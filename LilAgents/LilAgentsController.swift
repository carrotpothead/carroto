import AppKit

class LilAgentsController {
    var characters: [WalkerCharacter] = []
    var dog: DogCompanion?
    private var lastTick = CACurrentMediaTime()
    private var displayLink: CVDisplayLink?
    var debugWindow: NSWindow?
    var pinnedScreenIndex: Int = -1
    private static let onboardingKey = "hasCompletedOnboarding"
    private var isHiddenForEnvironment = false

    func start() {
        let carrot = WalkerCharacter(videoName: "walk-carrot-01", name: "Carroto")

        // Detect available providers, then set first-run defaults
        AgentProvider.detectAvailableProviders { [weak carrot] in
            guard let carrot = carrot else { return }
            if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
                carrot.provider = AgentProvider.firstAvailable
            }
        }

        // carroto's videos are rendered from a three.js scene
        carrot.accelStart = 3.0
        carrot.fullSpeedStart = 3.75
        carrot.decelStart = 7.5
        carrot.walkStop = 8.25
        carrot.walkAmountRange = 0.3...0.55
        carrot.yOffset = -3
        carrot.characterColor = NSColor(red: 0.96, green: 0.48, blue: 0.13, alpha: 1.0) // carrot orange
        carrot.flipXOffset = 0
        carrot.positionProgress = 0.9 // he lives at the right end of the dock
        carrot.pauseEndTime = CACurrentMediaTime() + Double.random(in: 0.5...2.0)
        // between walks he stands in a breathing loop, and now and then does a trick
        carrot.idleVideoName = "idle-carrot-01"
        carrot.tricks = [("water-carrot-01", 7.0), ("yoga-carrot-01", 9.4)]
        carrot.clips = [
            "lunch": ("lunch-carrot-01", 6.5),
            "doze": ("doze-carrot-01", 4.8),
            "wake": ("wake-carrot-01", 2.4),
            "land": ("land-carrot-01", 1.4),
            "focusin": ("focusin-carrot-01", 1.2),
            "focusout": ("focusout-carrot-01", 2.4),
            "cheer": ("cheer-carrot-01", 2.4),
            "feed": ("feed-carrot-01", 4.0),
            "watchin": ("watchin-carrot-01", 1.8),
            "watchout": ("watchout-carrot-01", 1.4),
        ]
        carrot.loops = ["sleep": "sleep-carrot-01", "dangle": "dangle-carrot-01", "focus": "focus-carrot-01", "watch": "watch-carrot-01"]
        carrot.napAfter = 10 * 60

        carrot.setup()

        characters = [carrot]
        dog = DogCompanion(following: carrot)        // his dachshund, trotting after him
        characters.forEach { $0.controller = self }

