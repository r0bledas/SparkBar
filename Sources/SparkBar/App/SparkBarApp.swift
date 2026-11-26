import AppKit
import SwiftUI

@main
public struct SparkBarMain {
    public static func main() {
        let args = CommandLine.arguments
        if let cliIdx = args.firstIndex(of: "--cli") {
            let subArgs = Array(args.dropFirst(cliIdx + 1))
            runCLIMode(arguments: subArgs)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    @MainActor
    private static func runCLIMode(arguments: [String]) {
        guard let subcommand = arguments.first else {
            print("Usage: sparkbar-tools <html2pdf|pdf-info|file-verify> [args...]")
            exit(1)
        }

        switch subcommand {
        case "pdf-info", "file-verify":
            guard arguments.count >= 2 else {
                print("Usage: sparkbar-tools \(subcommand) <path>")
                exit(1)
            }
            let (out, isErr) = NativePDFRenderer.inspectPDF(at: arguments[1])
            print(out)
            exit(isErr ? 1 : 0)

        case "html2pdf":
            guard arguments.count >= 3 else {
                print("Usage: sparkbar-tools html2pdf <input.html> <output.pdf>")
                exit(1)
            }
            let inPath = arguments[1]
            let outPath = arguments[2]
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let (out, isErr) = await NativePDFRenderer.renderToPDF(
                    htmlOrMarkdown: nil,
                    inputPath: inPath,
                    outputPath: outPath
                )
                print(out)
                exit(isErr ? 1 : 0)
            }
            app.run()

        default:
            print("Unknown subcommand: \(subcommand)")
            exit(1)
        }
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another SparkBar process is already running, ask it to open & focus the main window and exit.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "com.sparkbar.app"
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != currentPID }
        if !duplicates.isEmpty {
            DistributedNotificationCenter.default().post(
                name: NSNotification.Name("com.sparkbar.openMainWindow"),
                object: nil
            )
            NSApp.terminate(nil)
            return
        }

        // Warm up the login-shell PATH and Environment Manifest asynchronously
        EnvironmentProbe.shared.refreshAsync()

        // Run as a lightweight accessory / menu bar agent without cluttering the Dock
        NSApp.setActivationPolicy(.accessory)

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }

