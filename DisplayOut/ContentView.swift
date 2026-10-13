//
//  ContentView.swift
//  DisplayOut
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    private var locked: Bool { model.isRunning || model.isStarting }

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(layer: model.preview.layer)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if !model.isRunning {
                        Text("No output")
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding([.horizontal, .top])

            Form {
                Section("Source") {
                    Picker("Source", selection: $model.source) {
                        ForEach(SourceKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(locked)

                    if model.source == .testPattern {
                        // Stays enabled while running: the pattern can be switched live.
                        Picker("Pattern", selection: $model.testPattern) {
                            ForEach(TestPattern.allCases) { pattern in
                                Text(pattern.title).tag(pattern)
                            }
                        }
                    } else {
                        if !model.hasScreenAccess {
                            LabeledContent {
                                Button("Grant Access…") { model.requestScreenAccess() }
                            } label: {
                                Label("Screen Recording permission is required. Relaunch after granting it.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Group {
                            Picker("Display", selection: $model.selectedDisplayID) {
                                ForEach(model.displays) { display in
                                    Text(display.name).tag(Optional(display.id))
                                }
                            }
                            Picker("Scaling", selection: $model.scaling) {
                                ForEach(ScalingMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            Toggle("Show cursor", isOn: $model.showsCursor)
                            Toggle("Hide this app's windows from the output", isOn: $model.hidesOwnWindows)
                        }
                        .disabled(locked)
                    }
                }

                Section("Output") {
                    if !model.driverAvailable {
                        Label("Blackmagic Desktop Video isn't installed.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if model.devices.isEmpty {
                        Label("No DeckLink or UltraStudio output device connected.", systemImage: "cable.connector.slash")
                            .foregroundStyle(.secondary)
                    } else {
                        Group {
                            Picker("Device", selection: $model.selectedDevice) {
                                ForEach(model.devices, id: \.self) { device in
                                    Text(device.displayName).tag(Optional(device))
                                }
                            }
                            Picker("Format", selection: $model.selectedModeID) {
                                ForEach(model.selectedDevice?.modes ?? [], id: \.modeID) { mode in
                                    Text(mode.name).tag(Optional(mode.modeID))
                                }
                            }
                        }
                        .disabled(locked)
                    }
                    Toggle("Blank output when stopped", isOn: $model.blanksOnStop)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                if let error = model.errorMessage {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(model.statusText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.stop() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Start Output") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
            }
            .font(.callout)
            .lineLimit(2)
            .padding([.horizontal, .bottom])
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PreviewView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
