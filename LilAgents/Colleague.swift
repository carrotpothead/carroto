import AppKit
import IOKit.pwr_mgt

// carroto's everyday company: focusing with you (with DND mode), watching a video with you (popcorn out),
// a lunch alarm, and noticing when you come back. Nothing about you is stored: just a few settings in UserDefaults.

// MARK: - His chat setup

struct CarrotoMemory {
    /// his own folder (~/Library/Application Support/carroto): where his chats run, and the AI-tool hook script
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("carroto", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")   // (only the folder is used)
    }()

    static func load() -> CarrotoMemory { CarrotoMemory() }

    /// Who he is, for his chat (whichever AI tool you use).
    func personaPrompt() -> String {
        """
        You are carroto, a small carrot who lives on the user's Mac dock, with your dog Dig (a little brown \
        dachshund). You keep this person company while they work. Warm, a bit cheeky, honest, brief. \
        Write in lowercase, short sentences. Help with whatever they ask; be good company otherwise. \
        Never give financial advice or tell them what to buy or sell.
        \(Profile.promptLine())
        """
    }
}

enum CardLine {
    case title(String), header(String), sub(String), note(String)
}

// MARK: - The info card

/// A little card of notes above him (e.g. how to set up DND mode). Click anywhere to close it.
final class InfoCard {
    static let shared = InfoCard()
    private var window: NSWindow?
    private var closeToken: UUID?
    private var clickAway: Any?


