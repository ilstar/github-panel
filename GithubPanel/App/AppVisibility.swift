import AppKit

enum AppVisibility {
    static func toggle() {
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible }
        if NSApp.isActive && hasVisibleWindow {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if let mainWindow = NSApp.windows.first(where: { $0.title != "Settings" }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
    }
}
