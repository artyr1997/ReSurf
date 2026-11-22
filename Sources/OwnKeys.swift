import AppKit

/// Keys of one's own, set in ReDesk's keys popup (⌘/) and kept in Application Support/ReSpace/keys.json
/// ({"ReSurf": {"newTab": "keyCode:modifiers"}}). The app goes on knowing only its own keys: a key of one's
/// own pressed is handed on as the key it stands for, and that key itself does nothing any more (unless it
/// is another one's own). ReDesk says when they change (com.artursavytskyi.re.keys).
enum OwnKeys {
    struct Combo: Equatable {
        var key: UInt16
        var flags: NSEvent.ModifierFlags

        static let modifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

        init(key: UInt16, flags: NSEvent.ModifierFlags) {
            self.key = key
            self.flags = flags.intersection(Self.modifiers)
        }

        init(_ event: NSEvent) { self.init(key: event.keyCode, flags: event.modifierFlags) }

        init?(kept: String) {
            let parts = kept.split(separator: ":").compactMap { UInt64($0) }
            guard parts.count == 2 else { return nil }
            self.init(key: UInt16(parts[0]), flags: NSEvent.ModifierFlags(rawValue: UInt(parts[1])))
        }

        static func == (a: Combo, b: Combo) -> Bool { a.key == b.key && a.flags.rawValue == b.flags.rawValue }
    }

    /// what each of the app's keys is, as it came: the key, and the character it types (used only if the key's
    /// event can't be made as the system makes it)
    struct Standard {
        let combo: Combo
        let character: String
    }

    private static var app = ""
    private static var standard: [String: Standard] = [:]
    /// the keys of one's own, by what they do
    private static var own: [String: Combo] = [:]
    private static var monitor: Any?

    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ReSpace/keys.json")

    static func start(app: String, standard: [String: Standard]) {
        self.app = app
        self.standard = standard
        load()
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.artursavytskyi.re.keys"), object: nil, queue: .main) { _ in
            load()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in translate(event) }
    }

    private static func load() {
        let all = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: String]] } ?? [:]
        own = (all[app] ?? [:]).compactMapValues(Combo.init(kept:)).filter { standard[$0.key] != nil }
    }

    private static func translate(_ event: NSEvent) -> NSEvent? {
        guard !own.isEmpty else { return event }
        let pressed = Combo(event)
        // a key of one's own: handed on as the one it stands for
        if let (what, _) = own.first(where: { $0.value == pressed }), let was = standard[what] {
            // made as the system makes a key's event (its characters from the keyboard), which the menus and
            // the views take as the key itself; one made by NSEvent.keyEvent is matched to the wrong item
            if let cg = CGEvent(keyboardEventSource: nil, virtualKey: was.combo.key, keyDown: true) {
                cg.flags = CGEventFlags(rawValue: UInt64(was.combo.flags.rawValue))
                if event.isARepeat { cg.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
                if let made = NSEvent(cgEvent: cg) { return made }
            }
            let flags = event.modifierFlags.subtracting(Combo.modifiers).union(was.combo.flags)
            let typed = was.combo.flags.contains(.shift) ? was.character.uppercased() : was.character
            return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: flags,
                                    timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                    characters: typed, charactersIgnoringModifiers: typed,
                                    isARepeat: event.isARepeat, keyCode: was.combo.key) ?? event
        }
        // a key that has been given another: no longer this one's
        if standard.contains(where: { own[$0.key] != nil && $0.value.combo == pressed }) { return nil }
        return event
    }
}

extension OwnKeys.Standard {
    /// ⌘ and a letter (or another key), as the app's keys are written
    init(_ key: UInt16, _ character: String, _ flags: NSEvent.ModifierFlags = .command) {
        self.init(combo: OwnKeys.Combo(key: key, flags: flags), character: character)
    }
}
