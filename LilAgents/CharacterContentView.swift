import AppKit

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class CharacterContentView: NSView {
    weak var character: WalkerCharacter?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // AVPlayerLayer is GPU-rendered so layer.render(in:) won't capture video pixels.
        // Use CGWindowListCreateImage to sample actual on-screen alpha at click point.
        let screenPoint = window?.convertPoint(toScreen: convert(localPoint, to: nil)) ?? .zero
        // Use the full virtual display height for the CG coordinate flip, not just
        // the main screen. NSScreen coordinates have origin at bottom-left of the
        // primary display, while CG uses top-left. The primary screen's height is
        // the correct basis for the flip across all monitors.
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - screenPoint.y

        let captureRect = CGRect(x: screenPoint.x - 0.5, y: flippedY - 0.5, width: 1, height: 1)
        guard let windowID = window?.windowNumber, windowID > 0 else { return nil }

        if let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixel: [UInt8] = [0, 0, 0, 0]
            if let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if pixel[3] > 30 {
                    return self
                }
                return nil
            }
        }

        // Fallback: accept click if within center 60% of the view
        let insetX = bounds.width * 0.2
        let insetY = bounds.height * 0.15
        let hitRect = bounds.insetBy(dx: insetX, dy: insetY)
        return hitRect.contains(localPoint) ? self : nil
    }

    // carroto: press and move to pick him up; a press without moving is still a click
    private var pressPoint: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        // control-click (and trackpads set to that for secondary click) is a right-click on a Mac: show his menu
        if event.modifierFlags.contains(.control) { character?.showMenu(with: event, in: self); pressPoint = nil; return }
        pressPoint = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint, let character = character, character.canBeDragged else { return }
        let now = NSEvent.mouseLocation
        if !dragging, hypot(now.x - start.x, now.y - start.y) > 4 {
            dragging = true
            character.beginDrag(at: start)
        }
        if dragging { character.drag(to: now) }
    }

    override func rightMouseDown(with event: NSEvent) {
        character?.showMenu(with: event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil || dragging else { return }      // (the control-click already opened the menu)
        if dragging { character?.endDrag() } else { character?.handleClick() }
        pressPoint = nil
        dragging = false
    }
}
