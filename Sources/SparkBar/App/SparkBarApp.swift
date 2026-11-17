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

        setupStatusBarItem()
        PanelController.shared.setupPanel(with: FloatingPromptView())

        HotkeyManager.shared.onToggle = {
            PanelController.shared.togglePanel()
        }
        HotkeyManager.shared.registerDefaultHotkey()

        // Show the floating bar immediately on launch so the user sees it right away
        PanelController.shared.showPanel()
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

        let clearItem = NSMenuItem(
            title: "New / Clear Prompt",
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
