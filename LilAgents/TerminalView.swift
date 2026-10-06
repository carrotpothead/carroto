import AppKit

class PaddedTextFieldCell: NSTextFieldCell {
    private let inset = NSSize(width: 8, height: 2)
    var fieldBackgroundColor: NSColor?
    var fieldCornerRadius: CGFloat = 4

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let bg = fieldBackgroundColor {
            let path = NSBezierPath(roundedRect: cellFrame, xRadius: fieldCornerRadius, yRadius: fieldCornerRadius)
            bg.setFill()
            path.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        return base.insetBy(dx: inset.width, dy: inset.height)
    }

    private func configureEditor(_ textObj: NSText) {
        if let color = textColor {
            textObj.textColor = color
        }
        if let tv = textObj as? NSTextView {
            tv.insertionPointColor = textColor ?? .textColor
            tv.drawsBackground = false
            tv.backgroundColor = .clear
        }
        textObj.font = font
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        configureEditor(textObj)
        super.edit(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        configureEditor(textObj)
        super.select(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

class TerminalView: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let inputField = NSTextField()
    var onSendMessage: ((String) -> Void)?
    var onClearRequested: (() -> Void)?
    var provider: AgentProvider = .claude {
        didSet {
            updatePlaceholder()
        }
    }

    private var currentAssistantText = ""
    private var lastAssistantText = ""
    private var isStreaming = false
    private var showingSessionMessage = false

    // the sticker look: bubbles, quick-reply pills, a round input with his face as the send button
    var stickerStyle: Bool { theme.name == "Stickers" }
    var chips: [(title: String, fill: NSColor, halo: NSColor)] = [] { didSet { buildChips() } }
    var onChip: ((Int) -> Void)?
    private let chipRow = NSView()
    private let inputBox = NSView()
    private let sendButton = NSButton()
    private var streamStart = 0                 // where his current reply starts in the text
    private var streamBubbles: [BubbleInfo] = []
    private var typingRange: NSRange?
    private var replies = 0
    private var turnsSinceSticker = 9
    private var lastUserText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    var characterColor: NSColor?
    var themeOverride: PopoverTheme?
    var theme: PopoverTheme {
        var t = themeOverride ?? PopoverTheme.current
        if let color = characterColor { t = t.withCharacterColor(color) }
        t = t.withCustomFont()
        return t
    }

    // MARK: - Setup

    private func updatePlaceholder() {
        let t = theme
        inputField.placeholderAttributedString = NSAttributedString(
            string: stickerStyle ? "say something to carroto…" : provider.inputPlaceholder,
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        )
    }

    private func setupViews() {
        let t = theme
        let inputHeight: CGFloat = 30
        let padding: CGFloat = 10

        scrollView.frame = NSRect(
            x: padding, y: inputHeight + padding + 6,
            width: frame.width - padding * 2,
            height: frame.height - inputHeight - padding - 10
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = t.textPrimary
        textView.font = t.font
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = 8
        textView.defaultParagraphStyle = defaultPara
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        addSubview(scrollView)

        inputField.frame = NSRect(
            x: padding, y: 6,
            width: frame.width - padding * 2,
            height: inputHeight
        )
        inputField.autoresizingMask = [.width]
        inputField.focusRingType = .none
        let paddedCell = PaddedTextFieldCell(textCell: "")
        paddedCell.isEditable = true
        paddedCell.isScrollable = true
        paddedCell.font = t.font
        paddedCell.textColor = t.textPrimary
        paddedCell.drawsBackground = false
        paddedCell.isBezeled = false
        paddedCell.fieldBackgroundColor = nil
        paddedCell.fieldCornerRadius = 0
        inputField.cell = paddedCell
        updatePlaceholder()
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        addSubview(inputField)
        if stickerStyle { applyStickerLayout() }
    }

    private func applyStickerLayout() {
        let pad: CGFloat = 14, inputH: CGFloat = 44, chipH: CGFloat = 30
        textView.textContainer?.replaceLayoutManager(BubbleLayoutManager())
        textView.textContainerInset = NSSize(width: 4, height: 16)
        scrollView.frame = NSRect(x: pad - 6, y: 12 + inputH + chipH + 10, width: frame.width - (pad - 6) * 2,
                                  height: frame.height - (12 + inputH + chipH + 10))
        chipRow.frame = NSRect(x: pad, y: 12 + inputH + 8, width: frame.width - pad * 2, height: chipH)
        chipRow.autoresizingMask = [.width]
        addSubview(chipRow)
        // a white pill with a soft halo; his face is the send button
        inputBox.frame = NSRect(x: pad, y: 12, width: frame.width - pad * 2, height: inputH)
        inputBox.autoresizingMask = [.width]
        inputBox.wantsLayer = true
        inputBox.layer?.backgroundColor = NSColor.white.cgColor
        inputBox.layer?.cornerRadius = inputH / 2
        inputBox.layer?.borderWidth = 3.5
        inputBox.layer?.borderColor = Sticker.cream2.cgColor
        addSubview(inputBox, positioned: .below, relativeTo: inputField)
        inputField.frame = NSRect(x: pad + 10, y: 12 + (inputH - 24) / 2, width: frame.width - pad * 2 - 62, height: 24)
        sendButton.frame = NSRect(x: frame.width - pad - 41, y: 15, width: 38, height: 38)
        sendButton.autoresizingMask = [.minXMargin]
        sendButton.image = Sticker.image("send", size: 38)
        sendButton.imageScaling = .scaleProportionallyUpOrDown
        sendButton.isBordered = false
        sendButton.title = ""
        sendButton.target = self
        sendButton.action = #selector(inputSubmitted)
        sendButton.toolTip = "send"
        addSubview(sendButton)
    }

    private func buildChips() {
        chipRow.subviews.forEach { $0.removeFromSuperview() }
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        var x: CGFloat = 0
        for (i, c) in chips.enumerated() {
            let w = ceil((c.title as NSString).size(withAttributes: [.font: font]).width) + 26
            guard x + w <= chipRow.frame.width else { break }
            let b = NSButton(frame: NSRect(x: x, y: 2, width: w, height: 26))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: c.title, attributes: [.font: font, .foregroundColor: Sticker.ink])
            b.wantsLayer = true
            b.layer?.backgroundColor = c.fill.cgColor
            b.layer?.cornerRadius = 13
            b.layer?.borderWidth = 3
            b.layer?.borderColor = c.halo.cgColor
            b.tag = i
            b.target = self
            b.action = #selector(chipTapped(_:))
            chipRow.addSubview(b)
            x += w + 8
        }
    }

    @objc private func chipTapped(_ b: NSButton) { onChip?(b.tag) }

    /// Put text in the box (and put the cursor after it), e.g. "brainstorm with me: ".
    func prefill(_ text: String) {
        inputField.stringValue = text
        window?.makeFirstResponder(inputField)
        inputField.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    func resetState() {
        isStreaming = false
        currentAssistantText = ""
        lastAssistantText = ""
        showingSessionMessage = false
        typingRange = nil
        streamBubbles = []
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func showSessionMessage() {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "  \u{2726} new session\n",
            attributes: [.font: t.font, .foregroundColor: t.accentColor]
        ))
        showingSessionMessage = true
    }

    // MARK: - Input

    @objc private func inputSubmitted() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""

        if handleSlashCommand(text) { return }

        if showingSessionMessage {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            showingSessionMessage = false
        }
        appendUser(text)
        isStreaming = true
        currentAssistantText = ""
        lastUserText = text
        if stickerStyle { showTyping() }
        onSendMessage?(text)
    }

    /// Type and send a message for you (carroto's right-click shortcuts).
    func submitText(_ text: String) {
        inputField.stringValue = text
        inputSubmitted()
    }

    // MARK: - Slash Commands

    func handleSlashCommandPublic(_ text: String) {
        _ = handleSlashCommand(text)
    }

    private func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let cmd = text.lowercased().trimmingCharacters(in: .whitespaces)

        switch cmd {
        case "/clear":
            resetState()
            onClearRequested?()
            return true

        case "/copy":
            let toCopy = lastAssistantText.isEmpty ? "nothing to copy yet" : lastAssistantText
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(toCopy, forType: .string)
            let t = theme
            textView.textStorage?.append(NSAttributedString(
                string: "  ✓ copied to clipboard\n",
                attributes: [.font: t.font, .foregroundColor: t.successColor]
            ))
            scrollToBottom()
            return true

        case "/help":
            let t = theme
            let help = NSMutableAttributedString()
            help.append(NSAttributedString(string: "  carroto — slash commands\n",
                attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]))
            help.append(NSAttributedString(string: "  /clear  ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "clear chat history\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            help.append(NSAttributedString(string: "  /copy   ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "copy last response\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            help.append(NSAttributedString(string: "  /help   ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "show this message\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            textView.textStorage?.append(help)
            scrollToBottom()
            return true

        default:
            let t = theme
            textView.textStorage?.append(NSAttributedString(
                string: "  unknown command: \(text) (try /help)\n",
                attributes: [.font: t.font, .foregroundColor: t.errorColor]
            ))
            scrollToBottom()
            return true
        }
    }

    // MARK: - Append Methods

    private var messageSpacing: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0 {
            if !storage.string.hasSuffix("\n") {
                storage.append(NSAttributedString(string: "\n"))
            }
        }
    }

    func appendUser(_ text: String) {
        let t = theme
        ensureNewline()
        if stickerStyle {
            hideTyping()
            currentAssistantText = ""          // whatever he says next is a new reply (new bubbles)
            let mine = BubbleInfo(fill: Sticker.cobalt, halo: Sticker.cobaltHalo, eyes: .none, mine: true)
            textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: t.font.pointSize, weight: .medium), .foregroundColor: NSColor.white,
                .paragraphStyle: bubbleStyle(mine: true, first: true), .carrotoBubble: mine,
            ]))
            scrollToBottom()
            return
        }
        let para = messageSpacing
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "> ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor, .paragraphStyle: para
        ]))
        attributed.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: t.fontBold, .foregroundColor: t.textPrimary, .paragraphStyle: para
        ]))
        textView.textStorage?.append(attributed)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        if stickerStyle, currentAssistantText.isEmpty, !cleaned.isEmpty { startReply() }
        currentAssistantText += cleaned
        if !cleaned.isEmpty {
            textView.textStorage?.append(renderMarkdown(cleaned))
            if stickerStyle { restyleReply() }
            scrollToBottom()
        }
    }

    func endStreaming() {
        hideTyping()
        if isStreaming {
            isStreaming = false
            if !currentAssistantText.isEmpty {
                lastAssistantText = currentAssistantText
                if stickerStyle {
                    // now and then, a sticker that fits the moment (never two in a row)
                    if turnsSinceSticker >= 2, let name = Sticker.pick(you: lastUserText, him: currentAssistantText) {
                        appendSticker(name)
                        turnsSinceSticker = 0
                    } else {
                        turnsSinceSticker += 1
                    }
                }
            }
            currentAssistantText = ""
        }
    }

    // MARK: - Bubbles (the sticker look)

    private var containerWidth: CGFloat { textView.textContainer?.size.width ?? 380 }

    private func bubbleStyle(mine: Bool, first: Bool) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        let w = containerWidth
        p.paragraphSpacingBefore = first ? 26 : 3
        p.lineSpacing = 1.5
        if mine {
            p.alignment = .right
            p.firstLineHeadIndent = max(70, w * 0.26)
            p.headIndent = p.firstLineHeadIndent
            p.tailIndent = -16
        } else {
            p.firstLineHeadIndent = 16
            p.headIndent = 16
            p.tailIndent = -max(56, w * 0.17)
        }
        return p
    }

    private func startReply() {
        hideTyping()
        ensureNewline()
        streamStart = textView.textStorage?.length ?? 0
        streamBubbles = []
        replies += 1
    }

    /// His reply so far, as bubbles: a new one at each blank line, colours taking turns, eyes on the first.
    private func restyleReply() {
        guard let storage = textView.textStorage, streamStart <= storage.length else { return }
        let ns = storage.string as NSString
        let end = storage.length
        let eyes: [BubbleInfo.Eyes] = [.wide, .side, .wide, .sleepy]
        var block = 0, open = false, loc = streamStart
        storage.beginEditing()
        storage.removeAttribute(.carrotoBubble, range: NSRange(location: streamStart, length: end - streamStart))
        while loc < end {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // a blank line: the next text starts a new bubble (and the gap stays small)
                if open { block += 1; open = false }
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 2), .paragraphStyle: NSParagraphStyle()], range: para)
            } else {
                while streamBubbles.count <= block {
                    streamBubbles.append(Sticker.hisBubble(streamBubbles.count, eyes: eyes[replies % eyes.count]))
                }
                storage.addAttribute(.paragraphStyle, value: bubbleStyle(mine: false, first: !open), range: para)
                storage.addAttribute(.carrotoBubble, value: streamBubbles[block], range: para)
                open = true
            }
            if NSMaxRange(para) <= loc { break }
            loc = NSMaxRange(para)
        }
        storage.endEditing()
    }

    private func showTyping() {
        guard typingRange == nil, let storage = textView.textStorage else { return }
        ensureNewline()
        let dots = NSMutableAttributedString()
        for (i, c) in [Sticker.carrot, Sticker.cobalt, Sticker.pink].enumerated() {
            dots.append(NSAttributedString(string: i == 0 ? "●" : "  ●", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: c]))
        }
        dots.append(NSAttributedString(string: "\n"))
        dots.addAttributes([.paragraphStyle: bubbleStyle(mine: false, first: true),
                            .carrotoBubble: BubbleInfo(fill: .white, halo: Sticker.cream2, eyes: .none, mine: false)],
                           range: NSRange(location: 0, length: dots.length))
        typingRange = NSRange(location: storage.length, length: dots.length)
        storage.append(dots)
        scrollToBottom()
    }

    private func hideTyping() {
        guard let r = typingRange, let storage = textView.textStorage else { return }
        typingRange = nil
        if NSMaxRange(r) <= storage.length { storage.deleteCharacters(in: r) }
    }

    func appendSticker(_ name: String) {
        guard let img = Sticker.image(name, size: 78), let storage = textView.textStorage else { return }
        ensureNewline()
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(origin: .zero, size: img.size)
        let s = NSMutableAttributedString(attachment: att)
        s.append(NSAttributedString(string: "\n"))
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 10
        p.paragraphSpacingBefore = 10
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        storage.append(s)
        scrollToBottom()
    }

    func appendError(_ text: String) {
        hideTyping()
        let t = theme
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: t.font, .foregroundColor: t.errorColor
        ]))
        scrollToBottom()
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        endStreaming()
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "  \(toolName.uppercased()) ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        let color = isError ? t.errorColor : t.successColor
        let prefix = isError ? "  FAIL " : "  DONE "
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: prefix, attributes: [
            .font: t.fontBold, .foregroundColor: color
        ]))
        block.append(NSAttributedString(string: "\(summary.isEmpty ? "" : summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func replayHistory(_ messages: [AgentMessage]) {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                if stickerStyle {
                    startReply()
                    textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
                    restyleReply()
                } else {
                    textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
                }
            case .error:
                appendError(msg.text)
            case .toolUse:
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
            case .toolResult:
                let isErr = msg.text.hasPrefix("ERROR:")
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: isErr ? t.errorColor : t.successColor
                ]))
            }
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let t = theme
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockLang = ""
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeLines.joined(separator: "\n")
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
                    result.append(NSAttributedString(string: codeText + "\n", attributes: [
                        .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                    codeBlockLang = String(line.dropFirst(3))
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if line.hasPrefix("### ") {
                result.append(NSAttributedString(string: String(line.dropFirst(4)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("## ") {
                result.append(NSAttributedString(string: String(line.dropFirst(3)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 1, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 2, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                result.append(NSAttributedString(string: "  \u{2022} ", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
                result.append(renderInlineMarkdown(content + suffix, theme: t))
            } else {
                result.append(renderInlineMarkdown(line + suffix, theme: t))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            let codeText = codeLines.joined(separator: "\n")
            let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
            result.append(NSAttributedString(string: codeText + "\n", attributes: [
                .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
            ]))
        }

        return result
    }

    private func renderInlineMarkdown(_ text: String, theme t: PopoverTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex

        while i < text.endIndex {
            if text[i] == "`" {
                let afterTick = text.index(after: i)
                if afterTick < text.endIndex, let closeIdx = text[afterTick...].firstIndex(of: "`") {
                    let code = String(text[afterTick..<closeIdx])
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 0.5, weight: .regular)
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: codeFont, .foregroundColor: t.accentColor, .backgroundColor: t.inputBg
                    ]))
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            if text[i] == "*",
               text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    let bold = String(text[start..<range.lowerBound])
                    result.append(NSAttributedString(string: bold, attributes: [
                        .font: t.fontBold, .foregroundColor: t.textPrimary
                    ]))
                    i = range.upperBound
                    continue
                }
            }
            if text[i] == "[" {
                let afterBracket = text.index(after: i)
                if afterBracket < text.endIndex,
                   let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let parenStart = text.index(after: closeBracket)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let afterParen = text.index(after: parenStart)
                        if afterParen < text.endIndex,
                           let closeParen = text[afterParen...].firstIndex(of: ")") {
                            let linkText = String(text[afterBracket..<closeBracket])
                            let urlStr = String(text[afterParen..<closeParen])
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: t.font,
                                .foregroundColor: t.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                            if let url = URL(string: urlStr) {
                                attrs[.link] = url
                                attrs[.cursor] = NSCursor.pointingHand
                            }
                            result.append(NSAttributedString(string: linkText, attributes: attrs))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }
            if text[i] == "h" {
                let remaining = String(text[i...])
                if remaining.hasPrefix("https://") || remaining.hasPrefix("http://") {
                    var j = i
                    while j < text.endIndex && !text[j].isWhitespace && text[j] != ")" && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    let urlStr = String(text[i..<j])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: t.font,
                        .foregroundColor: t.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                    if let url = URL(string: urlStr) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: urlStr, attributes: attrs))
                    i = j
                    continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: t.font, .foregroundColor: t.textPrimary
            ]))
            i = text.index(after: i)
        }
        return result
    }
}

// MARK: - The sticker look (the chat window's style)
//
// Flat bold shapes, no black outlines, big white eyes, thin line legs, and a soft halo border in a lighter
// tint of each colour, on warm cream. Every sticker follows those rules so new ones match:
// add an SVG to `Sticker.svgs` (viewBox 0 0 80 80, the same palette, a face with white eyes).

enum CarrotoFonts {
    private static let registered: Void = {
        for name in ["gochi", "bricolage"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    /// the hand-written font, Gochi Hand (status lines, little notes)
    static func hand(_ size: CGFloat) -> NSFont {
        _ = registered
        return NSFont(name: "GochiHand-Regular", size: size) ?? .systemFont(ofSize: size)
    }
    /// the chunky display font, Bricolage Grotesque (his name)
    static func display(_ size: CGFloat) -> NSFont {
        _ = registered
        let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: "Bricolage Grotesque",
                                      kCTFontVariationAttribute: [0x77676874: 800, 0x6F70737A: 36]]   // wght 800, opsz 36
        let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil) as NSFont
        return font.familyName == "Bricolage Grotesque" ? font : .systemFont(ofSize: size, weight: .heavy)
    }
}

enum Sticker {
    static func hex(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
    }
    static let ink = hex(0x26282d), cream = hex(0xf6efe4), cream2 = hex(0xece3d6), dim = hex(0x9c9184), brown = hex(0x9a6b47)
    static let carrot = hex(0xf47b20), carrotHalo = hex(0xfbd9bd)
    static let sunny = hex(0xffd84a), sunnyHalo = hex(0xfff0b8)
    static let pink = hex(0xf59ad6), pinkHalo = hex(0xfcd8ef)
    static let cobalt = hex(0x2d55e8), cobaltHalo = hex(0xc9d5fb)
    static let mint = hex(0xb7ecc6), mintHalo = hex(0xe0f7e7)
    static let lilac = hex(0xe9dcff)

    /// his bubbles take turns: sunny, pink, white, mint. The first of each reply has eyes peeking over it.
    static func hisBubble(_ i: Int, eyes: BubbleInfo.Eyes) -> BubbleInfo {
        let fills: [(NSColor, NSColor)] = [(sunny, sunnyHalo), (pink, pinkHalo), (.white, cream2), (mint, mintHalo)]
        let (f, h) = fills[i % fills.count]
        return BubbleInfo(fill: f, halo: h, eyes: i == 0 ? eyes : .none, mine: false)
    }

    private static let leg = ##"stroke="#26282d" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round""##
    static let svgs: [String: String] = [
        "face": ##"<path d="M20 10c-4-6-1-9 2-9m4 9c2-6 6-7 9-5m-11 5c0-4 1-7 3-9" stroke="#3e9a4d" stroke-width="3" fill="none" stroke-linecap="round"/><path d="M8 14h32c2 0 3 2 2 4L27 48c-1 3-5 3-6 0L6 18c-1-2 0-4 2-4z" fill="#f47b20"/><ellipse cx="18" cy="24" rx="5.5" ry="6.5" fill="#fff"/><ellipse cx="30" cy="24" rx="5.5" ry="6.5" fill="#fff"/><circle cx="19.5" cy="25" r="3" fill="#26282d"/><circle cx="31.5" cy="25" r="3" fill="#26282d"/>"##,
        "send": ##"<circle cx="20" cy="20" r="19" fill="#f47b20"/><ellipse cx="15" cy="17" rx="4" ry="4.6" fill="#fff"/><ellipse cx="25" cy="17" rx="4" ry="4.6" fill="#fff"/><circle cx="15.5" cy="15" r="2.2" fill="#26282d"/><circle cx="25.5" cy="15" r="2.2" fill="#26282d"/><path d="M14 27q6 4 12 0" stroke="#fff" stroke-width="2.4" fill="none" stroke-linecap="round"/>"##,
        "star": ##"<path d="M40 4l10 20 22 3-16 15 4 22-20-10-20 10 4-22L8 27l22-3z" fill="#fff0b8" stroke="#fff0b8" stroke-width="8" stroke-linejoin="round"/><path d="M40 4l10 20 22 3-16 15 4 22-20-10-20 10 4-22L8 27l22-3z" fill="#ffd84a"/><ellipse cx="34" cy="34" rx="5.5" ry="6.5" fill="#fff"/><ellipse cx="46" cy="34" rx="5.5" ry="6.5" fill="#fff"/><circle cx="34" cy="35" r="3" fill="#26282d"/><circle cx="46" cy="35" r="3" fill="#26282d"/><path d="M32 66v8m16-8v8" LEG/>"##,
        "heart": ##"<path d="M40 64C14 48 8 34 14 24c6-9 18-8 26 3 8-11 20-12 26-3 6 10 0 24-26 40z" fill="#fcd8ef" stroke="#fcd8ef" stroke-width="8" stroke-linejoin="round"/><path d="M40 64C14 48 8 34 14 24c6-9 18-8 26 3 8-11 20-12 26-3 6 10 0 24-26 40z" fill="#f59ad6"/><path d="M27 36q5 5 10 0M43 36q5 5 10 0" stroke="#26282d" stroke-width="2.6" fill="none" stroke-linecap="round"/>"##,
        "focus": ##"<path d="M18 56V30a22 22 0 0 1 44 0v26z" fill="#c9d5fb" stroke="#c9d5fb" stroke-width="8" stroke-linejoin="round"/><path d="M18 56V30a22 22 0 0 1 44 0v26z" fill="#2d55e8"/><path d="M26 34h12v6H26zM42 34h12v6H42z" fill="#fff"/><circle cx="31" cy="37" r="2.6" fill="#26282d"/><circle cx="47" cy="37" r="2.6" fill="#26282d"/><path d="M16 46c-8-2-10-10-4-14m52 14c8-2 10-10 4-14" LEG/>"##,
        "idea": ##"<path d="M40 8c7 0 8 9 14 10s14-3 16 4-7 11-6 18 9 11 4 17-13 0-18 4-4 13-10 13-6-9-11-12-14 1-17-5 6-11 5-18-9-11-4-17 13 0 18-4 2-10 9-10z" fill="#ffc6c6" stroke="#ffc6c6" stroke-width="7" stroke-linejoin="round"/><path d="M40 8c7 0 8 9 14 10s14-3 16 4-7 11-6 18 9 11 4 17-13 0-18 4-4 13-10 13-6-9-11-12-14 1-17-5 6-11 5-18-9-11-4-17 13 0 18-4 2-10 9-10z" fill="#ec4b48"/><circle cx="40" cy="40" r="13" fill="#fff"/><circle cx="40" cy="40" r="7" fill="#26282d"/>"##,
        "nap": ##"<path d="M14 58a26 22 0 0 1 52 0z" fill="#fbd9bd" stroke="#fbd9bd" stroke-width="8" stroke-linejoin="round"/><path d="M14 58a26 22 0 0 1 52 0z" fill="#f47b20"/><path d="M27 48a6 6 0 0 0 12 0zM41 48a6 6 0 0 0 12 0z" fill="#fff"/><path d="M27 48h12M41 48h12" stroke="#26282d" stroke-width="2.6" fill="none" stroke-linecap="round"/><path d="M57 34q4-6 8-2m-2-8q4-4 7 0" stroke="#26282d" stroke-width="1.6" fill="none" stroke-linecap="round"/>"##,
        "nice": ##"<path d="M30 64V30c0-6 4-8 7-8V12c0-5 8-5 8 0v10h4c4 0 6 3 6 6v6c3 0 5 2 5 5v14c0 9-6 15-15 15h-5c-6 0-10-3-10-4z" fill="#e9dcff" stroke="#e9dcff" stroke-width="8" stroke-linejoin="round"/><path d="M30 64V30c0-6 4-8 7-8V12c0-5 8-5 8 0v10h4c4 0 6 3 6 6v6c3 0 5 2 5 5v14c0 9-6 15-15 15h-5c-6 0-10-3-10-4z" fill="#9b7ff5"/><ellipse cx="40" cy="42" rx="4.5" ry="5.2" fill="#fff"/><ellipse cx="50" cy="42" rx="4.5" ry="5.2" fill="#fff"/><circle cx="41" cy="41" r="2.4" fill="#26282d"/><circle cx="51" cy="41" r="2.4" fill="#26282d"/><path d="M42 52q4 3 8 0" LEG/>"##,
        "lunch": ##"<path d="M22 20h36v34a18 18 0 0 1-36 0z" fill="#fff0b8" stroke="#fff0b8" stroke-width="8" stroke-linejoin="round"/><path d="M22 20h36v34a18 18 0 0 1-36 0z" fill="#f4b23a"/><path d="M58 28h6a6 6 0 0 1 0 14h-6" stroke="#26282d" stroke-width="3" fill="none" stroke-linecap="round"/><ellipse cx="34" cy="40" rx="5" ry="5.5" fill="#fff"/><ellipse cx="46" cy="40" rx="5" ry="5.5" fill="#fff"/><circle cx="35" cy="38" r="2.6" fill="#26282d"/><circle cx="47" cy="38" r="2.6" fill="#26282d"/><path d="M34 14q2-4 0-8m10 8q2-4 0-8" stroke="#26282d" stroke-width="1.6" fill="none" stroke-linecap="round"/>"##,
        "home": ##"<path d="M10 44a30 22 0 0 1 60 0z" fill="#c9d5fb" stroke="#c9d5fb" stroke-width="8" stroke-linejoin="round"/><path d="M10 44a30 22 0 0 1 60 0z" fill="#2d55e8"/><path d="M26 38a6 6 0 0 1 12 0zM42 38a6 6 0 0 1 12 0z" fill="#fff"/><path d="M29 38a3 3 0 0 1 6 0zM45 38a3 3 0 0 1 6 0z" fill="#26282d"/><path d="M38 50c0 4 3 4 3 7s-3 3-3 1" stroke="#26282d" stroke-width="1.6" fill="none" stroke-linecap="round"/>"##,
        "win": ##"<path d="M40 2c8 0 10 10 16 12s16-2 18 6-8 12-8 20 8 14 2 20-14-2-20 2-8 12-16 12-10-10-16-12-16 2-18-6 8-12 8-20-8-14-2-20 14 2 20-2 8-12 16-12z" fill="#b7ecc6"/><path d="M40 8c6 0 8 9 13 10s13-1 15 5-7 10-7 17 7 12 2 16-12-1-17 2-6 10-12 10-8-9-13-10-13 1-15-5 7-10 7-17-7-12-2-16 12 1 17-2 6-10 12-10z" fill="#3fa45b"/><text x="40" y="44" text-anchor="middle" font-family="Helvetica" font-weight="bold" font-size="13" fill="#fff">you</text><text x="40" y="58" text-anchor="middle" font-family="Helvetica" font-weight="bold" font-size="13" fill="#fff">did it!</text><ellipse cx="34" cy="27" rx="4" ry="4.5" fill="#fff"/><ellipse cx="46" cy="27" rx="4" ry="4.5" fill="#fff"/><circle cx="35" cy="26" r="2" fill="#26282d"/><circle cx="47" cy="26" r="2" fill="#26282d"/>"##,
    ]

    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(size)"
        if let i = cache[key] { return i }
        guard let body = svgs[name] else { return nil }
        let box = name == "face" ? "0 0 48 52" : name == "send" ? "0 0 40 40" : "0 0 80 80"
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="\##(box)">\##(body.replacingOccurrences(of: "LEG", with: leg))</svg>"##
        guard let img = NSImage(data: Data(svg.utf8)) else { return nil }
        let parts = box.split(separator: " ").compactMap { Double($0) }
        img.size = NSSize(width: size * CGFloat(parts[2] / parts[3]), height: size)
        cache[key] = img
        return img
    }

    /// Now and then he sticks a sticker after a reply, when it fits the moment (never two in a row).
    static func pick(you: String, him: String) -> String? {
        let y = you.lowercased(), h = him.lowercased()
        func has(_ s: String, _ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(y, ["shipped", "launched", "posted", "finished", "done!", "i did it", "sent it", "nailed", "won "]) { return Bool.random() ? "win" : "star" }
        if has(y + h, ["lunch", "hungry", "snack", "coffee", "tea "]) { return "lunch" }
        if has(y + h, ["nap", "sleepy", "tired", "good night", "goodnight"]) { return "nap" }
        if has(y + h, ["go home", "log off", "logging off", "calling it"]) { return "home" }
        if has(y + h, ["focus", "deep work", "heads down", "heads-down"]) { return "focus" }
        if has(y, ["brainstorm", "idea", "angles"]) { return "idea" }
        if has(y, ["thank", "love you", "aww", "<3", "❤"]) { return "heart" }
        if has(h, ["nice one", "proud of you", "look at you", "well done", "great work"]) { return "nice" }
        return nil
    }
}

/// One chat bubble: what's drawn behind a message (and the eyes peeking over his).
final class BubbleInfo: NSObject {
    enum Eyes { case none, wide, side, sleepy }
    let fill: NSColor, halo: NSColor, eyes: Eyes, mine: Bool
    init(fill: NSColor, halo: NSColor, eyes: Eyes, mine: Bool) { self.fill = fill; self.halo = halo; self.eyes = eyes; self.mine = mine }
}

extension NSAttributedString.Key {
    static let carrotoBubble = NSAttributedString.Key("carrotoBubble")
}

/// Draws a rounded bubble (with a soft halo) behind each run of text marked `.carrotoBubble`,
/// hugging the text, and a pair of eyes peeking over the top of the ones that have them.
final class BubbleLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var done = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.carrotoBubble, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let b = value as? BubbleInfo, NSIntersectionRange(range, shown).length > 0 || NSLocationInRange(range.location, shown),
                  done.insert(ObjectIdentifier(b)).inserted else { return }
            // the whole bubble, minus its trailing newline(s)
            var full = NSRange()
            _ = storage.attribute(.carrotoBubble, at: range.location, longestEffectiveRange: &full, in: NSRange(location: 0, length: storage.length))
            while full.length > 0, let c = Unicode.Scalar(ns.character(at: NSMaxRange(full) - 1)), CharacterSet.newlines.contains(c) { full.length -= 1 }
            guard full.length > 0 else { return }
            let glyphs = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            var rect = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
                let r = NSIntersectionRange(lineGlyphs, glyphs)
                guard r.length > 0 else { return }
                let ink = self.boundingRect(forGlyphRange: r, in: container)
                rect = rect.union(NSRect(x: ink.minX, y: used.minY, width: ink.width, height: used.height))
            }
            guard !rect.isNull else { return }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -12, dy: -7)
            let radius = min(18, rect.height / 2)
            b.halo.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -3.5, dy: -3.5), xRadius: radius + 3.5, yRadius: radius + 3.5).fill()
            b.fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            if b.eyes != .none { drawEyes(b, over: rect) }
        }
    }

    private func drawEyes(_ b: BubbleInfo, over r: NSRect) {
        // two eyes on the bubble's top edge, near the right (the text view is flipped: minY is the top)
        for cx in [r.maxX - 34, r.maxX - 18] {
            let eye = NSRect(x: cx - 7, y: r.minY - 9, width: 14, height: 16)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: eye).fill()
            Sticker.ink.setFill()
            switch b.eyes {
            case .wide: NSBezierPath(ovalIn: NSRect(x: cx - 2, y: r.minY - 6, width: 7, height: 7)).fill()
            case .side: NSBezierPath(ovalIn: NSRect(x: cx, y: r.minY - 2, width: 6.5, height: 6.5)).fill()
            case .sleepy:
                NSBezierPath(ovalIn: NSRect(x: cx - 3.5, y: r.minY - 1, width: 7, height: 7)).fill()
                b.fill.setFill()                                           // a heavy lid
                NSBezierPath(rect: NSRect(x: cx - 8, y: r.minY - 10, width: 16, height: 9)).fill()
                NSBezierPath(ovalIn: NSRect(x: cx - 8, y: r.minY - 12, width: 16, height: 12)).fill()
            case .none: break
            }
        }
    }
}
