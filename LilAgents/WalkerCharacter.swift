import AVFoundation
import AppKit

enum CharacterSize: String, CaseIterable {
    case large, medium, small
    var height: CGFloat {
        switch self {
        case .large: return 200
        case .medium: return 150
        case .small: return 100
        }
    }
    var displayName: String {
        switch self {
        case .large: return "Large"
        case .medium: return "Medium"
        case .small: return "Small"
        }
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run(_ sender: Any?) { block() }
}

class WalkerCharacter {
    let videoName: String
    let name: String
    var provider: AgentProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: "\(name)Provider") ?? "claude"
            return AgentProvider(rawValue: raw) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "\(name)Provider")
        }
    }
    var size: CharacterSize {
        get {
            let raw = UserDefaults.standard.string(forKey: "\(name)Size") ?? "big"
            return CharacterSize(rawValue: raw) ?? .large
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "\(name)Size")
            updateDimensions()
        }
    }
    var window: NSWindow!
    var playerLayer: AVPlayerLayer!
    var queuePlayer: AVQueuePlayer!
    var looper: AVPlayerLooper!

    // carroto: a standing loop between walks, and one-off tricks (watering, yoga)
    var idleVideoName: String?
    var tricks: [(video: String, duration: CFTimeInterval)] = []
    var trickChance = 0.35
    private var idlePlayer: AVQueuePlayer?
    private var idleLooper: AVPlayerLooper?
    private var idleLayer: AVPlayerLayer?
    private var trickPlayer = AVPlayer()
    private var trickLayer: AVPlayerLayer?
    private(set) var isDoingTrick = false
    private var trickEndTime: CFTimeInterval = 0

    // carroto: picked up and carried around, then dropped back onto the dock
    private(set) var isBeingDragged = false

    // carroto: where on the dock he lives (0 = left end, 1 = right end), and his hourly stroll
    var homeRange: ClosedRange<CGFloat> = 0.8...1.0
    private var destination: CGFloat?
    private var nextTripAt = CACurrentMediaTime() + Double.random(in: 45...75) * 60
    private var dragOffset = NSPoint.zero
    private var droppedAtX: CGFloat?
    private var dropFromY: CGFloat = 0
    private var dropStart: CFTimeInterval = -10
    private let dropDuration: CFTimeInterval = 0.35
    var canBeDragged: Bool { !isIdleForPopover && !isOnboarding }

    let videoWidth: CGFloat = 1080
    let videoHeight: CGFloat = 1920
    private(set) var displayHeight: CGFloat = 200
    var displayWidth: CGFloat { displayHeight * (videoWidth / videoHeight) }

    // Walk timing (per-character, from frame analysis)
    let videoDuration: CFTimeInterval = 10.0
    var accelStart: CFTimeInterval = 3.0
    var fullSpeedStart: CFTimeInterval = 3.75
    var decelStart: CFTimeInterval = 7.5
    var walkStop: CFTimeInterval = 8.25
    var walkAmountRange: ClosedRange<CGFloat> = 0.25...0.5
    var yOffset: CGFloat = 0
    var flipXOffset: CGFloat = 0
    var characterColor: NSColor = .gray

    // Walk state
    var playCount = 0
    var walkStartTime: CFTimeInterval = 0
    var positionProgress: CGFloat = 0.0
    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true
    var walkStartPos: CGFloat = 0.0
    var walkEndPos: CGFloat = 0.0
    var currentTravelDistance: CGFloat = 500.0
    // Walk endpoints stored in pixels for consistent speed across screen switches
    var walkStartPixel: CGFloat = 0.0
    var walkEndPixel: CGFloat = 0.0

    // Onboarding
    var isOnboarding = false

    // Popover state
    var isIdleForPopover = false
    var popoverWindow: NSWindow?
    /// "at his desk" / "focusing with you" (the sticker look's header)
    weak var statusLabel: NSTextField?
    var terminalView: TerminalView?
    var session: (any AgentSession)?
    var clickOutsideMonitor: Any?
    var escapeKeyMonitor: Any?
    var currentStreamingText = ""
    weak var controller: LilAgentsController?
    var themeOverride: PopoverTheme?
    var isAgentBusy: Bool { session?.isBusy ?? false }
    var thinkingBubbleWindow: NSWindow?
    private(set) var isManuallyVisible = true
    private var environmentHiddenAt: CFTimeInterval?
    private var wasPopoverVisibleBeforeEnvironmentHide = false
    private var wasBubbleVisibleBeforeEnvironmentHide = false

    init(videoName: String, name: String) {
        self.videoName = videoName
        self.name = name
        self.displayHeight = size.height
    }

    // MARK: - Setup

    func updateDimensions() {
        displayHeight = size.height
        let newWidth = displayWidth
        let newHeight = displayHeight
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            let oldFrame = window.frame
            let newFrame = CGRect(x: oldFrame.origin.x, y: oldFrame.origin.y, width: newWidth, height: newHeight)
            
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(newFrame, display: true)
            for layer in self.allLayers { layer.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight) }
            if let hostView = window.contentView {
                hostView.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
            }
            CATransaction.commit()
            
            self.updateFlip()
        }
    }

    func setup() {
        guard let videoURL = Outfit.url(videoName) else {
            print("Video \(videoName) not found")
            return
        }

        let asset = AVAsset(url: videoURL)
        queuePlayer = AVQueuePlayer()
        looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(asset: asset))

        playerLayer = AVPlayerLayer(player: queuePlayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

        let screen = NSScreen.main!
        let dockTopY = screen.visibleFrame.origin.y
        let bottomPadding = displayHeight * 0.15
        let y = dockTopY - bottomPadding + yOffset

        let contentRect = CGRect(x: 0, y: y, width: displayWidth, height: displayHeight)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.moveToActiveSpace, .stationary]

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.addSublayer(playerLayer)
        setupExtraLayers(in: hostView)

        window.contentView = hostView
        window.orderFrontRegardless()
    }

    // MARK: - Visibility

    func setManuallyVisible(_ visible: Bool) {
        isManuallyVisible = visible
        if visible {
            if environmentHiddenAt == nil {
                window.orderFrontRegardless()
            }
        } else {
            queuePlayer.pause()
            window.orderOut(nil)
            popoverWindow?.orderOut(nil)
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    func hideForEnvironment() {
        guard environmentHiddenAt == nil else { return }

        environmentHiddenAt = CACurrentMediaTime()
        wasPopoverVisibleBeforeEnvironmentHide = popoverWindow?.isVisible ?? false
        wasBubbleVisibleBeforeEnvironmentHide = thinkingBubbleWindow?.isVisible ?? false

        queuePlayer.pause()
        idlePlayer?.pause()
        trickPlayer.pause()
        window.orderOut(nil)
        popoverWindow?.orderOut(nil)
        thinkingBubbleWindow?.orderOut(nil)
    }

    func showForEnvironmentIfNeeded() {
        guard let hiddenAt = environmentHiddenAt else { return }

        let hiddenDuration = CACurrentMediaTime() - hiddenAt
        environmentHiddenAt = nil
        walkStartTime += hiddenDuration
        pauseEndTime += hiddenDuration
        completionBubbleExpiry += hiddenDuration
        lastPhraseUpdate += hiddenDuration

        guard isManuallyVisible else { return }

        window.orderFrontRegardless()
        trickEndTime += hiddenDuration
        if isWalking {
            queuePlayer.play()
        } else if isDoingTrick {
            trickPlayer.play()
        } else {
            idlePlayer?.play()
        }

        if isIdleForPopover && wasPopoverVisibleBeforeEnvironmentHide {
            updatePopoverPosition()
            popoverWindow?.orderFrontRegardless()
            popoverWindow?.makeKey()
            if let terminal = terminalView {
                popoverWindow?.makeFirstResponder(terminal.inputField)
            }
        }

        if wasBubbleVisibleBeforeEnvironmentHide {
            updateThinkingBubble()
        }
    }

    // MARK: - Click Handling & Popover

    func handleClick() {
        // a click wakes him up first; the next one opens the chat
        if isAsleep { wakeUp(line: "wha—? i'm up."); return }
        // if he asked you something, clicking him answers it
        if isOnboarding {
            adopt()
            return
        }
        if isIdleForPopover {
            closePopover()
        } else {
            openPopover()
        }
    }

    /// Meeting for the first time: he asks what you'll call him, and what he should call you.
    private func adopt() {
        let c = colleague
        c.ask.open(question: "hi! i'm your new carrot. what do you want to call me?", placeholder: "carroto", above: window.frame) { [weak self] name in
            guard let self = self else { return }
            Profile.petName = name
            self.say("\(Profile.petName). i love it.", for: 2.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                guard let self = self else { return }
                c.ask.open(question: "and what should i call you?", placeholder: "your name", above: self.window.frame) { [weak self] you in
                    Profile.humanName = you
                    self?.say("nice to meet you, \(Profile.humanName ?? "friend"). i'll be right here on the dock.", for: 4)
                    self?.playCompletionSound()
                }
            }
        }
        // done either way (if they click away, he's still theirs; they can name him later from his menu)
        hideBubble()
        isOnboarding = false
        controller?.completeOnboarding()
    }

    func renameMe() {
        colleague.ask.open(question: "what should my name be?", placeholder: Profile.petName, above: window.frame) { [weak self] name in
            Profile.petName = name
            self?.say("\(Profile.petName). yes. that's me.", for: 3)
        }
    }

    func renameDog() {
        colleague.ask.open(question: "what should my dog be called?", placeholder: Profile.dogName, above: window.frame) { [weak self] name in
            Profile.dogName = name
            self?.say("\(Profile.dogName)! c'mere, \(Profile.dogName).", for: 3)
        }
    }

    func callYou() {
        colleague.ask.open(question: "what should i call you?", placeholder: Profile.humanName ?? "your name", above: window.frame) { [weak self] you in
            Profile.humanName = you
            self?.say("got it, \(Profile.humanName ?? "friend").", for: 2.5)
        }
    }

    /// change his look: saved, then he pops back in wearing it (a quick relaunch swaps all his clips)
    func wear(_ o: Outfit) {
        guard o != Outfit.current else { say("already wearing it.", for: 2); return }
        Outfit.current = o
        say("one sec. changing.", for: 1.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-n", Bundle.main.bundlePath]
            try? p.run()
            NSApp.terminate(nil)
        }
    }

    func setUpQuietFocus() {
        if QuietFocus.shortcutsReady { say("DND mode is all set. notifications go off when we focus.", for: 4); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
        InfoCard.shared.show(lines: [.title("set up DND mode")] + QuietFocus.setupSteps.components(separatedBy: "\n").map { .note($0) }, above: window.frame, width: 360)
    }

    private func openOnboardingPopover() {
        showingCompletion = false
        hideBubble()

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        standStill()

        if popoverWindow == nil {
            createPopoverWindow()
        }

        // Show static welcome message instead of Claude terminal
        terminalView?.inputField.isEditable = false
        terminalView?.inputField.placeholderString = ""
        let welcome = """
        hi! i'm carroto. i live on your dock now. the long one is dig, my dog.

        click me to open a Claude AI chat. i'll walk around while you work and let you know when Claude's thinking.

        check the menu bar icon (top right) for themes, sounds, and more options.

        click anywhere outside to dismiss, then click me again to start chatting.
        """
        terminalView?.appendStreamingText(welcome)
        terminalView?.endStreaming()

        updatePopoverPosition()
        popoverWindow?.orderFrontRegardless()

        // Set up click-outside to dismiss and complete onboarding
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.closeOnboarding()
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeOnboarding(); return nil }
            return event
        }
    }

    private func closeOnboarding() {
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor); clickOutsideMonitor = nil }
        if let monitor = escapeKeyMonitor { NSEvent.removeMonitor(monitor); escapeKeyMonitor = nil }
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        isIdleForPopover = false
        isOnboarding = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 1.0...3.0)
        standStill()
        controller?.completeOnboarding()
    }

    func openPopover() {
        // Close any other open popover
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self && sibling.isIdleForPopover {
                sibling.closePopover()
            }
        }

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        standStill()

        // Always clear any bubble (thinking or completion) when popover opens
        showingCompletion = false
        hideBubble()

        if session == nil {
            let newSession = provider.createSession()
            session = newSession
            wireSession(newSession)
            newSession.start()
        }

        if popoverWindow == nil {
            createPopoverWindow()
        }
        statusLabel?.stringValue = colleague.statusLine

        if let terminal = terminalView, let session = session, !session.history.isEmpty {
            terminal.replayHistory(session.history)
        }

        updatePopoverPosition()
        popoverWindow?.orderFrontRegardless()
        popoverWindow?.makeKey()

        if let terminal = terminalView {
            popoverWindow?.makeFirstResponder(terminal.inputField)
        }

        // Remove old monitors before adding new ones
        removeEventMonitors()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.popoverWindow else { return }
            let popoverFrame = popover.frame
            let charFrame = self.window.frame
            if !popoverFrame.contains(NSEvent.mouseLocation) && !charFrame.contains(NSEvent.mouseLocation) {
                self.closePopover()
            }
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    func closePopover() {
        guard isIdleForPopover else { return }

        popoverWindow?.orderOut(nil)
        removeEventMonitors()

        isIdleForPopover = false

        // If still waiting for a response, show thinking bubble immediately
        // If completion came while popover was open, show completion bubble
        if showingCompletion {
            // Reset expiry so user gets the full 3s from now
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isAgentBusy {
            // Force a fresh phrase pick and show immediately
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        let delay = Double.random(in: 2.0...5.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    private func removeEventMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    var resolvedTheme: PopoverTheme {
        (themeOverride ?? PopoverTheme.current).withCharacterColor(characterColor).withCustomFont()
    }

    func createPopoverWindow() {
        let t = resolvedTheme
        let stickerLook = t.name == "Stickers"
        let popoverWidth: CGFloat = stickerLook ? 400 : 420
        let popoverHeight: CGFloat = stickerLook ? 500 : 310
        let barH: CGFloat = stickerLook ? 62 : 28

        let win = KeyableWindow(
            contentRect: CGRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBar = NSView(frame: NSRect(x: 0, y: popoverHeight - barH, width: popoverWidth, height: barH))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
        container.addSubview(titleBar)

        let titleLabel = NSTextField(labelWithString: t.titleString(for: provider))
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 12, y: 6)
        titleBar.addSubview(titleLabel)
        if stickerLook {
            // his face, his name in the chunky font, and what he's up to in the hand font
            let face = NSImageView(frame: NSRect(x: 16, y: 9, width: 42, height: 46))
            face.image = Sticker.image("face", size: 46)
            titleBar.addSubview(face)
            titleLabel.stringValue = Profile.petName
            titleLabel.font = CarrotoFonts.display(19)
            titleLabel.sizeToFit()
            titleLabel.frame.origin = NSPoint(x: 66, y: 30)
            let status = NSTextField(labelWithString: colleague.statusLine)
            status.font = CarrotoFonts.hand(14.5)
            status.textColor = Sticker.brown
            status.frame = NSRect(x: 66, y: 9, width: popoverWidth - 140, height: 20)
            status.lineBreakMode = .byTruncatingTail
            titleBar.addSubview(status)
            statusLabel = status
        }

        let arrowBtn = NSButton(frame: NSRect(x: titleLabel.frame.maxX + 2, y: stickerLook ? 33 : 5, width: 16, height: 16))
        arrowBtn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Switch provider")
        arrowBtn.imageScaling = .scaleProportionallyDown
        arrowBtn.bezelStyle = .inline
        arrowBtn.isBordered = false
        arrowBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        arrowBtn.target = self
        arrowBtn.action = #selector(showProviderMenu(_:))
        titleBar.addSubview(arrowBtn)

        // Make the title label clickable too
        let clickArea = NSButton(frame: NSRect(x: stickerLook ? 60 : 0, y: stickerLook ? 28 : 0, width: arrowBtn.frame.maxX + 4 - (stickerLook ? 60 : 0), height: 28))
        clickArea.isTransparent = true
        clickArea.target = self
        clickArea.action = #selector(showProviderMenu(_:))
        titleBar.addSubview(clickArea)

        let refreshBtn = NSButton(frame: NSRect(x: popoverWidth - (stickerLook ? 58 : 48), y: stickerLook ? 24 : 5, width: 16, height: 16))
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshBtn.imageScaling = .scaleProportionallyDown
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        refreshBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshSessionFromButton)
        titleBar.addSubview(refreshBtn)

        let copyBtn = NSButton(frame: NSRect(x: popoverWidth - (stickerLook ? 34 : 28), y: stickerLook ? 24 : 5, width: 16, height: 16))
        copyBtn.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        copyBtn.imageScaling = .scaleProportionallyDown
        copyBtn.bezelStyle = .inline
        copyBtn.isBordered = false
        copyBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        copyBtn.target = self
        copyBtn.action = #selector(copyLastResponseFromButton)
        titleBar.addSubview(copyBtn)

        let sep = NSView(frame: NSRect(x: 0, y: popoverHeight - barH - 1, width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        container.addSubview(sep)

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight - barH - 1))
        terminal.characterColor = characterColor
        terminal.themeOverride = themeOverride
        terminal.provider = provider
        terminal.autoresizingMask = [.width, .height]
        terminal.onSendMessage = { [weak self, weak terminal] message in
            self?.session?.send(message: message)
        }
        terminal.onClearRequested = { [weak self] in
            self?.resetSession()
        }
        if stickerLook {
            // quick replies: the things you do most
            terminal.chips = [("say hi", .white, Sticker.cream2), ("cheer me up", Sticker.sunny, Sticker.sunnyHalo), ("tell me something", Sticker.cobaltHalo, Sticker.lilac)]
            terminal.onChip = { [weak terminal] i in terminal?.submitText(["hi carroto", "cheer me up a little", "tell me something interesting"][i]) }
        }
        container.addSubview(terminal)

        win.contentView = container
        popoverWindow = win
        terminalView = terminal
    }

    func resetSession() {
        session?.terminate()
        session = nil
        currentStreamingText = ""
        showingCompletion = false
        currentPhrase = ""
        completionBubbleExpiry = 0
        hideBubble()
        terminalView?.resetState()
        terminalView?.showSessionMessage()
        let newSession = provider.createSession()
        session = newSession
        wireSession(newSession)
        newSession.start()
    }

    private func wireSession(_ session: any AgentSession) {
        session.onText = { [weak self] text in
            self?.currentStreamingText += text
            self?.terminalView?.appendStreamingText(text)
        }

        session.onTurnComplete = { [weak self] in
            self?.terminalView?.endStreaming()
            self?.playCompletionSound()
            self?.showCompletionBubble()
        }

        session.onError = { [weak self] text in
            self?.terminalView?.appendError(text)
        }

        session.onToolUse = { [weak self] toolName, input in
            guard let self = self else { return }
            let summary = self.formatToolInput(input)
            self.terminalView?.appendToolUse(toolName: toolName, summary: summary)
        }

        session.onToolResult = { [weak self] summary, isError in
            self?.terminalView?.appendToolResult(summary: summary, isError: isError)
        }

        session.onProcessExit = { [weak self] in
            guard let self = self else { return }
            self.terminalView?.endStreaming()
            self.terminalView?.appendError("\(self.provider.displayName) session ended.")
        }

        session.onSessionReady = { }
    }

    @objc func showProviderMenu(_ sender: Any) {
        let menu = NSMenu()
        let menuFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        for p in AgentProvider.allCases {
            let item = NSMenuItem(title: p.displayName, action: #selector(providerMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: p.displayName, attributes: [.font: menuFont])
            item.representedObject = p.rawValue
            if p == provider {
                item.state = .on
            }
            if !p.isAvailable {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        // Show menu below the title bar area
        if let titleBar = popoverWindow?.contentView?.subviews.first(where: { $0.frame.origin.y > 0 && $0.frame.height == 28 }) {
            menu.popUp(positioning: nil, at: NSPoint(x: 10, y: 0), in: titleBar)
        }
    }

    @objc func providerMenuItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let newProvider = AgentProvider(rawValue: raw),
              newProvider != provider else { return }
        provider = newProvider
        // Terminate existing session and rebuild popover for new provider
        session?.terminate()
        session = nil
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        thinkingBubbleWindow?.orderOut(nil)
        thinkingBubbleWindow = nil
        openPopover()
    }

    @objc func copyLastResponseFromButton() {
        terminalView?.handleSlashCommandPublic("/copy")
    }

    @objc func refreshSessionFromButton() {
        guard !isOnboarding else { return }
        resetSession()
    }

    private func formatToolInput(_ input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return path }
        if let pattern = input["pattern"] as? String { return pattern }
        return input.keys.sorted().prefix(3).joined(separator: ", ")
    }

    func updatePopoverPosition() {
        guard let popover = popoverWindow, isIdleForPopover else { return }
        guard let screen = NSScreen.main else { return }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        let y = charFrame.maxY - 15

        let screenFrame = screen.frame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, screenFrame.maxY - popoverSize.height - 4)

        popover.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    // MARK: - Thinking Bubble

    private static let thinkingPhrases = [
        "hmm...", "thinking...", "one sec...", "ok hold on",
        "let me check", "working on it", "almost...", "bear with me",
        "on it!", "gimme a sec", "brb", "processing...",
        "hang tight", "just a moment", "figuring it out",
        "crunching...", "reading...", "looking...",
        "cooking...", "vibing...", "digging in",
        "connecting dots", "give me a sec",
        "don't rush me", "calculating...", "assembling\u{2026}"
    ]

    private static let completionPhrases = [
        "done!", "all set!", "ready!", "here you go", "got it!",
        "finished!", "ta-da!", "voila!",
        "boom!", "there ya go!", "check it out!"
    ]

    private var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""
    var completionBubbleExpiry: CFTimeInterval = 0
    var showingCompletion = false

    private static let bubbleH: CGFloat = 26
    private var phraseAnimating = false

    func updateThinkingBubble() {
        let now = CACurrentMediaTime()

        if showingCompletion {
            if now >= completionBubbleExpiry {
                showingCompletion = false
                hideBubble()
                return
            }
            if isIdleForPopover {
                completionBubbleExpiry += 1.0 / 60.0
                hideBubble()
            } else {
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }

        if isAgentBusy && !isIdleForPopover {
            let oldPhrase = currentPhrase
            updateThinkingPhrase()
            if currentPhrase != oldPhrase && !oldPhrase.isEmpty && !phraseAnimating {
                animatePhraseChange(to: currentPhrase, isCompletion: false)
            } else if !phraseAnimating {
                showBubble(text: currentPhrase, isCompletion: false)
            }
        } else if !showingCompletion {
            hideBubble()
        }
    }

    private func hideBubble() {
        if thinkingBubbleWindow?.isVisible ?? false {
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    private func animatePhraseChange(to newText: String, isCompletion: Bool) {
        guard let win = thinkingBubbleWindow, win.isVisible,
              let label = win.contentView?.viewWithTag(100) as? NSTextField else {
            showBubble(text: newText, isCompletion: isCompletion)
            return
        }
        phraseAnimating = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            label.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.showBubble(text: newText, isCompletion: isCompletion)
            label.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                label.animator().alphaValue = 1.0
            }, completionHandler: {
                self?.phraseAnimating = false
            })
        })
    }

    func showBubble(text: String, isCompletion: Bool) {
        let t = resolvedTheme
        if thinkingBubbleWindow == nil {
            createThinkingBubble()
        }

        let h = Self.bubbleH
        let padding: CGFloat = 16
        let font = t.bubbleFont
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubbleW = max(ceil(textSize.width) + padding * 2, 48)

        let charFrame = window.frame
        // lying down asleep his head is much lower (and off to the left)
        let x = charFrame.midX - bubbleW / 2 - (isAsleep ? charFrame.width * 0.12 : 0)
        let y = charFrame.origin.y + charFrame.height * (isAsleep ? 0.58 : 0.88)
        thinkingBubbleWindow?.setFrame(CGRect(x: x, y: y, width: bubbleW, height: h), display: false)

        let borderColor = isCompletion ? t.bubbleCompletionBorder.cgColor : t.bubbleBorder.cgColor
        let textColor = isCompletion ? t.bubbleCompletionText : t.bubbleText

        if let container = thinkingBubbleWindow?.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bubbleW, height: h)
            container.layer?.backgroundColor = t.bubbleBg.cgColor
            container.layer?.cornerRadius = t.bubbleCornerRadius
            container.layer?.borderColor = borderColor
            if let label = container.viewWithTag(100) as? NSTextField {
                label.font = font
                let lineH = ceil(textSize.height)
                let labelY = round((h - lineH) / 2) - 1
                label.frame = NSRect(x: 0, y: labelY, width: bubbleW, height: lineH + 2)
                label.stringValue = text
                label.textColor = textColor
            }
        }

        if !(thinkingBubbleWindow?.isVisible ?? false) {
            thinkingBubbleWindow?.alphaValue = 1.0
            thinkingBubbleWindow?.orderFrontRegardless()
        }
    }

    private func updateThinkingPhrase() {
        let now = CACurrentMediaTime()
        if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
            var next = Self.thinkingPhrases.randomElement() ?? "..."
            while next == currentPhrase && Self.thinkingPhrases.count > 1 {
                next = Self.thinkingPhrases.randomElement() ?? "..."
            }
            currentPhrase = next
            lastPhraseUpdate = now
        }
    }

    func showCompletionBubble() {
        currentPhrase = Self.completionPhrases.randomElement() ?? "done!"
        showingCompletion = true
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        lastPhraseUpdate = 0
        phraseAnimating = false
        if !isIdleForPopover {
            showBubble(text: currentPhrase, isCompletion: true)
        }
    }

    private func createThinkingBubble() {
        let t = resolvedTheme
        let w: CGFloat = 80
        let h = Self.bubbleH
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.bubbleBg.cgColor
        container.layer?.cornerRadius = t.bubbleCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = t.bubbleBorder.cgColor

        let font = t.bubbleFont
        let lineH = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        let labelY = round((h - lineH) / 2) - 1

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = t.bubbleText
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: labelY, width: w, height: lineH + 2)
        label.tag = 100
        container.addSubview(label)

        win.contentView = container
        thinkingBubbleWindow = win
    }

    // MARK: - Completion Sound

    static var soundsEnabled = true

    private static let completionSounds: [(name: String, ext: String)] = [
        ("ping-aa", "mp3"), ("ping-bb", "mp3"), ("ping-cc", "mp3"),
        ("ping-dd", "mp3"), ("ping-ee", "mp3"), ("ping-ff", "mp3"),
        ("ping-gg", "mp3"), ("ping-hh", "mp3"), ("ping-jj", "m4a")
    ]
    private static var lastSoundIndex: Int = -1

    func playCompletionSound() {
        guard Self.soundsEnabled else { return }
        var idx: Int
        repeat {
            idx = Int.random(in: 0..<Self.completionSounds.count)
        } while idx == Self.lastSoundIndex && Self.completionSounds.count > 1
        Self.lastSoundIndex = idx

        let s = Self.completionSounds[idx]
        if let url = Bundle.main.url(forResource: s.name, withExtension: s.ext, subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Idle loop, tricks, nap, lunch, dangling (carroto)
    //
    // Four video layers, only one visible at a time (they're all transparent):
    //   walk  - the lil-agents walk video
    //   idle  - a breathing loop while he stands
    //   once  - a one-off clip (tricks, lunch, dozing off, waking, landing)
    //   loop  - a held state (asleep, dangling while dragged)

    private var allLayers: [AVPlayerLayer] { [playerLayer, idleLayer, trickLayer, loopLayer].compactMap { $0 } }
    private let loopPlayer = AVQueuePlayer()
    private var loopLooper: AVPlayerLooper?
    private var loopLayer: AVPlayerLayer?
    private var onceDone: (() -> Void)?
    private(set) var loopingName: String?

    /// one-off clips by name, and looping ones, set up by the controller
    var clips: [String: (video: String, duration: CFTimeInterval)] = [:]
    var loops: [String: String] = [:]
    var napAfter: CFTimeInterval = 600
    private(set) var isAsleep = false
    private var asleepSince: CFTimeInterval = 0
    private var lastZzz: CFTimeInterval = 0
    private var landingPending = false
    private static let lunchKey = "carrotoLastLunch"
    /// the work-colleague side of him (see Colleague.swift)
    lazy var colleague = Colleague(carrot: self)
    /// watches your Claude Code sessions (permission requests, done, waiting) — see ClaudeWatcher.swift
    lazy var claude = ClaudeWatcher(carrot: self)
    var lunchedToday: Bool {
        UserDefaults.standard.double(forKey: Self.lunchKey) == Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }

    private func makeLayer(_ player: AVPlayer, in view: NSView) -> AVPlayerLayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        layer.frame = playerLayer.frame
        layer.isHidden = true
        view.layer?.addSublayer(layer)
        return layer
    }

    private func setupExtraLayers(in view: NSView) {
        if let name = idleVideoName, let url = Outfit.url(name) {
            let player = AVQueuePlayer()
            idleLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: AVAsset(url: url)))
            idlePlayer = player
            idleLayer = makeLayer(player, in: view)
        }
        trickLayer = makeLayer(trickPlayer, in: view)
        loopLayer = makeLayer(loopPlayer, in: view)
        standStill()
    }

    /// Only one video shows at a time.
    private func show(_ layer: AVPlayerLayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in allLayers { l.isHidden = l !== layer }
        CATransaction.commit()
        if layer !== idleLayer { idlePlayer?.pause() }
        if layer !== loopLayer { loopPlayer.pause(); loopingName = nil }
        if layer !== trickLayer { trickPlayer.pause() }
    }

    /// Standing around: the breathing loop if there is one, otherwise the walk video's first frame.
    func standStill() {
        queuePlayer?.pause()
        queuePlayer?.seek(to: .zero)
        if isDoingTrick || loopingName != nil { return }
        guard let idle = idlePlayer else { show(playerLayer); return }
        show(idleLayer)
        idle.play()
    }

    /// Play a clip once, then run `then` (or go back to standing).
    private func playOnce(_ video: String, duration: CFTimeInterval, then: (() -> Void)? = nil) {
        guard let url = Outfit.url(video) else { then?(); return }
        isDoingTrick = true
        onceDone = then
        trickEndTime = CACurrentMediaTime() + duration
        trickPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        trickPlayer.seek(to: .zero)
        show(trickLayer)
        trickPlayer.play()
        onTrick?(video)   // (his dog joins in with the yoga, however it started)
    }

    private func playClip(_ name: String, then: (() -> Void)? = nil) {
        guard let c = clips[name] else { then?(); return }
        playOnce(c.video, duration: c.duration, then: then)
    }

    func playLoop(_ name: String) {
        guard loopingName != name, let video = loops[name],
              let url = Outfit.url(video) else { return }
        isDoingTrick = false
        onceDone = nil
        show(loopLayer)
        loopingName = name
        loopPlayer.removeAllItems()
        loopLooper = AVPlayerLooper(player: loopPlayer, templateItem: AVPlayerItem(asset: AVAsset(url: url)))
        loopPlayer.play()
    }

    func stopLoop() {
        loopingName = nil
        loopPlayer.pause()
        standStill()
    }

    /// told whenever he starts a one-off clip (his dog joins in with the yoga)
    var onTrick: ((String) -> Void)?

    private func startTrick() {
        guard let trick = tricks.randomElement() else { startWalk(); return }
        playOnce(trick.video, duration: trick.duration)
    }

    /// Cut a one-off clip short (e.g. he's been picked up).
    private func finishTrick() {
        isDoingTrick = false
        onceDone = nil
        trickPlayer.pause()
        standStill()
    }

    /// Everything that happens while he's standing still. Called every frame from update().
    private func updateStanding(_ now: CFTimeInterval) {
        if isDoingTrick, now >= trickEndTime {
            isDoingTrick = false
            let done = onceDone
            onceDone = nil
            if let done = done { done() } else { standStill() }
            pauseEndTime = max(pauseEndTime, now + Double.random(in: 1.5...4.0))
        }
        if landingPending, now - dropStart >= dropDuration {
            landingPending = false
            playClip("land") { [weak self] in self?.resumeActivity() }
        }

        // nap when you've been away; wake the moment you're back
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if isAsleep {
            pauseEndTime = now + 3
            if now - lastZzz > 4 { lastZzz = now; say("z z z", for: 2.5) }
            if away < 1, now - asleepSince > 3 { wakeUp() }
            return
        }
        // focusing, watching a video, noticing you're back
        if !isDoingTrick, loopingName == nil || colleague.holdsStill { colleague.tick(now: now, away: away) }
        if colleague.holdsStill { pauseEndTime = now + 3; return }

        if !isDoingTrick, loopingName == nil, away > napAfter { fallAsleep() }

        // lunch alarm, once a day between 12:30 and 2pm
        if !isDoingTrick, loopingName == nil, isLunchTime() { lunchAlarm() }

        if !isDoingTrick, loopingName == nil, now >= pauseEndTime {
            if !tricks.isEmpty, Double.random(in: 0...1) < trickChance {
                startTrick()
            } else {
                startWalk()
            }
        }
    }

    /// settled in for a while (at his desk, watching something, eating lunch): his dog lies down next to him
    var isSettledDown: Bool { ["focus", "watch"].contains(loopingName ?? "") }

    /// His dog gets a biscuit now and then: he turns to the dog and drops one from his hand (the feed clip).
    /// Only when he's just standing about. Returns false if he's busy.
    @discardableResult
    func feedDog(dogIsToTheRight: Bool) -> Bool {
        guard isPaused, !isWalking, !isDoingTrick, loopingName == nil, !isAsleep, !isBeingDragged, !isIdleForPopover,
              !colleague.holdsStill, clips["feed"] != nil else { return false }
        goingRight = dogIsToTheRight
        updateFlip()
        playClip("feed")
        pauseEndTime = max(pauseEndTime, CACurrentMediaTime() + 6)
        let dog = Profile.dogName
        say(["treat time, \(dog) 🦴", "who's a good boy", "here you go, \(dog) 🦴", "one for you, \(dog)", "\(dog). sit. …close enough 🦴"].randomElement()!, for: 2.2)
        return true
    }

    /// Turn toward the middle of the screen (where the video usually is): his clips face right, the layer flips.
    func faceTheScreen() {
        let mid = (window.screen ?? NSScreen.main)?.frame.midX ?? 0
        goingRight = window.frame.midX < mid
        updateFlip()
    }

    /// Back to what he was doing before you picked him up.
    private func resumeActivity() {
        if colleague.isWatching {
            faceTheScreen()
            playClip("watchin") { [weak self] in self?.playLoop("watch") }
        } else if colleague.isFocusing {
            playClip("focusin") { [weak self] in self?.playLoop("focus") }
        } else {
            standStill()
        }
    }

    func fallAsleep() {
        guard !isAsleep else { return }
        isAsleep = true
        asleepSince = CACurrentMediaTime()
        lastZzz = asleepSince + 1
        if isWalking { isWalking = false; isPaused = true }
        playClip("doze") { [weak self] in
            guard let self = self, self.isAsleep else { return }
            self.playLoop("sleep")
        }
    }

    func wakeUp(line: String = "i was awake.") {
        guard isAsleep else { return }
        isAsleep = false
        loopingName = nil
        playClip("wake") { [weak self] in self?.standStill() }
        say(line, for: 2.5)
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 3.0...5.0)
    }

    private func isLunchTime() -> Bool {
        let now = Date()
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard minutes >= 12 * 60 + 30, minutes < 14 * 60 else { return false }
        let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        return UserDefaults.standard.double(forKey: Self.lunchKey) != today
    }

    /// `real` is the 12:30 alarm; a test from the menu doesn't count as today's lunch.
    func lunchAlarm(real: Bool = true) {
        if real { UserDefaults.standard.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: Self.lunchKey) }
        if isWalking { isWalking = false; isPaused = true }
        playClip("lunch")
        // the bubble lands on the jump, when the clock goes off
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.say("it's lunch time.", for: 4) }
    }

    /// For the menu: do something now.
    func perform(_ name: String) {
        guard !isIdleForPopover, !isBeingDragged else { return }
        if isAsleep { wakeUp() ; return }
        isWalking = false
        isPaused = true
        if isDoingTrick { finishTrick() }
        switch name {
        case "nap": fallAsleep()
        case "lunch": lunchAlarm(real: false)
        case "focusin": playClip("focusin") { [weak self] in self?.playLoop("focus") }
        case "focusout", "cheer", "land": playClip(name)
        case "focus": colleague.startFocus()
        case "watchin":
            faceTheScreen()
            playClip("watchin") { [weak self] in self?.playLoop("watch") }
        case "watchout": playClip("watchout")
        case "watch": colleague.isWatching ? colleague.stopWatching() : colleague.startWatching(byHand: true)
        default:
            if let t = tricks.first(where: { $0.video.hasPrefix(name) }) { playOnce(t.video, duration: t.duration) }
        }
    }

    /// A short line in his speech bubble.
    func say(_ text: String, for seconds: CFTimeInterval) {
        guard !isIdleForPopover, !isAgentBusy else { return }
        currentPhrase = text
        showingCompletion = true
        completionBubbleExpiry = CACurrentMediaTime() + seconds
        showBubble(text: text, isCompletion: true)
    }

    func toggleClaudeWatch() {
        let on = !ClaudeWatcher.isInstalled
        guard ClaudeWatcher.setInstalled(on) else { say("couldn't change claude's settings file. is it plain json?", for: 4); return }
        if on { claude.start() }
        say(on ? "okay. watching \(ClaudeWatcher.watchedNames) for you. permission asks come to me now." : "okay. they'll ask in their own windows again.", for: 5)
    }

    /// Open his chat and send a message straight away.
    func openChat(with message: String) {
        openPopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.terminalView?.submitText(message)
        }
    }

    // MARK: - Right-click menu (carroto)

    func showMenu(with event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        func item(_ title: String, _ run: @escaping () -> Void) {
            let i = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let action = MenuAction(run)
            i.target = action
            i.representedObject = action
            menu.addItem(i)
        }
        if colleague.isFocusing {
            item("stop focusing") { [weak self] in self?.colleague.endFocus(done: false) }
        } else {
            item("focus with me (25 min)") { [weak self] in self?.colleague.startFocus() }
            item("focus with me (50 min)") { [weak self] in self?.colleague.startFocus(minutes: 50) }
        }
        item(colleague.isWatching ? "stop watching" : "watch with me 🍿") { [weak self] in self?.perform("watch") }
        // you and me: names, looks, quiet focus
        menu.addItem(.separator())
        item("rename me…") { [weak self] in self?.renameMe() }
        item("rename \(Profile.dogName)…") { [weak self] in self?.renameDog() }
        item(Profile.humanName == nil ? "tell me your name…" : "call me something else…") { [weak self] in self?.callYou() }
        for o in Outfit.allCases where o.isAvailable {
            item((o == Outfit.current ? "✓ " : "    ") + "wear: " + o.title) { [weak self] in self?.wear(o) }
        }
        item(QuietFocus.shortcutsReady ? "DND mode ✓" : "set up DND mode…") { [weak self] in self?.setUpQuietFocus() }
        menu.addItem(.separator())
        item("water fernando") { [weak self] in self?.perform("water") }
        item("yoga") { [weak self] in self?.perform("yoga") }
        item("take a nap") { [weak self] in self?.perform("nap") }
        item("celebrate 🎉") { [weak self] in self?.perform("cheer") }
        item(ClaudeWatcher.isInstalled ? "stop watching my ai tools" : "watch my ai tools 👀") { [weak self] in self?.toggleClaudeWatch() }
        menu.addItem(.separator())
        item("chat") { [weak self] in self?.openPopover() }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: - Dragging (carroto)

    func beginDrag(at screenPoint: NSPoint) {
        isBeingDragged = true
        if isAsleep { isAsleep = false; say("hey!", for: 1.5) }
        else if colleague.isFocusing { say("hey, i was working!", for: 1.5) }
        if isDoingTrick { finishTrick() }
        landingPending = false
        isWalking = false
        isPaused = true
        playLoop("dangle")
        dragOffset = NSPoint(x: screenPoint.x - window.frame.origin.x, y: screenPoint.y - window.frame.origin.y)
    }

    func drag(to screenPoint: NSPoint) {
        window.setFrameOrigin(NSPoint(x: screenPoint.x - dragOffset.x, y: screenPoint.y - dragOffset.y))
        updateThinkingBubble()
    }

    func endDrag() {
        isBeingDragged = false
        droppedAtX = window.frame.origin.x
        dropFromY = window.frame.origin.y
        dropStart = CACurrentMediaTime()
        // keeps dangling while he falls, then the landing clip plays
        landingPending = true
        loopingName = nil
        // he stands where he landed for a bit before wandering off again
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 3.0...6.0)
    }

    /// The dock-height y, or partway through the fall if he was just dropped.
    private func landingY(_ dockY: CGFloat, now: CFTimeInterval) -> CGFloat {
        let u = (now - dropStart) / dropDuration
        guard u < 1, dropFromY > dockY else { return dockY }
        return dropFromY + (dockY - dropFromY) * CGFloat(u * u) // falls, speeding up
    }

    // MARK: - Walking

    func startWalk() {
        isPaused = false
        isWalking = true
        playCount = 0
        walkStartTime = CACurrentMediaTime()

        walkStartPos = positionProgress
        // Walk a fixed pixel distance (~200-325px) regardless of screen width.
        let referenceWidth: CGFloat = 500.0
        let walkPixels = CGFloat.random(in: walkAmountRange) * referenceWidth
        let walkAmount = currentTravelDistance > 0 ? walkPixels / currentTravelDistance : 0.3

        // carroto keeps to his corner of the dock, and strolls to the middle about once an hour.
        // Long trips are several ordinary walks toward a destination, so his feet never skate.
        let now = CACurrentMediaTime()
        if destination == nil, now >= nextTripAt {
            destination = CGFloat.random(in: 0.42...0.58)
            nextTripAt = now + Double.random(in: 45...75) * 60
        } else if destination == nil, !homeRange.contains(positionProgress) {
            destination = CGFloat.random(in: homeRange) // dropped somewhere else: head home
        }
        if let dest = destination {
            goingRight = dest > walkStartPos
            walkEndPos = goingRight ? min(walkStartPos + walkAmount, dest) : max(walkStartPos - walkAmount, dest)
            if abs(walkEndPos - dest) < 0.005 {
                // arrived: from the middle, head back home; from home, done
                destination = homeRange.contains(dest) ? nil : CGFloat.random(in: homeRange)
            }
        } else {
            // pottering about at home
            if positionProgress > homeRange.upperBound - 0.03 { goingRight = false }
            else if positionProgress < homeRange.lowerBound + 0.03 { goingRight = true }
            else { goingRight = Bool.random() }
            walkEndPos = goingRight ? min(walkStartPos + walkAmount, homeRange.upperBound) : max(walkStartPos - walkAmount, homeRange.lowerBound)
        }
        // Store pixel positions so walk speed stays consistent if screen changes mid-walk
        walkStartPixel = walkStartPos * currentTravelDistance
        walkEndPixel = walkEndPos * currentTravelDistance

        let minSeparation: CGFloat = 0.12
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self {
                let sibPos = sibling.positionProgress
                if abs(walkEndPos - sibPos) < minSeparation {
                    if goingRight {
                        walkEndPos = max(walkStartPos, sibPos - minSeparation)
                    } else {
                        walkEndPos = min(walkStartPos, sibPos + minSeparation)
                    }
                }
            }
        }

        updateFlip()
        show(playerLayer)
        idlePlayer?.pause()
        queuePlayer.seek(to: .zero)
        queuePlayer.play()
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        standStill()
        let delay = Double.random(in: 5.0...12.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in allLayers {
            layer.transform = goingRight ? CATransform3DIdentity : CATransform3DMakeScale(-1, 1, 1)
            layer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        }
        CATransaction.commit()
    }

    var currentFlipCompensation: CGFloat {
        goingRight ? 0 : flipXOffset
    }

    func movementPosition(at videoTime: CFTimeInterval) -> CGFloat {
        let dIn = fullSpeedStart - accelStart
        let dLin = decelStart - fullSpeedStart
        let dOut = walkStop - decelStart
        let v = 1.0 / (dIn / 2.0 + dLin + dOut / 2.0)

        if videoTime <= accelStart {
            return 0.0
        } else if videoTime <= fullSpeedStart {
            let t = videoTime - accelStart
            return CGFloat(v * t * t / (2.0 * dIn))
        } else if videoTime <= decelStart {
            let easeInDist = v * dIn / 2.0
            let t = videoTime - fullSpeedStart
            return CGFloat(easeInDist + v * t)
        } else if videoTime <= walkStop {
            let easeInDist = v * dIn / 2.0
            let linearDist = v * dLin
            let t = videoTime - decelStart
            return CGFloat(easeInDist + linearDist + v * (t - t * t / (2.0 * dOut)))
        } else {
            return 1.0
        }
    }

    // MARK: - Frame Update

    func update(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        currentTravelDistance = max(dockWidth - displayWidth, 0)
        if isIdleForPopover {
            let travelDistance = currentTravelDistance
            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        let now = CACurrentMediaTime()

        if isBeingDragged { return }
        // watch party: notice a video playing whatever he's doing (checks every 2s)
        if !isAsleep, !isIdleForPopover, loopingName == nil || colleague.isWatching { colleague.watchTick(now) }
        if let x = droppedAtX {
            droppedAtX = nil
            if currentTravelDistance > 0 {
                positionProgress = min(max((x - dockX - currentFlipCompensation) / currentTravelDistance, 0), 1)
            }
        }

        if isPaused {
            updateStanding(now)
            if isPaused {
                let travelDistance = max(dockWidth - displayWidth, 0)
                let x = dockX + travelDistance * positionProgress + currentFlipCompensation
                let bottomPadding = displayHeight * 0.15
                let y = landingY(dockTopY - bottomPadding + yOffset, now: now)
                window.setFrameOrigin(NSPoint(x: x, y: y))
                updateThinkingBubble()
                return
            }
        }

        if isWalking {
            let elapsed = now - walkStartTime
            let videoTime = min(elapsed, videoDuration)
            let travelDistance = currentTravelDistance

            // Interpolate in pixel space for consistent speed across screen changes
            let walkNorm = elapsed >= videoDuration ? 1.0 : movementPosition(at: videoTime)
            let currentPixel = walkStartPixel + (walkEndPixel - walkStartPixel) * walkNorm

            // Convert pixel position back to progress for the current screen
            if travelDistance > 0 {
                positionProgress = min(max(currentPixel / travelDistance, 0), 1)
            }

            if elapsed >= videoDuration {
                walkEndPos = positionProgress
                enterPause()
                return
            }

            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        updateThinkingBubble()
    }
}
