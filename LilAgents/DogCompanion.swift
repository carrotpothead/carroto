import AVFoundation
import AppKit

/// carroto's dog: a little dachshund who trots after him along the dock, stands next to him wagging,
/// and curls up to sleep when carroto naps. His clips are rendered from a three.js scene
/// into Outfits/dog/, with the same camera and size as carroto's, so they stand together.
final class DogCompanion {
    private weak var carrot: WalkerCharacter?
    private var window: NSWindow!
    private var layers: [String: AVPlayerLayer] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [AVPlayerLooper] = []
    private var current = ""
    private var x: CGFloat?                 // where his window is (left edge), in screen points
    private var walking = false
    private var facingRight = true
    private var height: CGFloat = 0
    private var hidden = false
    // treats: every so often carroto drops him a biscuit (carroto's feed clip, then his eat clip, timed to meet)
    private var nextTreatAt = CACurrentMediaTime() + Double.random(in: 4...7) * 60
    private var catchAt: CFTimeInterval = .infinity     // when his eat clip starts (as the biscuit leaves carroto's hand)
    private var eatingUntil: CFTimeInterval = 0
    static let dropAt: CFTimeInterval = 1.65            // carroto lets go 1.75s into his clip; the eat clip's biscuit appears 0.15s in
    static let eatDuration: CFTimeInterval = 4.2
    /// his tricks (each starts and ends standing): rolling on his back, chasing his tail, a play bow
    static let tricks: [(clip: String, duration: CFTimeInterval, doing: String)] = [
        ("roll", 5, "rolling around on his back, belly up"), ("spin", 3.5, "chasing his own tail"), ("bow", 3, "doing a play bow at you, tail going"),
    ]
    private var nextTrickAt = CACurrentMediaTime() + Double.random(in: 3...8) * 60
    private var trickUntil: CFTimeInterval = 0
    private var trickDoing = ""
    /// across carroto's clip frame, where his hand is when he lets go of the biscuit (from his feed render, facing right)
    static let handFrac: CGFloat = 0.91
    /// across the dog's clip frame, where his nose is (facing right)
    static let noseFrac: CGFloat = 0.866
    /// how big he is next to carroto (his clips share carroto's camera; this scales them up from there)
    static let scale: CGFloat = 1.2

