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
        <linearGradient id="surface" x1="160" y1="112" x2="864" y2="912" \
        gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#2A323D"/>
          <stop offset="1" stop-color="#11161C"/>
        </linearGradient>
      </defs>
      <rect x="64" y="64" width="896" height="896" rx="220" fill="url(#surface)"/>
      <rect x="66" y="66" width="892" height="892" rx="218" fill="none" \
      stroke="#FFFFFF" stroke-opacity=".10" stroke-width="4"/>
      <g transform="translate(188 184) scale(27)" fill="none" stroke="#F5F7FA" \
      stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round">
        <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>
        <path d="m20 7 2 .5-2 .5"/>
        <path d="M10 18v3"/>
        <path d="M14 17.75V21"/>
        <path d="M7 18a6 6 0 0 0 3.84-10.61"/>
        <circle cx="16" cy="7" r=".26" fill="#78E0C5" stroke="none"/>
      </g>
    </svg>
    """

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Parrot",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Parrot",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Parrot",
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
final class ParrotAppDelegate: NSObject, NSApplicationDelegate {
    private let onOpenHistory: () -> Void

    init(onOpenHistory: @escaping () -> Void) {
        self.onOpenHistory = onOpenHistory
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            onOpenHistory()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
