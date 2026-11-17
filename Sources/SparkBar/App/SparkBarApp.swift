import AppKit
import SwiftUI

@main
public struct SparkBarMain {
    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
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

        PanelController.shared.setupPanel(with: FloatingPromptView())

        HotkeyManager.shared.onToggle = {
            PanelController.shared.togglePanel()
        }
        HotkeyManager.shared.registerDefaultHotkey()

        // Show the floating bar immediately on launch so the user sees it right away
        PanelController.shared.showPanel()
    }

    private func setupMainMenuWithEditCommands() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "New Chat", action: #selector(clearConversationAction), keyEquivalent: "n")
        appMenu.addItem(withTitle: "Close Panel", action: #selector(closePanelAction), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
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
            button.image = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: "SparkBar")
            button.image?.isTemplate = true
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

    @objc private func closePanelAction() {
        PanelController.shared.hidePanel()
    }

    @objc private func clearConversationAction() {
        ChatViewModel.shared.clearConversation()
        PanelController.shared.showPanel()
    }

    @objc private func openSettingsAction() {
        PanelController.shared.showPanel()
        ChatViewModel.shared.showSettings = true
    }

    @objc private func quitAppAction() {
        NSApplication.shared.terminate(nil)
    }
}