        setupMainMenuWithEditCommands()
        updateStatusBarItemVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarVisibilityChanged),
            name: NSNotification.Name("SparkBarMenuBarVisibilityChanged"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalOpenMainWindow),
            name: NSNotification.Name("com.sparkbar.openMainWindow"),
            object: nil
        )

        PanelController.shared.setupPanel(with: FloatingPromptView())

        HotkeyManager.shared.onToggle = {
            PanelController.shared.togglePanel()
        }
        HotkeyManager.shared.registerDefaultHotkey()

        if SettingsStore.shared.enableLocalAPIServer {
            LocalAPIServer.shared.start(port: SettingsStore.shared.localAPIServerPort)
        }

        // If launched automatically at login/restart, stay silent in the background until ⌥Space is pressed.
        // If launched manually by the user (e.g. from /Applications), open and focus the main full-size window.
        if !wasLaunchedAtStartup(notification) {
            FullScreenChatWindowController.shared.showWindow()
            // On manual launch, if AGY is selected but binary or Google login isn't set up yet, open Settings to guide setup
            if SettingsStore.shared.selectedProvider == .antigravity {
                AGYAccountManager.shared.reload()
                if SettingsStore.shared.resolvedAGYBinaryPath == nil || !AGYAccountManager.shared.isSignedIn {
                    SettingsWindowController.shared.showWindow()
                }
            }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        FullScreenChatWindowController.shared.showWindow()
        return true
    }

    @objc private func handleExternalOpenMainWindow() {
        Task { @MainActor in
            FullScreenChatWindowController.shared.showWindow()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        LocalAPIServer.shared.stop()
        ChatViewModel.shared.persistCurrentSession()
    }

    private func wasLaunchedAtStartup(_ notification: Notification) -> Bool {
        if CommandLine.arguments.contains("--background") {
            return true
        }
        // Standard macOS AppleEvent flag when launched as a Login Item
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           let prop = event.paramDescriptor(forKeyword: keyAEPropData),
           prop.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Also guard early boot window if Open on Startup is enabled
        if SettingsStore.shared.openOnStartup && ProcessInfo.processInfo.systemUptime < 90 {
            return true
        }
        return false
    }

    private func setupMainMenuWithEditCommands() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "New Chat", action: #selector(clearConversationAction), keyEquivalent: "n")
        appMenu.addItem(withTitle: "Open Full Window", action: #selector(openFullScreenWindowAction), keyEquivalent: "F")
        appMenu.addItem(withTitle: "Conversation History…", action: #selector(toggleHistoryAction), keyEquivalent: "y")
        appMenu.addItem(withTitle: "Close Panel", action: #selector(closePanelAction), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Update from GitHub…", action: #selector(updateFromGitHubAction), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit SparkBar", action: #selector(quitAppAction), keyEquivalent: "q")

        // Standard Edit Menu (Required by macOS Responder Chain for ⌘C Copy, ⌘V Paste, ⌘X Cut, ⌘A Select All)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleMenuBarVisibilityChanged() {
        updateStatusBarItemVisibility()
    }

    private func updateStatusBarItemVisibility() {
        if SettingsStore.shared.showMenuBarIcon {
            if statusItem == nil {
                setupStatusBarItem()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = SparkBarIconRenderer.makeImage(size: 18, isTemplate: true)
            button.image?.accessibilityDescription = "SparkBar"
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: "Toggle SparkBar (⌥Space)",
            action: #selector(togglePanelAction),
            keyEquivalent: " "
        )
        toggleItem.keyEquivalentModifierMask = [.option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let fullWindowItem = NSMenuItem(
            title: "Open Full Window",
            action: #selector(openFullScreenWindowAction),
            keyEquivalent: "f"
        )
        fullWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fullWindowItem.target = self
        menu.addItem(fullWindowItem)

        let closeItem = NSMenuItem(
            title: "Close Panel",
            action: #selector(closePanelAction),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        closeItem.target = self
        menu.addItem(closeItem)

        let newChatItem = NSMenuItem(
            title: "New Chat",
            action: #selector(clearConversationAction),
            keyEquivalent: "n"
        )
        newChatItem.keyEquivalentModifierMask = [.command]
        newChatItem.target = self
        menu.addItem(newChatItem)

        let historyItem = NSMenuItem(
            title: "Conversation History…",
            action: #selector(toggleHistoryAction),
            keyEquivalent: "y"
        )
        historyItem.keyEquivalentModifierMask = [.command]
        historyItem.target = self
        menu.addItem(historyItem)

        let openLogsItem = NSMenuItem(
            title: "Open Logs Folder in Finder",
            action: #selector(openLogsFolderAction),
            keyEquivalent: ""
        )
        openLogsItem.target = self
        menu.addItem(openLogsItem)

        let clearItem = NSMenuItem(
            title: "Clear Prompt",
            action: #selector(clearConversationAction),
            keyEquivalent: "k"
        )
        clearItem.keyEquivalentModifierMask = [.command]
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings & API Keys…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "Update from GitHub…",
            action: #selector(updateFromGitHubAction),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit SparkBar",
            action: #selector(quitAppAction),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func togglePanelAction() {
        PanelController.shared.togglePanel()
    }

    @objc private func openFullScreenWindowAction() {
        FullScreenChatWindowController.shared.showWindow()
    }

    @objc private func closePanelAction() {
        PanelController.shared.hidePanel()
    }

    @objc private func clearConversationAction() {
        ChatViewModel.shared.startNewConversation()
        PanelController.shared.showPanel()
    }

    @objc private func toggleHistoryAction() {
        PanelController.shared.showPanel()
        ChatViewModel.shared.toggleHistory()
    }

    @objc private func openLogsFolderAction() {
        ConversationStore.shared.openLogsFolderInFinder()
    }

    @objc private func openSettingsAction() {
        SettingsWindowController.shared.showWindow()
    }

    @objc private func updateFromGitHubAction() {
        SettingsWindowController.shared.showWindow()
        GitHubUpdater.shared.performUpdateFromGitHub()
    }

    @objc private func quitAppAction() {
        NSApplication.shared.terminate(nil)
    }
}
