//
//  DisplayOutApp.swift
//  DisplayOut
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DisplayOutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DisplayOut", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