    func show(lines: [CardLine], above frame: NSRect, width w: CGFloat = 300, autoClose: TimeInterval? = nil) {
        close()
        if let t = autoClose {
            let token = UUID(); closeToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in if self?.closeToken == token { self?.close() } }
        }
        let ink = NSColor(red: 0.106, green: 0.114, blue: 0.133, alpha: 1)
        // lay the lines out top-down first, so the window can be sized to fit
        var views: [(NSTextField, CGFloat)] = [] // field, height
        func field(_ s: String, _ font: NSFont, _ color: NSColor, _ width: CGFloat, align: NSTextAlignment = .left, wrap: Bool = false) -> NSTextField {
            let l = wrap ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
            l.font = font; l.textColor = color; l.alignment = align
            l.preferredMaxLayoutWidth = width
            return l
        }
        var y: CGFloat = 16
        var placed: [(NSView, NSRect)] = []
        for line in lines {
            switch line {
            case .title(let s):
                let l = field(s, .systemFont(ofSize: 12, weight: .semibold), ink.withAlphaComponent(0.6), w - 32)
                placed.append((l, NSRect(x: 16, y: y, width: w - 32, height: 18))); y += 24
            case .header(let s):
                y += 4
                let l = field(s.uppercased(), .systemFont(ofSize: 10, weight: .bold), NSColor(red: 0.96, green: 0.48, blue: 0.13, alpha: 1), w - 32)
                placed.append((l, NSRect(x: 16, y: y, width: w - 32, height: 14))); y += 18
            case .sub(let s), .note(let s):
                let isNote: Bool = { if case .note = line { return true }; return false }()
                let l = field(s, .systemFont(ofSize: isNote ? 10.5 : 11), ink.withAlphaComponent(isNote ? 0.55 : 0.75), w - 40, wrap: true)
                let hgt = ceil(l.sizeThatFits(NSSize(width: w - 40, height: 400)).height)
                if isNote { y += 6 }
                placed.append((l, NSRect(x: isNote ? 16 : 24, y: y, width: w - 40, height: hgt))); y += hgt + 4
            }
        }
        _ = views
        let h = y + 12
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2000, height: 1200)
        let x = min(max(frame.midX - w / 2, screen.minX + 8), screen.maxX - w - 8)
        let top = min(frame.maxY - frame.height * 0.08 + h, screen.maxY - 8)
        let win = NSWindow(contentRect: NSRect(x: x, y: top - h, width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar + 5
        win.hasShadow = true
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(red: 0.985, green: 0.965, blue: 0.918, alpha: 1).cgColor
        box.layer?.cornerRadius = 16
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor(red: 0.96, green: 0.48, blue: 0.13, alpha: 1).cgColor
        // flip from top-down layout to AppKit's bottom-up coordinates
        for (v, r) in placed {
            v.frame = NSRect(x: r.minX, y: h - r.minY - r.height, width: r.width, height: r.height)
            box.addSubview(v)
        }
        win.contentView = box
        win.orderFrontRegardless()
        window = win
        clickAway = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in self?.close() }
    }

    func close() {
        if let m = clickAway { NSEvent.removeMonitor(m); clickAway = nil }
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - The little answer box

/// A speech-bubble-style text box above him. Enter answers, Esc (or clicking away) closes it.
final class AskPanel: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private var onAnswer: ((String) -> Void)?
    private var clickAway: Any?

    var isOpen: Bool { window?.isVisible ?? false }

    func open(question: String, placeholder: String, above frame: NSRect, onAnswer: @escaping (String) -> Void) {
        close()
        self.onAnswer = onAnswer
        let w: CGFloat = 320
        let qFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        // his question can be a whole reply now: give it up to five lines
        let qH = min(90, max(18, ceil((question as NSString).boundingRect(with: NSSize(width: w - 32, height: 400),
                                                                     options: [.usesLineFragmentOrigin], attributes: [.font: qFont]).height)))
        let h: CGFloat = 78 + qH
        let win = KeyableWindow(contentRect: NSRect(x: frame.midX - w / 2, y: frame.maxY - frame.height * 0.08, width: w, height: h),
                                styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar + 5
        win.hasShadow = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]

        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(red: 0.985, green: 0.965, blue: 0.918, alpha: 1).cgColor
        box.layer?.cornerRadius = 16
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor(red: 0.96, green: 0.48, blue: 0.13, alpha: 1).cgColor

        let label = NSTextField(wrappingLabelWithString: question)
        label.font = qFont
        label.textColor = NSColor(red: 0.106, green: 0.114, blue: 0.133, alpha: 1)
        label.frame = NSRect(x: 16, y: h - 16 - qH, width: w - 32, height: qH)
        label.maximumNumberOfLines = 5

        let field = NSTextField(frame: NSRect(x: 14, y: 16, width: w - 28, height: 28))
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(submit(_:))

        box.addSubview(label)
        box.addSubview(field)
        win.contentView = box
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(field)
        clickAway = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
    }

    @objc private func submit(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let handler = onAnswer
        close()
        if !text.isEmpty { handler?(text) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }

    func close() {
        if let m = clickAway { NSEvent.removeMonitor(m); clickAway = nil }
        window?.orderOut(nil)
        window = nil
        onAnswer = nil
    }
}

// MARK: - The colleague

final class Colleague {
    weak var carrot: WalkerCharacter?
    let ask = AskPanel()

    // what he's in the middle of
    private(set) var focusUntil: Date?
    var isFocusing: Bool { focusUntil != nil }
    /// While focusing or watching he stays put: no walks, tricks or naps.
    var holdsStill: Bool { isFocusing || isWatching }

    // MARK: watch party

    /// Watching something with you: back turned, popcorn out.
    private(set) var isWatching = false
    /// true when you asked for it from the menu (then it doesn't stop on its own)
    private var watchByHand = false
    private var videoSince: CFTimeInterval?
    private var noVideoSince: CFTimeInterval?
    private var lastVideoCheck: CFTimeInterval = 0
    private var videoOn = false
    private var lastWatchLine: CFTimeInterval = 0

    /// A video is playing somewhere: browsers and players ask macOS to keep the screen awake while one plays.
    static func videoPlaying() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for (pid, list) in dict where pid.int32Value != me {
            for a in list where (a["AssertType"] as? String) == "PreventUserIdleDisplaySleep" || (a["AssertType"] as? String) == "NoDisplaySleepAssertion" {
                return true
            }
        }
        return false
    }

    func startWatching(byHand: Bool = false) {
        guard let c = carrot, !isWatching else { return }
        isWatching = true
        watchByHand = byHand
        if isFocusing { focusUntil = nil; c.stopLoop() }
        c.perform("watchin")
        lastWatchLine = CACurrentMediaTime()
    }

    func stopWatching() {
        guard let c = carrot, isWatching else { return }
        isWatching = false
        watchByHand = false
        c.stopLoop()
        c.perform("watchout")
    }

    /// Checked every couple of seconds: start when a video's been playing a few seconds, stop after it's been off a bit.
    func watchTick(_ now: CFTimeInterval) {
        guard now - lastVideoCheck > 2 else { return }
        lastVideoCheck = now
        videoOn = Self.videoPlaying()
        if videoOn { noVideoSince = nil; videoSince = videoSince ?? now } else { videoSince = nil; noVideoSince = noVideoSince ?? now }
        if !isWatching, !isFocusing, let since = videoSince, now - since > 4 { startWatching() }
        if isWatching, !watchByHand, let since = noVideoSince, now - since > 8 { stopWatching() }
        // the odd comment, quietly, every few minutes
        if isWatching, now - lastWatchLine > 240 {
            lastWatchLine = now
            carrot?.say(["🍿", "good bit.", "wait what", "shh.", "one more episode.", "this is my favourite part."].randomElement()!, for: 2.5)
        }
    }

    // MARK: he misses you

    /// When you come back after a while he notices — more the longer you were gone. (Remembered across restarts.)
    private var greetedAt: Date?
    func welcomeBack(away: CFTimeInterval) {
        guard let c = carrot else { return }
        let now = Date()
        guard away < 3 else { return }                                  // only right as you come back
        defer { Profile.lastSeen = now }
        guard let last = Profile.lastSeen, !isFocusing, c.colleague.ask.isOpen == false else { return }
        let gone = now.timeIntervalSince(last)
        guard gone > 45 * 60, greetedAt.map({ now.timeIntervalSince($0) > 60 }) ?? true else { return }
        greetedAt = now
        let you = Profile.humanName.map { " \($0)" } ?? ""
        if c.isAsleep { c.wakeUp(line: "wha—? oh!") }
        switch gone {
        case ..<(4 * 3600):
            c.say(["welcome back\(you).", "oh hi\(you). missed you a little.", "there you are."].randomElement()!, for: 3.5)
        case ..<(24 * 3600):
            c.perform("land")
            c.say("you're back\(you)! i missed you.", for: 4)
        case ..<(3 * 24 * 3600):
            c.perform("cheer")
            c.say("you're back!! i missed you so much\(you.isEmpty ? "" : ",\(you)").", for: 5)
        default:
            do {
                c.say("…\(Int(gone / 86400)) days. i thought you forgot about me.", for: 4)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { c.perform("cheer"); c.say("it's okay. you're here now. 🥕", for: 4) }
            }
        }
        c.playCompletionSound()
    }

    /// What the chat window says under his name.
    var statusLine: String {
        isFocusing ? "focusing with you" : isWatching ? "watching with you"
            : carrot?.isAsleep == true ? "napping" : "at his desk"
    }

    init(carrot: WalkerCharacter) {
        self.carrot = carrot
        // listen for your AI tools on this Mac only (see ClaudeWatcher.swift; nothing calls it unless you turn the watcher on)
        DispatchQueue.main.async { carrot.claude.start() }
        _ = QuietFocus.shortcutsReady   // (warm the check)
    }

    // MARK: every frame while he's standing (and awake)

    func tick(now: CFTimeInterval, away: CFTimeInterval) {
        if let until = focusUntil, Date() >= until { endFocus(done: true) }
        if isWatching { return }
        welcomeBack(away: away)
    }

    // MARK: focusing together

    func startFocus(minutes: Int = 25) {
        guard let c = carrot, !isFocusing else { return }
        focusUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        c.perform("focusin")
        // quiet: chatty apps tucked away, and notifications off if the two shortcuts exist
        let muted = QuietFocus.begin()
        c.say(muted ? "\(minutes) minutes. notifications off. i'll be right here." :
              "\(minutes) minutes. i hid the chatty apps. (right-click me → set up DND mode, to mute notifications too.)", for: muted ? 3.5 : 6)
    }

    func endFocus(done: Bool) {
        guard isFocusing, let c = carrot else { return }
        focusUntil = nil
        QuietFocus.end()
        c.stopLoop()
        c.perform("focusout")
        c.say(done ? "done. nice work. take 5." : "okay. break time.", for: 4)
    }

}
