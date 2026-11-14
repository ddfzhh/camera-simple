import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PinholeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = CameraModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Single window: no "New Window".
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                Button("Take Photo") { model.capture() }
                Divider()
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { model.setZoom(1) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Choose Save Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Show in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                if model.devices.count > 1 {
                    Divider()
                    ForEach(model.devices, id: \.uniqueID) { device in
                        Button((device.uniqueID == model.selectedID ? "✓ " : "    ") + device.localizedName) {
                            model.choose(device)
                        }
                    }
                }
            }
        }
    }
}
