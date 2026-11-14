import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalShortcuts {
    enum Command: Int, CaseIterable {
        case toggle, join

        var title: String { self == .toggle ? L("快捷窗口分屏") : L("还原分屏") }
        var defaultKey: Key {
            Key(code: UInt32(self == .toggle ? kVK_ANSI_S : kVK_ANSI_J),
                modifiers: UInt32(controlKey | shiftKey), equivalent: self == .toggle ? "s" : "j")
        }
        var defaultsKey: String { self == .toggle ? "shortcut.toggle" : "shortcut.join" }
    }

    struct Key: Codable {
        private static let modifierKeys: [(flag: NSEvent.ModifierFlags, mask: UInt32, symbol: String)] = [
            (.control, UInt32(controlKey), "⌃"), (.option, UInt32(optionKey), "⌥"),
            (.shift, UInt32(shiftKey), "⇧"), (.command, UInt32(cmdKey), "⌘")
        ]

        let code: UInt32
        let modifiers: UInt32
        let equivalent: String

        init(code: UInt32, modifiers: UInt32, equivalent: String) {
            self.code = code
            self.modifiers = modifiers
            self.equivalent = equivalent
        }

        init?(event: NSEvent) {
            let modifiers = Self.modifierKeys.reduce(UInt32(0)) { mask, key in
                event.modifierFlags.contains(key.flag) ? mask | key.mask : mask
            }
            guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0,
                  let equivalent = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
                  equivalent.unicodeScalars.count == 1 else { return nil }
            self.init(code: UInt32(event.keyCode), modifiers: modifiers, equivalent: equivalent)
        }

        var menuModifiers: NSEvent.ModifierFlags {
            Self.modifierKeys.reduce(into: []) { flags, key in
                if modifiers & key.mask != 0 { flags.insert(key.flag) }
            }
        }

        var label: String {
            let symbols = Self.modifierKeys.filter { modifiers & $0.mask != 0 }.map(\.symbol).joined()
            return symbols + keyName
        }

        private var keyName: String {
            switch Int(code) {
            case kVK_Space: return L("空格")
            case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
            case kVK_Tab: return "⇥"
            case kVK_Delete: return "⌫"
            case kVK_ForwardDelete: return "⌦"
            case kVK_LeftArrow: return "←"
            case kVK_RightArrow: return "→"
            case kVK_UpArrow: return "↑"
            case kVK_DownArrow: return "↓"
            case kVK_Home: return "↖"
            case kVK_End: return "↘"
            case kVK_PageUp: return "⇞"
            case kVK_PageDown: return "⇟"
            default:
                if let scalar = equivalent.unicodeScalars.first?.value,
                   (UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey)).contains(scalar) {
                    return "F\(scalar - UInt32(NSF1FunctionKey) + 1)"
                }
                return equivalent.uppercased()
            }
        }

        func hasSameKeys(as other: Key) -> Bool { code == other.code && modifiers == other.modifiers }
    }

    private struct Registration {
        let id: UInt32
        let reference: EventHotKeyRef
    }

    private static let signature: OSType = 0x5653504C
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var registrations: [Command: Registration] = [:]
    private var keys: [Command: Key] = [:]
    var onPress: ((Command) -> Void)?

    init() {
        for command in Command.allCases {
            guard let data = UserDefaults.standard.data(forKey: command.defaultsKey) else { continue }
            keys[command] = try? PropertyListDecoder().decode(Key.self, from: data)
        }
    }

    func key(for command: Command) -> Key { keys[command] ?? command.defaultKey }
    func isRegistered(_ command: Command) -> Bool { registrations[command] != nil }

    func command(for event: NSEvent) -> Command? {
        guard let pressed = Key(event: event) else { return nil }
        return Command.allCases.first { pressed.hasSameKeys(as: key(for: $0)) }
    }

    func start() -> [Command] {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let signature = id.signature
            let hotKeyID = id.id
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak shortcuts] in
                guard signature == GlobalShortcuts.signature else { return }
                shortcuts?.handlePress(hotKeyID)
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return Command.allCases }
        return Command.allCases.filter { register(key(for: $0), for: $0) != noErr }
    }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func set(_ key: Key, for command: Command) -> String? {
        if let other = Command.allCases.first(where: { $0 != command && key.hasSameKeys(as: self.key(for: $0)) }) {
            return L("这个组合键已用于「%@」，请按其他组合键。", String(describing: other.title))
        }
        let status = register(key, for: command)
        if status == eventHotKeyExistsErr { return L("这个组合键已被占用，请按其他组合键。") }
        guard status == noErr else { return L("无法注册 %@（%@），请按其他组合键。", String(describing: key.label), String(describing: status)) }
        if let data = try? PropertyListEncoder().encode(key) {
            UserDefaults.standard.set(data, forKey: command.defaultsKey)
        }
        return nil
    }

    private func register(_ key: Key, for command: Command) -> OSStatus {
        guard handler != nil else { return OSStatus(eventNotHandledErr) }
        if isRegistered(command), key.hasSameKeys(as: self.key(for: command)) { return noErr }
        nextID += 1
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr else { return status }
        guard let reference else { return OSStatus(paramErr) }
        // Acquire the new shortcut before releasing the previous one.
        if let old = registrations.updateValue(Registration(id: id.id, reference: reference), forKey: command) {
            UnregisterEventHotKey(old.reference)
        }
        keys[command] = key
        return noErr
    }

    private func handlePress(_ id: UInt32) {
        guard let command = registrations.first(where: { $0.value.id == id })?.key else { return }
        onPress?(command)
    }
}
