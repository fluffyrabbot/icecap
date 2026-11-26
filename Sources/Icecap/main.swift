import AppKit

// A write to the spacer's helper after it has ended fails with an error to log, rather
// than ending icecap.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
let applicationDelegate = ApplicationDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.mainMenu = MainMenu.make()
application.run()
