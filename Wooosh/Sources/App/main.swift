import AppKit

// `.accessory` keeps Wooosh out of the Dock and the app switcher: it is a
// background service that happens to be able to show one window, not a document
// app. The window is still fully usable — `NSApp.activate` brings it forward.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
