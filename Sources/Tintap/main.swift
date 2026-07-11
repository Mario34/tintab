import AppKit

private let application = NSApplication.shared
private let delegate = AppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
