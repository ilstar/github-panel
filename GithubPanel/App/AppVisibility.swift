import AppKit

enum AppVisibility {
    static func toggle() {
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible }
        if NSApp.isActive && hasVisibleWindow {
            NSApp.hide(nil)
        } else {
            show()
        }
    }

    /// Brings the app and its main window to the front.
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = NSApp.windows.first(where: { $0.title != "Settings" }) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }
}
