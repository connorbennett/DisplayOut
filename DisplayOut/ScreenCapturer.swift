//
//  ScreenCapturer.swift
//  DisplayOut
//

import CoreMedia
import ScreenCaptureKit

enum ScalingMode: String, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "Fit (letterbox)"
        case .fill: return "Fill (crop)"
        }
    }
}

/// Captures one display with ScreenCaptureKit and delivers BGRA frames on a background queue.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the capture queue for every new frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the capture queue if the system ends the stream.
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "DisplayOut.capture", qos: .userInteractive)

    func start(display: SCDisplay,
               excluding excludedApps: [SCRunningApplication],
               outputWidth: Int,
               outputHeight: Int,
               frameDuration: CMTime,
               scaling: ScalingMode,
               showsCursor: Bool) async throws {
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.itur_709
        config.minimumFrameInterval = frameDuration
        config.showsCursor = showsCursor
        config.scalesToFit = true
        config.queueDepth = 5

        let displaySize = CGSize(width: display.width, height: display.height)
        let outputSize = CGSize(width: outputWidth, height: outputHeight)
        switch scaling {
        case .fit:
            // Capture at the aspect-fit size; the output centres it on black.
            let scale = min(outputSize.width / displaySize.width, outputSize.height / displaySize.height)
            config.width = min(outputWidth, Self.even(displaySize.width * scale))
            config.height = min(outputHeight, Self.even(displaySize.height * scale))
        case .fill:
            // Crop the display to the output's aspect ratio and scale that to the full frame.
            let scale = min(displaySize.width / outputSize.width, displaySize.height / outputSize.height)
            let crop = CGSize(width: outputSize.width * scale, height: outputSize.height * scale)
            config.sourceRect = CGRect(x: (displaySize.width - crop.width) / 2,
                                       y: (displaySize.height - crop.height) / 2,
                                       width: crop.width,
                                       height: crop.height)
            config.width = outputWidth
            config.height = outputHeight
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
