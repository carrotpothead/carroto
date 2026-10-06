import SwiftUI
import AppKit
import ServiceManagement

@main
struct LilAgentsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: LilAgentsController?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = LilAgentsController()
        controller?.start()
        setupMenuBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.characters.forEach { $0.session?.terminate() }
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "carroto")
        }

        let menu = NSMenu()

        let char1Item = NSMenuItem(title: "Carroto", action: #selector(toggleChar1), keyEquivalent: "1")
        char1Item.state = .on
        menu.addItem(char1Item)

        // carroto: make him do something right now
        let trickItem = NSMenuItem(title: "Do a Trick", action: nil, keyEquivalent: "")
        let trickMenu = NSMenu()
        for (title, name) in [("Water Fernando", "water"), ("Yoga", "yoga"), ("Lunch Alarm", "lunch"), ("Take a Nap", "nap"), ("Focus with Me", "focus"), ("Watch Party", "watch"), ("Celebrate", "cheer")] {
            let item = NSMenuItem(title: title, action: #selector(doTrick(_:)), keyEquivalent: "")
            item.representedObject = name
            item.target = self
            trickMenu.addItem(item)
        }
        trickItem.submenu = trickMenu
        menu.addItem(trickItem)

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.state = .on
        menu.addItem(soundItem)

        // carroto: start with the Mac, so he's back on the dock after a restart
        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        // carroto watches your Claude Code: permission requests come to him (Allow / Deny), and he tells you when it's done
        let claudeItem = NSMenuItem(title: "Watch My AI Tools", action: #selector(toggleWatchClaude(_:)), keyEquivalent: "")
        claudeItem.target = self
        claudeItem.state = ClaudeWatcher.isInstalled ? .on : .off
        menu.addItem(claudeItem)

        // focus, names, outfits, quiet focus (the same things as his own menu)
        menu.addItem(NSMenuItem.separator())
        let focusItem = NSMenuItem(title: "Focus With Me", action: nil, keyEquivalent: "")
        let focusMenu = NSMenu()
        for m in [25, 50] {
            let i = NSMenuItem(title: "\(m) minutes", action: #selector(startFocus(_:)), keyEquivalent: ""); i.target = self; i.tag = m
            focusMenu.addItem(i)
        }
        focusMenu.addItem(NSMenuItem.separator())
        let quiet = NSMenuItem(title: "Set Up DND Mode…", action: #selector(setUpQuiet), keyEquivalent: ""); quiet.target = self
        focusMenu.addItem(quiet)
        focusItem.submenu = focusMenu
        menu.addItem(focusItem)

        let outfitItem = NSMenuItem(title: "Outfit", action: nil, keyEquivalent: "")
        let outfitMenu = NSMenu()
        for (i, o) in Outfit.allCases.enumerated() where o.isAvailable {
            let it = NSMenuItem(title: o.title, action: #selector(wearOutfit(_:)), keyEquivalent: ""); it.target = self; it.tag = i
            it.state = o == Outfit.current ? .on : .off
            outfitMenu.addItem(it)
        }
        outfitItem.submenu = outfitMenu
        menu.addItem(outfitItem)

        let renameItem = NSMenuItem(title: "Rename Him…", action: #selector(renameHim), keyEquivalent: ""); renameItem.target = self
        menu.addItem(renameItem)
        let youItem = NSMenuItem(title: "Your Name…", action: #selector(yourName), keyEquivalent: ""); youItem.target = self
        menu.addItem(youItem)

        // Provider submenu (applies to all characters)
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        let currentProvider = controller?.characters.first?.provider ?? .claude
        for (i, provider) in AgentProvider.allCases.enumerated() {
            let item = NSMenuItem(title: provider.displayName, action: #selector(switchProvider(_:)), keyEquivalent: "")
            item.tag = i
            item.state = provider == currentProvider ? .on : .off
            if !provider.isAvailable {
                item.isEnabled = false
            }
            providerMenu.addItem(item)
        }
        providerMenu.addItem(NSMenuItem.separator())
        let gatewayItem = NSMenuItem(title: "Advanced Settings\u{2026}", action: #selector(openGatewaySettings), keyEquivalent: "")
        gatewayItem.tag = -1
        providerMenu.addItem(gatewayItem)

        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        // Size submenu (applies to all characters)
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        let currentSize = controller?.characters.first?.size ?? .large
        for (i, size) in CharacterSize.allCases.enumerated() {
            let item = NSMenuItem(title: size.displayName, action: #selector(switchCharacterSize(_:)), keyEquivalent: "")
            item.tag = i
            item.state = size == currentSize ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // Theme submenu
        let themeItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (i, theme) in PopoverTheme.allThemes.enumerated() {
            let item = NSMenuItem(title: theme.name, action: #selector(switchTheme(_:)), keyEquivalent: "")
            item.tag = i
            item.state = theme.name == PopoverTheme.current.name ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Display submenu
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.delegate = self
        let autoItem = NSMenuItem(title: "Auto (Main Display)", action: #selector(switchDisplay(_:)), keyEquivalent: "")
        autoItem.tag = -1
        autoItem.state = .on
        displayMenu.addItem(autoItem)
        displayMenu.addItem(NSMenuItem.separator())
        for (i, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(switchDisplay(_:)), keyEquivalent: "")
            item.tag = i
            item.state = .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Menu Actions

    @objc func switchTheme(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < PopoverTheme.allThemes.count else { return }
        PopoverTheme.current = PopoverTheme.allThemes[idx]

        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }

        controller?.characters.forEach { char in
            let wasOpen = char.isIdleForPopover
            if wasOpen { char.popoverWindow?.orderOut(nil) }
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow = nil
            if wasOpen {
                char.createPopoverWindow()
                if let session = char.session, !session.history.isEmpty {
                    char.terminalView?.replayHistory(session.history)
                }
                char.updatePopoverPosition()
                char.popoverWindow?.orderFrontRegardless()
                char.popoverWindow?.makeKey()
                if let terminal = char.terminalView {
                    char.popoverWindow?.makeFirstResponder(terminal.inputField)
                }
            }
        }
    }

    @objc func switchProvider(_ sender: NSMenuItem) {
        let idx = sender.tag
        let allProviders = AgentProvider.allCases
        guard idx < allProviders.count else { return }
        let newProvider = allProviders[idx]

        controller?.characters.forEach { char in
            if char.provider == newProvider { return }
            char.provider = newProvider
            char.session?.terminate()
            char.session = nil
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow?.orderOut(nil)
            char.thinkingBubbleWindow = nil
        }

        if let providerMenu = sender.menu {
            for item in providerMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func switchCharacterSize(_ sender: NSMenuItem) {
        let idx = sender.tag
        let allSizes = CharacterSize.allCases
        guard idx < allSizes.count else { return }
        let newSize = allSizes[idx]

        controller?.characters.forEach { $0.size = newSize }

        if let sizeMenu = sender.menu {
            for item in sizeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func switchDisplay(_ sender: NSMenuItem) {
        let idx = sender.tag
        controller?.pinnedScreenIndex = idx

        if let displayMenu = sender.menu {
            for item in displayMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func doTrick(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller?.characters.first?.perform(name)
    }

    @objc func toggleChar1(_ sender: NSMenuItem) {
        guard let chars = controller?.characters, chars.count > 0 else { return }
        let char = chars[0]
        if char.isManuallyVisible {
            char.setManuallyVisible(false)
            sender.state = .off
        } else {
            char.setManuallyVisible(true)
            sender.state = .on
        }
    }


    @objc func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            // macOS can ask for approval first: System Settings → General → Login Items
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        sender.state = service.status == .enabled ? .on : .off
    }

    @objc func startFocus(_ sender: NSMenuItem) { controller?.characters.first?.colleague.startFocus(minutes: sender.tag) }
    @objc func setUpQuiet() { controller?.characters.first?.setUpQuietFocus() }
    @objc func wearOutfit(_ sender: NSMenuItem) { controller?.characters.first?.wear(Outfit.allCases[sender.tag]) }
    @objc func renameHim() { controller?.characters.first?.renameMe() }
    @objc func yourName() { controller?.characters.first?.callYou() }

    @objc func toggleWatchClaude(_ sender: NSMenuItem) {
        controller?.characters.first?.toggleClaudeWatch()
        sender.state = ClaudeWatcher.isInstalled ? .on : .off
    }

    @objc func toggleSounds(_ sender: NSMenuItem) {
        WalkerCharacter.soundsEnabled.toggle()
        sender.state = WalkerCharacter.soundsEnabled ? .on : .off
    }

    @objc func openGatewaySettings() {
        OpenClawSession.showSettingsPanel { [weak self] in
            // If OpenClaw is the active provider, reconnect with new settings
            guard AgentProvider.current == .openclaw else { return }
            self?.controller?.characters.forEach { char in
                char.session?.terminate()
                char.session = nil
            }
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {}