    init?(following carrot: WalkerCharacter) {
        self.carrot = carrot
        for clip in ["walk", "idle", "sleep", "eat", "rest", "yoga"] + Self.tricks.map(\.clip) {
            guard let url = Bundle.main.url(forResource: "\(clip)-dog-01", withExtension: "mov", subdirectory: "Outfits/dog") else { return nil }
            let player = AVQueuePlayer()
            loopers.append(AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: AVAsset(url: url))))
            player.isMuted = true
            players[clip] = player
        }
        height = carrot.displayHeight * Self.scale
        let w = height * 1080 / 1920
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true                      // clicks go through him (to carroto, or the dock)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)   // just behind carroto
        window.collectionBehavior = [.moveToActiveSpace, .stationary]
        let view = NSView(frame: CGRect(x: 0, y: 0, width: w, height: height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        for (clip, player) in players {
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.clear.cgColor
            layer.frame = view.bounds
            layer.isHidden = true
            view.layer?.addSublayer(layer)
            layers[clip] = layer
        }
        window.contentView = view
        play("idle")
        window.orderFrontRegardless()
        // when carroto does yoga, dig does it with him (his yoga clip is timed to carroto's: downward dog, then upward dog)
        carrot.onTrick = { [weak self] video in if video.hasPrefix("yoga") { self?.joinYoga() } }
    }

    private func play(_ clip: String, fromStart: Bool = false) {
        guard clip != current else { return }
        if fromStart { players[clip]?.seek(to: .zero) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (name, layer) in layers { layer.isHidden = name != clip }
        CATransaction.commit()
        for (name, player) in players { if name == clip { player.play() } else { player.pause() } }
        current = clip
    }

    private func face(right: Bool) {
        guard right != facingRight else { return }
        facingRight = right
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in layers.values { layer.transform = right ? CATransform3DIdentity : CATransform3DMakeScale(-1, 1, 1) }
        CATransaction.commit()
    }

    private func joinYoga() {
        let now = CACurrentMediaTime()
        guard !walking, now >= eatingUntil, catchAt == .infinity, now >= trickUntil else { return }
        trickUntil = now + 9.4
        trickDoing = "doing yoga with you (downward dog, obviously, then upward dog)"
        play("yoga", fromStart: true)
    }

    func hide() { hidden = true; window.orderOut(nil); players[current]?.pause() }
    func show() { hidden = false; window.orderFrontRegardless(); players[current]?.play() }

    /// called every frame by the controller, after carroto has moved
    func update(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat, dt: CGFloat) {
        guard let carrot = carrot, let cw = carrot.window else { return }
        // he's only out when carroto is
        if !cw.isVisible { if !hidden { hide() }; return } else if hidden { show() }

        // same size as carroto (the clips share a camera)
        if carrot.displayHeight * Self.scale != height {
            height = carrot.displayHeight * Self.scale
            let w = height * 1080 / 1920
            window.setContentSize(NSSize(width: w, height: height))
            window.contentView?.frame = CGRect(x: 0, y: 0, width: w, height: height)
            for layer in layers.values { layer.frame = CGRect(x: 0, y: 0, width: w, height: height) }
        }
        let w = window.frame.width

        // he keeps to carroto's side that faces the middle of the dock
        let mid = dockX + dockWidth / 2
        let side: CGFloat = cw.frame.midX > mid ? -1 : 1
        let lo = dockX, hi = max(dockX, dockX + dockWidth - w)
        // he stands with his nose right under carroto's hand (where carroto drops his biscuits; the eat clip relies on it)
        let handX = cw.frame.minX + cw.frame.width * (side < 0 ? 1 - Self.handFrac : Self.handFrac)
        let target = min(max(handX - w * (side < 0 ? Self.noseFrac : 1 - Self.noseFrac), lo), hi)
        var px = x ?? target

        let speed = 52 * height / 200                          // points a second at full trot
        let gap = target - px
        if carrot.isBeingDragged {
            walking = false                                     // carroto's been picked up: he waits where he is
        } else if walking {
            let step = min(abs(gap), speed * dt)
            px += gap > 0 ? step : -step
            face(right: gap > 0)
            if abs(gap) < 2 { walking = false }
        } else if abs(gap) > w * (carrot.isWalking ? 0.12 : 0.35) {     // keeps up while carroto walks; doesn't fuss over a few steps
            walking = true
        }
        x = px

        // treat time
        let now = CACurrentMediaTime()
        if now >= catchAt {
            catchAt = .infinity
            eatingUntil = now + Self.eatDuration
            face(right: cw.frame.midX > px + w / 2)
            play("eat", fromStart: true)
        }
        // a trick now and then, while he's just standing about
        if now < trickUntil {
            Profile.dogDoing = trickDoing
            window.setFrameOrigin(NSPoint(x: px, y: dockTopY + carrot.yOffset - height * 0.15)); return
        }
        if now >= nextTrickAt, !walking, now >= eatingUntil, catchAt == .infinity, abs(gap) < w * 0.35,
           !carrot.isAsleep, !carrot.isSettledDown, !carrot.isBeingDragged {
            nextTrickAt = now + Double.random(in: 3...8) * 60
            if let t = Self.tricks.randomElement() {
                trickUntil = now + t.duration; trickDoing = t.doing
                face(right: cw.frame.midX > px + w / 2)
                play(t.clip, fromStart: true)
                if carrot.isPaused, !carrot.isDoingTrick, Bool.random() {
                    let d = Profile.dogName
                    DispatchQueue.main.asyncAfter(deadline: .now() + t.duration * 0.6) {
                        carrot.say(["good boy, \(d)!", "show off.", "\(d)! 👏", "he's been practising", "10/10, \(d)"].randomElement()!, for: 2)
                    }
                }
                window.setFrameOrigin(NSPoint(x: px, y: dockTopY + carrot.yOffset - height * 0.15)); return
            }
        }
        if now < eatingUntil || catchAt < .infinity {
            if now < eatingUntil { Profile.dogDoing = "munching the biscuit you just gave him"; window.setFrameOrigin(NSPoint(x: px, y: dockTopY + carrot.yOffset - height * 0.15)); return }
        } else if now >= nextTreatAt, !walking, abs(gap) >= 3, !carrot.isAsleep, !carrot.isWalking {
            walking = true                                      // treat time: trot the last bit, right under carroto's hand
        } else if now >= nextTreatAt, !walking, abs(gap) < 3, !carrot.isAsleep {
            if carrot.feedDog(dogIsToTheRight: px + w / 2 > cw.frame.midX) {
                catchAt = now + Self.dropAt
                nextTreatAt = now + Double.random(in: 25...45) * 60
            } else {
                nextTreatAt = now + 30                          // he's busy: try again in a bit
            }
        }

        Profile.dogDoing = now < eatingUntil ? "munching the biscuit you just gave him"
            : walking ? "trotting after you"
            : carrot.isAsleep ? "asleep next to you, flat on his tummy"
            : carrot.isSettledDown ? "lying on the floor next to you, keeping you company while you're busy" : "standing next to you, wagging"
        if walking { play("walk") }
        else {
            face(right: cw.frame.midX > px + w / 2)             // standing: he looks at carroto
            play(carrot.isAsleep ? "sleep" : carrot.isSettledDown ? "rest" : "idle")   // lies down while carroto works
        }
        let y = dockTopY + carrot.yOffset - height * 0.15            // the ground sits 15% up the clip, so his feet meet carroto's
        window.setFrameOrigin(NSPoint(x: px, y: y))
    }
}
