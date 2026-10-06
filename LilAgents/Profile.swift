import AppKit

// Who he is and who you are, and what he's wearing. Kept in UserDefaults (on this Mac only).
//   - his name: you name him when you adopt him (onboarding); "rename me…" in his menu
//   - your name: he asks when you first meet; "call me…" in his menu
//   - outfit: his clips come in looks (classic, glasses, …); each look is a folder of the same clips

enum Profile {
    private static let d = UserDefaults.standard

    static var petName: String {
        get { d.string(forKey: "petName").flatMap { $0.isEmpty ? nil : $0 } ?? "carroto" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "petName") }
    }
    static var humanName: String? {
        get { d.string(forKey: "humanName").flatMap { $0.isEmpty ? nil : $0 } }
        set { d.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "humanName") }
    }

    /// his dog (he named him dig himself, 5 oct 2026); "rename dig…" in his menu
    static var dogName: String {
        get { d.string(forKey: "dogName").flatMap { $0.isEmpty ? nil : $0 } ?? "dig" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "dogName") }
    }

    /// what dig's up to this minute (DogCompanion keeps it current), so carroto can mention it
    static var dogDoing = "standing next to you, wagging"

    /// The last time you were at the computer (for "i missed you").
    static var lastSeen: Date? {
        get { d.object(forKey: "lastSeen") as? Date }
        set { d.set(newValue, forKey: "lastSeen") }
    }

    /// what goes into his chat so he knows his name and yours
    static func promptLine() -> String {
        var s = "Your name is \(petName)"
        s += petName.lowercased() == "carroto" ? "." : " (the person who adopted you named you that; you love it)."
        if let h = humanName { s += " The person you live with is called \(h); use their name now and then, naturally, not every message." }
        s += " You have a dog called \(dogName): a little brown dachshund who lives on the dock right beside you. He trots after you, wags, naps when you nap, and you give him a bone biscuit every half hour or so. Right now he's \(dogDoing). Mention him only when it fits."
        return s
    }
}

// MARK: - Outfits

enum Outfit: String, CaseIterable {
    case classic, glasses
    // each look is a folder of the same clips in Outfits/<name>/

    var title: String { ["classic": "classic", "glasses": "glasses 🤓"][rawValue] ?? rawValue }

    static var current: Outfit {
        get {
            if let s = UserDefaults.standard.string(forKey: "outfit"), let o = Outfit(rawValue: s), o.isAvailable { return o }
            return .classic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "outfit") }
    }

    /// which outfits this build actually has clips for
    var isAvailable: Bool { Bundle.main.url(forResource: "walk-carrot-01", withExtension: "mov", subdirectory: "Outfits/\(rawValue)") != nil || self == .glasses }

    /// a clip in the current outfit (falls back to the main set)
    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mov", subdirectory: "Outfits/\(current.rawValue)")
            ?? Bundle.main.url(forResource: name, withExtension: "mov")
    }
}

// MARK: - Quiet focus

/// During a focus session: macOS Focus on (through two Shortcuts you make once), and chatty apps tucked away.
enum QuietFocus {
    static let onName = "carroto focus on", offName = "carroto focus off"
    /// the apps he hides while you focus (they come back after)
    static let noisy = ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
                        "com.facebook.archon", "com.burbn.instagram", "com.apple.mail", "com.microsoft.teams2", "com.microsoft.teams"]
    private static var hidden: [NSRunningApplication] = []

    /// (checked in the background and remembered, so his menu opens instantly)
    private static var ready = false, checkedAt = Date.distantPast
    static var shortcutsReady: Bool {
        if Date().timeIntervalSince(checkedAt) > 20 {
            checkedAt = Date()
            DispatchQueue.global().async {
                let out = run(["list"]) ?? ""
                let names = Set(out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                let ok = names.contains(onName) && names.contains(offName)
                DispatchQueue.main.async { ready = ok }
            }
        }
        return ready
    }

    @discardableResult
    private static func run(_ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// returns whether notifications were muted (the shortcuts exist)
    static func begin() -> Bool {
        hidden = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier, noisy.contains(id), !app.isHidden else { return false }
            return app.hide()
        }
        guard shortcutsReady else { return false }
        DispatchQueue.global().async { run(["run", onName]) }
        return true
    }

    static func end() {
        for app in hidden { app.unhide() }
        hidden = []
        DispatchQueue.global().async { if shortcutsReady { run(["run", offName]) } }
    }

    /// one-time setup: two tiny shortcuts that switch Do Not Disturb on and off
    static let setupSteps = """
    so i can mute everything while you focus:
    1. open Shortcuts, click +
    2. add “Set Focus” → Do Not Disturb → On (until turned off)
    3. name it “\(onName)”
    4. make one more: “Set Focus” → Do Not Disturb → Off, named “\(offName)”
    that's it. next focus session, it all goes quiet.
    """
}
