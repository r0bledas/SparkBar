import Foundation
import Carbon
import AppKit

/// Ultra-lightweight Carbon Global Hotkey Manager for `Option + Space`.
@MainActor
public final class HotkeyManager {
    public static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    public var onToggle: (() -> Void)?

    private init() {}

    public func registerDefaultHotkey() {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr && hotKeyID.id == 1 {
                Task { @MainActor in
                    HotkeyManager.shared.onToggle?()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        // Option (optionKey = 0x0800) + Space (kVK_Space = 0x31 = 49)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5350524B), id: 1) // 'SPRK'
        let modifiers = UInt32(optionKey)
        let keyCode = UInt32(kVK_Space)

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
