//
//  AppModel.swift
//  DisplayOut
//

import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

enum SourceKind: String, CaseIterable, Identifiable {
    case display
    case testPattern

    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: return "Display"
        case .testPattern: return "Test Pattern"
        }
    }
}

struct DisplayItem: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// Shows captured frames in a layer, throttled so the preview doesn't compete with the output.
final class PreviewSink: @unchecked Sendable {
    let layer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect
        return layer
    }()
    private var lastShown: CFTimeInterval = 0

    /// Called on the capture queue. Frames arriving faster than the preview rate are ignored
    /// unless `force` is set.
    func show(_ pixelBuffer: CVPixelBuffer, force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastShown >= 1.0 / 15.0,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        lastShown = now
        DispatchQueue.main.async { [layer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        }
    }

    func clear() {
        DispatchQueue.main.async { [layer] in layer.contents = nil }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Source
    @Published var source: SourceKind = .display { didSet { defaults.set(source.rawValue, forKey: Keys.source) } }
    @Published var testPattern: TestPattern = .bars75 {
        didSet {
            defaults.set(testPattern.rawValue, forKey: Keys.testPattern)
            sendTestPattern()
        }
    }
    @Published var displays: [DisplayItem] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var scaling: ScalingMode = .fit { didSet { defaults.set(scaling.rawValue, forKey: Keys.scaling) } }
    @Published var showsCursor = true { didSet { defaults.set(showsCursor, forKey: Keys.showsCursor) } }
    @Published var hidesOwnWindows = true { didSet { defaults.set(hidesOwnWindows, forKey: Keys.hidesOwnWindows) } }
    @Published var hasScreenAccess = CGPreflightScreenCaptureAccess()

    // Output
    @Published var devices: [DLDevice] = []
    @Published var selectedDevice: DLDevice? { didSet { deviceSelectionChanged() } }
    @Published var selectedModeID: UInt32?
    @Published var blanksOnStop = true { didSet { defaults.set(blanksOnStop, forKey: Keys.blanksOnStop) } }

    // State
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var statusText = ""
    @Published var errorMessage: String?

    let preview = PreviewSink()
    let driverAvailable: Bool

    private let deviceManager = DLDeviceManager()
    private let capturer = ScreenCapturer()
    private var output: DLOutput?
    private var outputDevice: DLDevice?
    private var runningMode: DLDisplayMode?
    private var runningSource: SourceKind = .display
    private var statsTimer: Timer?
    private var activity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let source = "source"
        static let testPattern = "testPattern"
        static let blanksOnStop = "blanksOnStop"
        static let scaling = "scaling"
        static let showsCursor = "showsCursor"
        static let hidesOwnWindows = "hidesOwnWindows"
        static let deviceName = "deviceName"
        static let modeID = "modeID"
        static let displayID = "displayID"
    }

    var selectedMode: DLDisplayMode? {
        selectedDevice?.modes.first { $0.modeID == selectedModeID }
    }

    var canStart: Bool {
        guard !isRunning, !isStarting, selectedMode != nil else { return false }
        return source == .testPattern || (hasScreenAccess && selectedDisplayID != nil)
    }

    init() {
        driverAvailable = deviceManager.driverAvailable
        if let raw = defaults.string(forKey: Keys.source), let saved = SourceKind(rawValue: raw) { source = saved }
        if let raw = defaults.string(forKey: Keys.testPattern), let saved = TestPattern(rawValue: raw) { testPattern = saved }
        if defaults.object(forKey: Keys.blanksOnStop) != nil { blanksOnStop = defaults.bool(forKey: Keys.blanksOnStop) }
        if let raw = defaults.string(forKey: Keys.scaling), let saved = ScalingMode(rawValue: raw) { scaling = saved }
        if defaults.object(forKey: Keys.showsCursor) != nil { showsCursor = defaults.bool(forKey: Keys.showsCursor) }
        if defaults.object(forKey: Keys.hidesOwnWindows) != nil { hidesOwnWindows = defaults.bool(forKey: Keys.hidesOwnWindows) }

        deviceManager.devicesChanged = { [weak self] in
            MainActor.assumeIsolated { self?.devicesDidChange() }
        }
        deviceManager.start()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
        refreshDisplays()
    }

    // MARK: Displays

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let size = screen.frame.size
            return DisplayItem(id: number.uint32Value,
                               name: "\(screen.localizedName) (\(Int(size.width)) × \(Int(size.height)))")
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            let saved = CGDirectDisplayID(defaults.integer(forKey: Keys.displayID))
            selectedDisplayID = displays.contains(where: { $0.id == saved }) ? saved : displays.first?.id
        }
    }

    func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        hasScreenAccess = CGPreflightScreenCaptureAccess()
    }

    // MARK: Devices

    private func devicesDidChange() {
        devices = deviceManager.devices
        if let outputDevice, !devices.contains(outputDevice) {
            stop()
            errorMessage = "\(outputDevice.displayName) was disconnected."
        }
        if let current = selectedDevice, devices.contains(current) { return }
        let savedName = defaults.string(forKey: Keys.deviceName)
        selectedDevice = devices.first { $0.displayName == savedName } ?? devices.first
    }

    private func deviceSelectionChanged() {
        guard let device = selectedDevice else {
            selectedModeID = nil
            return
        }
        let modeIDs = device.modes.map(\.modeID)
        if let current = selectedModeID, modeIDs.contains(current) { return }
        let saved = UInt32(truncatingIfNeeded: defaults.integer(forKey: Keys.modeID))
        // 1080p59.94, 1080p29.97, 1080i59.94
        let preferred: [UInt32] = [saved, 0x4870_3539, 0x4870_3239, 0x4869_3539]
        selectedModeID = preferred.first { modeIDs.contains($0) } ?? modeIDs.first
    }

    // MARK: Start / stop

    func start() {
        guard canStart, let device = selectedDevice, let mode = selectedMode else { return }
        let source = self.source
        let displayID = selectedDisplayID
        errorMessage = nil
        isStarting = true
        statusText = "Starting…"
        defaults.set(device.displayName, forKey: Keys.deviceName)
        defaults.set(Int(mode.modeID), forKey: Keys.modeID)
        if let displayID { defaults.set(Int(displayID), forKey: Keys.displayID) }

        Task {
            do {
                // Resolve the capture target before touching the hardware so permission
                // problems surface without the output flashing on.
                var captureTarget: (display: SCDisplay, excluded: [SCRunningApplication])?
                if source == .display {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                        throw NSError(domain: "DisplayOut", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "The selected display is no longer available."])
                    }
                    let ownApps = hidesOwnWindows
                        ? content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                        : []
                    captureTarget = (display, ownApps)
                }

                let output = DLOutput(device: device)
                try output.start(mode: mode)

                if let captureTarget {
                    let preview = self.preview
                    capturer.onFrame = { pixelBuffer in
                        output.send(pixelBuffer)
                        preview.show(pixelBuffer)
                    }
                    capturer.onStop = { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.isRunning else { return }
                            self.stop()
                            self.errorMessage = "Screen capture stopped: \(error.localizedDescription)"
                        }
                    }
                    do {
                        try await capturer.start(display: captureTarget.display,
                                                 excluding: captureTarget.excluded,
                                                 outputWidth: mode.width,
                                                 outputHeight: mode.height,
                                                 frameDuration: CMTime(value: mode.frameDuration, timescale: CMTimeScale(mode.timeScale)),
                                                 scaling: scaling,
                                                 showsCursor: showsCursor)
                    } catch {
                        output.stop()
                        throw error
                    }
                }

                self.output = output
                outputDevice = device
                runningMode = mode
                runningSource = source
                isRunning = true
                sendTestPattern()
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                                                                 reason: "Sending display to video output")
                statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateStatus() }
                }
                updateStatus()
            } catch {
                statusText = ""
                errorMessage = error.localizedDescription
                hasScreenAccess = CGPreflightScreenCaptureAccess()
            }
            isStarting = false
        }
    }

    /// Renders the selected pattern once; the output repeats it until something newer is sent.
    private func sendTestPattern() {
        guard isRunning, runningSource == .testPattern, let output, let mode = runningMode,
              let pixelBuffer = testPattern.makePixelBuffer(width: mode.width, height: mode.height) else { return }
        output.send(pixelBuffer)
        preview.show(pixelBuffer, force: true)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        statsTimer?.invalidate()
        statsTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        capturer.onFrame = nil
        capturer.onStop = nil
        let output = self.output
        output?.blanksOnStop = blanksOnStop
        self.output = nil
        outputDevice = nil
        runningMode = nil
        statusText = ""
        preview.clear()
        Task {
            await capturer.stop()
            output?.stop()
        }
    }

    private func updateStatus() {
        guard let output else { return }
        let stats = output.stats
        statusText = "\(runningMode?.name ?? "") · \(output.pixelFormatName) · \(stats.late) late · \(stats.dropped) dropped"
    }
}
