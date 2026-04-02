import AppKit
import SwiftUI

@main
struct VoiceCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
                .frame(width: 1, height: 1)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dependencies = AppDependencies()
        statusItemController = StatusItemController(dependencies: dependencies)
        statusItemController?.install()
    }
}
