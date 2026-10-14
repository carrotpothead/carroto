import AVFoundation
import AppKit

/// carroto's yoga break: a 5-minute seated stretch with him (and Dig) in his little studio.
///
/// Every screen frosts over (the system's own blur, so he never sees what's behind it) and a card in the middle plays
/// the session: Outfits/yoga/yoga-break.mp4 (the studio, him, Dig, his voice and the music, made by tools/yoga-preview.py)
/// with the subtitles and the pose list from yoga-break.json drawn on top. Esc or × ends it any time.
///
/// He offers one (`YogaInvite`) after ~50 minutes of work without a break; you can
/// say yes, later, or not today. It's an invitation, never a block.
final class YogaBreak: NSObject {
    static let shared = YogaBreak()

    // MARK: settings

    static var remindAfterWork: Bool {
        get { UserDefaults.standard.object(forKey: "carrotoYogaAfterWork") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "carrotoYogaAfterWork") }
    }
    static let workMinutes: Double = 50
    /// how many breaks you've taken with him (a leaf for each, one day)
    static var breaksTaken: Int {
        get { UserDefaults.standard.integer(forKey: "carrotoYogaBreaks") }
        set { UserDefaults.standard.set(newValue, forKey: "carrotoYogaBreaks") }
    }
    /// "not today": no more invitations until tomorrow
    static var declinedToday: Bool {
        get { UserDefaults.standard.string(forKey: "carrotoYogaDeclined") == today() }
        set { UserDefaults.standard.set(newValue ? today() : nil, forKey: "carrotoYogaDeclined") }
    }
    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    static var isAvailable: Bool { videoURL != nil && session != nil }
    private static let videoURL = Bundle.main.url(forResource: "yoga-break", withExtension: "mp4", subdirectory: "Outfits/yoga")
    private static let session: Session? = {
        guard let url = Bundle.main.url(forResource: "yoga-break", withExtension: "json", subdirectory: "Outfits/yoga"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }()

    struct Session: Decodable {
        struct Pose: Decodable { let pose: String; let at: Double; let hold: Double }
        struct Line: Decodable { let at: Double; let until: Double; let text: String }
        let length: Double
        let poses: [Pose]
        let subtitles: [Line]
    }
    private static let poseNames = ["arrive": "arrive", "reach": "reach up", "sideL": "side bend", "sideR": "side bend", "chest": "chest opener",
                                    "cactus": "shoulders", "neckL": "neck", "neckR": "neck", "fold": "forward fold", "figR": "ankle over knee",
                                    "twistR": "twist", "figL": "other side", "twistL": "twist", "close": "breathe", "end": "done!"]

    let invite = YogaInvite()
    private(set) var isRunning = false
    private weak var carrot: WalkerCharacter?
    private var windows: [NSWindow] = []
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var subtitle: NSTextField?
    private var step: NSTextField?
    private var barFill: NSView?
    private var barWidth: CGFloat = 0

    // MARK: start / stop

    func start(with carrot: WalkerCharacter) {
        guard !isRunning, let url = Self.videoURL, let session = Self.session else {
            carrot.say("my yoga mat's missing. (reinstall me?)", for: 4); return
        }
        invite.close()
        isRunning = true
        self.carrot = carrot
        let main = carrot.controller?.activeScreen ?? NSScreen.main ?? NSScreen.screens[0]

        // every screen frosts over
        for screen in NSScreen.screens {
            let win = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
            win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            win.alphaValue = 0
            let frost = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            frost.material = .fullScreenUI; frost.blendingMode = .behindWindow; frost.state = .active
            let tint = NSView(frame: frost.bounds); tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true; tint.layer?.backgroundColor = Sticker.cream.withAlphaComponent(0.28).cgColor
            frost.addSubview(tint)
            win.contentView = frost
            if screen == main { frost.addSubview(card(in: frost.bounds, url: url, session: session)) }
            win.orderFrontRegardless()
            windows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first { $0.screen == main }?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(completed: false); return nil }   // esc
            return e
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.9
            for w in windows { w.animator().alphaValue = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.player?.play() }
    }

    /// The studio card: the video, the subtitle under it, which pose you're on, and a way out.
    private func card(in bounds: NSRect, url: URL, session: Session) -> NSView {
        let vw = min(bounds.width * 0.62, 1180, (bounds.height - 260) * 16 / 9)
        let vh = vw * 9 / 16
        let pad: CGFloat = 16, below: CGFloat = 104
        let w = vw + pad * 2, h = vh + pad + below
        let box = NSView(frame: NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = Sticker.cream.cgColor
        box.layer?.cornerRadius = 30
        box.layer?.borderWidth = 5
        box.layer?.borderColor = Sticker.carrotHalo.cgColor
        box.shadow = NSShadow(); box.layer?.shadowOpacity = 0.18; box.layer?.shadowRadius = 30; box.layer?.shadowOffset = CGSize(width: 0, height: -8)

        let screen = NSView(frame: NSRect(x: pad, y: below, width: vw, height: vh))
        screen.wantsLayer = true
        screen.layer?.cornerRadius = 20; screen.layer?.masksToBounds = true
        let p = AVPlayer(url: url)
        let layer = AVPlayerLayer(player: p)
        layer.frame = screen.bounds; layer.videoGravity = .resizeAspectFill
        screen.layer?.addSublayer(layer)
        box.addSubview(screen)
        player = p

        // the subtitle: what he's saying right now
        let sub = NSTextField(wrappingLabelWithString: "")
        sub.alignment = .center; sub.font = NSFont.systemFont(ofSize: 17, weight: .semibold); sub.textColor = Sticker.ink
        sub.maximumNumberOfLines = 2
        sub.frame = NSRect(x: pad + 20, y: 44, width: vw - 40, height: 48)
        box.addSubview(sub)
        subtitle = sub

        // which pose, and how far along
        let st = NSTextField(labelWithString: "")
        st.font = CarrotoFonts.hand(16); st.textColor = Sticker.brown
        st.frame = NSRect(x: pad + 4, y: 14, width: 260, height: 20)
        box.addSubview(st)
        step = st
        barWidth = vw - 280 - 120
        let bar = NSView(frame: NSRect(x: pad + 280, y: 22, width: barWidth, height: 6))
        bar.wantsLayer = true; bar.layer?.backgroundColor = Sticker.cream2.cgColor; bar.layer?.cornerRadius = 3
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 6))
        fill.wantsLayer = true; fill.layer?.backgroundColor = Sticker.cobalt.cgColor; fill.layer?.cornerRadius = 3
        bar.addSubview(fill); box.addSubview(bar)
        barFill = fill
        let hint = NSTextField(labelWithString: "esc to stop")
        hint.font = CarrotoFonts.hand(14); hint.textColor = Sticker.dim; hint.alignment = .right
        hint.frame = NSRect(x: w - pad - 110, y: 14, width: 106, height: 20)
        box.addSubview(hint)

        // ×, over the top corner of the video
        let x = NSButton(frame: NSRect(x: w - pad - 44, y: below + vh - 44, width: 32, height: 32))
        x.isBordered = false
        x.attributedTitle = NSAttributedString(string: "×", attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: Sticker.ink])
        x.wantsLayer = true; x.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor; x.layer?.cornerRadius = 16
        x.target = self; x.action = #selector(stopNow)
        box.addSubview(x)

        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            self?.update(at: t.seconds, session: session)
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            self?.finish(completed: true)
        }
        update(at: 0, session: session)
        return box
    }

    private func update(at t: Double, session: Session) {
        let line = session.subtitles.first { $0.at <= t && t < $0.until }?.text ?? ""
        if subtitle?.stringValue != line { subtitle?.stringValue = line }
        let i = session.poses.lastIndex { $0.at <= t } ?? 0
        let name = Self.poseNames[session.poses[i].pose] ?? ""
        let count = session.poses.count - 1      // (the last one is the goodbye, not a pose)
        step?.stringValue = i < count ? "\(i + 1) of \(count) · \(name)" : name
        barFill?.frame.size.width = barWidth * CGFloat(min(1, max(0, t / session.length)))
    }

    @objc private func stopNow() { finish(completed: false) }

    func finish(completed: Bool) {
        guard isRunning else { return }
        isRunning = false
        let watched = player?.currentTime().seconds ?? 0
        player?.pause()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        timeObserver = nil; endObserver = nil; keyMonitor = nil
        let wins = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            for w in wins { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in wins { w.orderOut(nil) }
        })
        player = nil; subtitle = nil; step = nil; barFill = nil
        guard let c = carrot else { return }
        if completed || watched > 60 { Self.breaksTaken += 1 }
        c.colleague.yogaDone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if completed {
                c.perform("cheer")
                c.say(Self.breaksTaken > 1 ? "break #\(Self.breaksTaken) done. proud of you 🥕" : "first one done. proud of you 🥕", for: 4)
            } else {
                c.say(watched > 60 ? "good enough. that still counts 🥕" : "ok, another time 🥕", for: 3)
            }
        }
    }
}

