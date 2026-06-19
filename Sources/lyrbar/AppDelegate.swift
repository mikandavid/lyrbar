import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let autoLogin: Bool
    private var controller: StatusController?

    init(autoLogin: Bool) {
        self.autoLogin = autoLogin
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusController()
        self.controller = controller
        controller.start()
        if autoLogin {
            controller.beginLogin()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