        setupDebugLine()
        startDisplayLink()

        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            triggerOnboarding()
        }
    }

    private func triggerOnboarding() {
        guard let carrot = characters.first else { return }
        carrot.isOnboarding = true
        // Show "hi!" bubble after a short delay so the character is visible first
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            carrot.currentPhrase = "hi!"
            carrot.showingCompletion = true
            carrot.completionBubbleExpiry = CACurrentMediaTime() + 600 // stays until clicked
            carrot.showBubble(text: "hi!", isCompletion: true)
            carrot.playCompletionSound()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        characters.forEach { $0.isOnboarding = false }
    }

    // MARK: - Debug

    private func setupDebugLine() {
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 2),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.red
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        win.orderOut(nil)
        debugWindow = win
    }

    private func updateDebugLine(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        guard let win = debugWindow, win.isVisible else { return }
        win.setFrame(CGRect(x: dockX, y: dockTopY, width: dockWidth, height: 2), display: true)
    }

    // MARK: - Dock Geometry

    private func getDockIconArea(screenWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let tileSize = CGFloat(dockDefaults?.double(forKey: "tilesize") ?? 48)
        let slotWidth = tileSize * 1.25

        var persistentApps = dockDefaults?.array(forKey: "persistent-apps")?.count ?? 0
        var persistentOthers = dockDefaults?.array(forKey: "persistent-others")?.count ?? 0

        // Fallback for defaults reading issues
        if persistentApps == 0 && persistentOthers == 0 {
            persistentApps = 5
            persistentOthers = 3
        }

        let showRecents = dockDefaults?.bool(forKey: "show-recents") ?? true
        let recentApps = showRecents ? (dockDefaults?.array(forKey: "recent-apps")?.count ?? 0) : 0
        let totalIcons = persistentApps + persistentOthers + recentApps

        var dividers = 0
        if persistentApps > 0 && (persistentOthers > 0 || recentApps > 0) { dividers += 1 }
        if persistentOthers > 0 && recentApps > 0 { dividers += 1 }
        if showRecents && recentApps > 0 { dividers += 1 }

        let dividerWidth: CGFloat = 12.0
        var dockWidth = slotWidth * CGFloat(totalIcons) + CGFloat(dividers) * dividerWidth

        // Small fudge factor for dock edge padding
        dockWidth *= 1.15
        let dockX = (screenWidth - dockWidth) / 2.0
        return (dockX, dockWidth)
    }

    private func dockAutohideEnabled() -> Bool {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        return dockDefaults?.bool(forKey: "autohide") ?? false
    }

    // MARK: - Display Link

    private var frameTimer: Timer?

    // carroto: a plain main-thread timer instead of CVDisplayLink. The display link sometimes
    // never starts (e.g. launched while the screen was asleep), which left him frozen at x = 0.
    private func startDisplayLink() {
        frameTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    var activeScreen: NSScreen? {
        if pinnedScreenIndex >= 0, pinnedScreenIndex < NSScreen.screens.count {
            return NSScreen.screens[pinnedScreenIndex]
        }
        // Prefer the screen that currently shows the dock (bottom inset in visibleFrame).
        // NSScreen.main changes with keyboard focus and must NOT be used here — clicking a
        // secondary display switches NSScreen.main to that display, causing characters on
        // the dock screen to be incorrectly hidden.
        if let dockScreen = NSScreen.screens.first(where: { screenHasDock($0) }) {
            return dockScreen
        }
        // Dock is auto-hidden: fall back to the primary display, identified as the screen
        // whose menu bar reserves space at the top (visibleFrame.maxY < frame.maxY).
        if let primaryScreen = NSScreen.screens.first(where: { $0.visibleFrame.maxY < $0.frame.maxY }) {
            return primaryScreen
        }
        return NSScreen.screens.first
    }

    private func screenHasDock(_ screen: NSScreen) -> Bool {
        DockVisibility.screenHasVisibleDockReservedArea(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func shouldShowCharacters(on screen: NSScreen) -> Bool {
        // User explicitly pinned to this screen — always show
        if pinnedScreenIndex >= 0, pinnedScreenIndex < NSScreen.screens.count {
            return true
        }
        return DockVisibility.shouldShowCharacters(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isMainScreen: screen == NSScreen.main,
            dockAutohideEnabled: dockAutohideEnabled()
        )
    }

    @discardableResult
    private func updateEnvironmentVisibility(for screen: NSScreen) -> Bool {
        let shouldShow = shouldShowCharacters(on: screen)
        guard shouldShow != !isHiddenForEnvironment else { return shouldShow }

        isHiddenForEnvironment = !shouldShow

        if shouldShow {
            characters.forEach { $0.showForEnvironmentIfNeeded() }
            dog?.show()
        } else {
            debugWindow?.orderOut(nil)
            characters.forEach { $0.hideForEnvironment() }
            dog?.hide()
        }

        return shouldShow
    }

    func tick() {
        guard let screen = activeScreen else { return }
        guard updateEnvironmentVisibility(for: screen) else { return }

        let screenWidth = screen.frame.width
        let dockX: CGFloat
        let dockWidth: CGFloat
        let dockTopY: CGFloat

        // Dock is on this screen — constrain to dock area
        (dockX, dockWidth) = getDockIconArea(screenWidth: screenWidth)
        dockTopY = screen.visibleFrame.origin.y

        updateDebugLine(dockX: dockX, dockWidth: dockWidth, dockTopY: dockTopY)

        let activeChars = characters.filter { $0.window.isVisible && $0.isManuallyVisible }

        let now = CACurrentMediaTime()
        let anyWalking = activeChars.contains { $0.isWalking }
        for char in activeChars {
            if char.isIdleForPopover { continue }
            if char.isPaused && now >= char.pauseEndTime && anyWalking {
                char.pauseEndTime = now + Double.random(in: 5.0...10.0)
            }
        }
        for char in activeChars {
            char.update(dockX: dockX, dockWidth: dockWidth, dockTopY: dockTopY)
        }
        let dt = CGFloat(min(now - lastTick, 0.1)); lastTick = now
        dog?.update(dockX: dockX, dockWidth: dockWidth, dockTopY: dockTopY, dt: dt)

        let sorted = activeChars.sorted { $0.positionProgress < $1.positionProgress }
        for (i, char) in sorted.enumerated() {
            char.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + i)
        }
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
