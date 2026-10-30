import SwiftUI
import PaperLikeNativeUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Keep PaperLike Native running in the background for display control and touch mapping")
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ConnectionStatusIcon(presentation: model.connectionPresentation, size: 16)
            .accessibilityLabel(model.connectionPresentation.accessibilityLabel)
    }
}

@main
struct PaperLikeNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            QuickPanelView(model: appDelegate.model)
        } label: {
            MenuBarStatusLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { appDelegate.model.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
