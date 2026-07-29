import AppKit

@MainActor
enum AppIdentity {
    static func configure(_ app: NSApplication) {
        app.setActivationPolicy(.regular)
        if let data = appIconSVG.data(using: .utf8),
           let icon = NSImage(data: data) {
            icon.size = NSSize(width: 512, height: 512)
            app.applicationIconImage = icon
        }
        app.mainMenu = makeMainMenu()
    }

    private static let appIconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" \
    viewBox="0 0 1024 1024">
      <defs>
        <linearGradient id="surface" x1="176" y1="112" x2="848" y2="912" \
        gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#252B33"/>
          <stop offset="1" stop-color="#0E1217"/>
        </linearGradient>
        <linearGradient id="ink" x1="232" y1="324" x2="790" y2="700" \
        gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#FFFFFF"/>
          <stop offset="1" stop-color="#DDE4EA"/>
        </linearGradient>
      </defs>
      <rect x="64" y="64" width="896" height="896" rx="220" fill="url(#surface)"/>
      <rect x="66" y="66" width="892" height="892" rx="218" fill="none" \
      stroke="#FFFFFF" stroke-opacity=".10" stroke-width="4"/>
      <path d="M230 326L340 700L508 448L674 700L786 326" fill="none" \
      stroke="url(#ink)" stroke-width="62" stroke-linecap="round" \
      stroke-linejoin="round"/>
      <rect x="834" y="388" width="20" height="248" rx="10" fill="#78E0C5"/>
    </svg>
    """

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Wordhand",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Wordhand",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Wordhand",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        editItem.title = "Edit"
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        return main
    }
}

@MainActor
final class WordhandAppDelegate: NSObject, NSApplicationDelegate {
    private let onOpenPrimaryWindow: () -> Void

    init(onOpenPrimaryWindow: @escaping () -> Void) {
        self.onOpenPrimaryWindow = onOpenPrimaryWindow
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            onOpenPrimaryWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