// MARK: - The invitation

/// A card above him: why now, and three ways to answer. Never nags: "not today" means not today.
final class YogaInvite: NSObject {
    enum Answer { case go, later, notToday }
    private var window: NSWindow?
    private var onAnswer: ((Answer) -> Void)?
    var isOpen: Bool { window != nil }

    func show(title: String, detail: String, above frame: NSRect, answer: @escaping (Answer) -> Void) {
        close()
        onAnswer = answer
        let w: CGFloat = 330, h: CGFloat = 132
        let win = KeyableWindow(contentRect: NSRect(x: frame.midX - w / 2, y: frame.maxY - frame.height * 0.08, width: w, height: h),
                                styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = true
        win.level = .statusBar + 6
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = Sticker.cream.cgColor
        box.layer?.cornerRadius = 22
        box.layer?.borderWidth = 4
        box.layer?.borderColor = Sticker.carrotHalo.cgColor

        let face = NSImageView(frame: NSRect(x: 16, y: h - 50, width: 30, height: 33)); face.image = Sticker.image("face", size: 33); box.addSubview(face)
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 13, weight: .bold); t.textColor = Sticker.ink
        t.frame = NSRect(x: 54, y: h - 40, width: w - 70, height: 18); t.lineBreakMode = .byTruncatingTail; box.addSubview(t)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = CarrotoFonts.hand(15); d.textColor = Sticker.brown; d.maximumNumberOfLines = 2
        d.frame = NSRect(x: 54, y: h - 82, width: w - 70, height: 40); box.addSubview(d)

        func pill(_ title: String, _ fill: NSColor, _ halo: NSColor, _ fg: NSColor, x: CGFloat, width: CGFloat, action: Selector) -> NSButton {
            let b = NSButton(frame: NSRect(x: x, y: 14, width: width, height: 32))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: fg])
            b.wantsLayer = true; b.layer?.backgroundColor = fill.cgColor; b.layer?.cornerRadius = 16
            b.layer?.borderWidth = 3; b.layer?.borderColor = halo.cgColor
            b.target = self; b.action = action
            return b
        }
        let small = (w - 56) * 0.3, big = (w - 56) * 0.4
        box.addSubview(pill("not today", .white, Sticker.cream2, Sticker.ink, x: 14, width: small, action: #selector(notToday)))
        box.addSubview(pill("in 10", .white, Sticker.cream2, Sticker.ink, x: 28 + small, width: small, action: #selector(later)))
        let go = pill("let's go 🧘", Sticker.cobalt, Sticker.cobaltHalo, .white, x: 42 + small * 2, width: big, action: #selector(letsGo))
        go.keyEquivalent = "\r"
        box.addSubview(go)

        win.contentView = box
        window = win
        win.orderFrontRegardless()
    }

    @objc private func letsGo() { let a = onAnswer; close(); a?(.go) }
    @objc private func later() { let a = onAnswer; close(); a?(.later) }
    @objc private func notToday() { let a = onAnswer; close(); a?(.notToday) }

    func close() { window?.orderOut(nil); window = nil; onAnswer = nil }
}
