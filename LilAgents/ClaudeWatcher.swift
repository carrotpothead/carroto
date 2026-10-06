import AppKit
import Network

// carroto watches your AI coding tools from the dock: Claude Code, Codex, Cursor, Gemini CLI.
//
// Claude Code calls a few "HTTP hooks" (registered in ~/.claude/settings.json by `ClaudeWatcher.install()`):
//   PermissionRequest → POST /permission   he shows what Claude wants to do, with Allow / Deny; the click goes back
//   Notification      → POST /notify       "claude's waiting for you"
//   Stop              → POST /stop         Claude finished: a little cheer
// He only listens on 127.0.0.1 (this Mac). If carroto isn't running, the hook can't connect and Claude Code shows
// its normal prompt in the terminal; if nobody answers in time, the same.

final class ClaudeWatcher {
    static let port: UInt16 = 47380
    private var listener: NWListener?
    weak var carrot: WalkerCharacter?
    private let panel = ApprovalPanel()
    /// permission requests waiting for a click, oldest first (each holds its open connection)
    private var queue: [(id: Int, info: [String: Any], reply: (Bool?) -> Void)] = []
    private var nextID = 0
    private var lastStop: CFTimeInterval = 0

    init(carrot: WalkerCharacter) { self.carrot = carrot }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: .main)
        listener = l
    }

    // MARK: a tiny HTTP server (one request per connection)

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                if let data = data { buffer.append(data) }
                if let (path, body) = Self.parse(buffer) { self?.handle(path, body, c); return }
                if done || err != nil { c.cancel(); return }
                read()
            }
        }
        read()
    }

    /// (path, body) once the whole request is in
    private static func parse(_ d: Data) -> (String, Data)? {
        guard let headEnd = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let len = lines.compactMap { l -> Int? in
            let p = l.split(separator: ":", maxSplits: 1)
            return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        let body = d[headEnd.upperBound...]
        return body.count >= len ? (path, Data(body.prefix(len))) : nil
    }

    private func respond(_ c: NWConnection, _ json: [String: Any] = [:]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func handle(_ fullPath: String, _ body: Data, _ c: NWConnection) {
        var info = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let parts = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? "/")
        let src = parts.count > 1 ? String(parts[1].split(separator: "=").last ?? "claude") : "claude"
        info["_src"] = src
        // cursor sends just {command, cwd}: make it look like the others
        if src == "cursor", info["tool_name"] == nil, let cmd = info["command"] { info["tool_name"] = "Bash"; info["tool_input"] = ["command": cmd] }
        if src == "gemini", let n = info["tool_name"] as? String {
            info["tool_name"] = ["run_shell_command": "Bash", "write_file": "Write", "replace": "Edit", "web_fetch": "WebFetch"][n] ?? n
        }
        switch path {
        case "/permission":
            var answered = false
            let reply: (Bool?) -> Void = { [weak self] allow in
                guard !answered else { return }
                answered = true
                let why = "denied from carroto on the dock"
                switch src {
                case "cursor":   // cursor: allow / deny / ask (its own prompt)
                    self?.respond(c, ["permission": allow == nil ? "ask" : allow! ? "allow" : "deny", "user_message": allow == false ? why : ""])
                case "gemini":
                    guard let allow = allow else { self?.respond(c); return }
                    self?.respond(c, allow ? ["decision": "allow"] : ["decision": "deny", "reason": why])
                default:         // claude code and codex speak the same hook language
                    guard let allow = allow else { self?.respond(c); return }   // no answer: it asks in the terminal
                    var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
                    if !allow { decision["message"] = why }
                    self?.respond(c, ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
                }
            }
            // give up a little before Claude Code's own timeout, so the terminal prompt takes over cleanly
            nextID += 1
            let id = nextID
            DispatchQueue.main.asyncAfter(deadline: .now() + 110) { [weak self] in
                guard let self = self, let i = self.queue.firstIndex(where: { $0.id == id }) else { return }
                self.queue.remove(at: i); reply(nil); self.showNext()
            }
            queue.append((id, info, reply))
            if queue.count == 1 { showNext() }
        case "/notify":
            respond(c)
            let type = info["notification_type"] as? String ?? ""
            if type == "idle_prompt" || type == "agent_needs_input" || type == "elicitation_dialog" {
                carrot?.playCompletionSound()
                carrot?.say("\(Self.who(info))'s waiting for you\(Self.project(info)).", for: 6)
            }
        case "/stop":
            respond(c)
            let now = CACurrentMediaTime()
            guard now - lastStop > 20 else { return }      // (several in a row: once is enough)
            lastStop = now
            carrot?.playCompletionSound()
            let w = Self.who(info)
            carrot?.say(["\(w)'s done\(Self.project(info)). ✨", "\(w) finished\(Self.project(info)). go look.", "done\(Self.project(info)). nice one, \(w)."].randomElement()!, for: 5)
        default:
            respond(c)
        }
    }

    private func showNext() {
        guard let next = queue.first, let c = carrot else { panel.close(); return }
        c.playCompletionSound()
        if !c.colleague.isFocusing { c.perform("land") }   // a little startled hop so you notice
        panel.show(title: "\(Self.who(next.info)) wants to\(Self.project(next.info)):", detail: Self.describe(next.info), waiting: queue.count - 1,
                   above: c.window.frame) { [weak self] allow in
            guard let self = self, !self.queue.isEmpty else { return }
            let first = self.queue.removeFirst()
            first.reply(allow)
            self.carrot?.say(allow ? "approved. 👍" : "nope. told \(Self.who(first.info)).", for: 2.5)
            self.showNext()
        }
    }

    static func who(_ info: [String: Any]) -> String { ["codex": "codex", "cursor": "cursor", "gemini": "gemini"][info["_src"] as? String ?? ""] ?? "claude" }

    /// " in “the chat's title”" — or the project folder if there's no title to find
    static func project(_ info: [String: Any]) -> String {
        if let title = chatTitle(info) { return " in “\(title)”" }
        guard let cwd = info["cwd"] as? String, !cwd.isEmpty else { return "" }
        return " in \((cwd as NSString).lastPathComponent)"
    }

    /// The chat's name: Claude Code keeps it in the conversation file ("custom-title" lines; the newest wins).
    /// No title yet: the start of the first thing you asked. Cached per conversation.
    private static var titles: [String: (String?, Date)] = [:]
    static func chatTitle(_ info: [String: Any]) -> String? {
        guard let path = info["transcript_path"] as? String, !path.isEmpty else { return nil }
        if let hit = titles[path], Date().timeIntervalSince(hit.1) < 30 { return hit.0 }
        var found: String?
        if let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 400_000 ? size - 400_000 : 0)          // the newest part of the file
            let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
            for line in tail.split(separator: "\n").reversed() where line.contains("\"custom-title\"") || line.contains("\"ai-title\"") {
                if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                   let t = (o["customTitle"] ?? o["aiTitle"] ?? o["title"]) as? String, !t.isEmpty { found = t; break }
            }
            if found == nil {                                                   // no title: the first thing you asked
                try? fh.seek(toOffset: 0)
                let head = String(decoding: fh.readData(ofLength: 200_000), as: UTF8.self)
                for line in head.split(separator: "\n") where line.contains("\"type\":\"user\"") {
                    guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          let msg = o["message"] as? [String: Any], let text = msg["content"] as? String,
                          !text.hasPrefix("<") else { continue }
                    found = text; break
                }
            }
        }
        if let f = found {
            let one = f.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            found = one.count > 34 ? String(one.prefix(33)).trimmingCharacters(in: .whitespaces) + "…" : one
        }
        titles[path] = (found, Date())
        return found
    }

    /// What the tool call is, in plain words: the command, the file, the URL…
    static func describe(_ info: [String: Any]) -> String {
        let tool = info["tool_name"] as? String ?? "something"
        let input = info["tool_input"] as? [String: Any] ?? [:]
        func short(_ s: String, _ n: Int = 220) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        switch tool {
        case "Bash": return "run: " + short((input["command"] as? String) ?? "")
        case "Edit", "MultiEdit", "apply_patch": return "edit " + short(((input["file_path"] as? String) ?? (input["path"] as? String) ?? "files") as String)
        case "Write": return "write " + short((input["file_path"] as? String) ?? "")
        case "Read": return "read " + short((input["file_path"] as? String) ?? "")
        case "WebFetch": return "open " + short((input["url"] as? String) ?? "")
        case "WebSearch": return "search: " + short((input["query"] as? String) ?? "")
        default:
            let first = input.first.map { "\($0.key): \($0.value)" } ?? ""
            return short("use \(tool)" + (first.isEmpty ? "" : " — \(first)"))
        }
    }

    // MARK: switching it on and off — Claude Code, Codex, Cursor, Gemini CLI (whichever are on this Mac)

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private static func url(_ path: String, _ src: String = "claude") -> String { "http://127.0.0.1:\(port)/\(path)?src=\(src)" }

    /// The little script the command-hook tools (codex, cursor, gemini) run: pass the request to carroto, print his answer.
    /// If carroto isn't running, it prints nothing (cursor: "ask"), so the tool asks you itself.
    static var hookScript: URL { CarrotoMemory.url.deletingLastPathComponent().appendingPathComponent("carroto-hook.sh") }
    private static func writeHookScript() {
        let sh = """
        #!/bin/sh
        # carroto on the dock answers AI-tool permission requests. usage: carroto-hook.sh <permission|stop|notify> <claude|codex|cursor|gemini>
        out=$(curl -s -m 115 -X POST -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:\(port)/$1?src=$2")
        if [ -n "$out" ] && [ "$out" != "{}" ]; then printf '%s' "$out"; elif [ "$2" = cursor ] && [ "$1" = permission ]; then printf '{"permission":"ask"}'; fi
        exit 0
        """
        try? sh.write(to: hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)
    }
    private static func cmd(_ event: String, _ src: String) -> String { "'\(hookScript.path)' \(event) \(src)" }

    /// The tools we know how to watch, and the file each keeps its hooks in. Only those you have are touched.
    static var tools: [(name: String, file: URL, has: Bool)] {
        let fm = FileManager.default
        return [("claude", settingsURL, fm.fileExists(atPath: home.appendingPathComponent(".claude").path)),
                ("codex", home.appendingPathComponent(".codex/hooks.json"), fm.fileExists(atPath: home.appendingPathComponent(".codex").path)),
                ("cursor", home.appendingPathComponent(".cursor/hooks.json"), fm.fileExists(atPath: home.appendingPathComponent(".cursor").path)),
                ("gemini", home.appendingPathComponent(".gemini/settings.json"), fm.fileExists(atPath: home.appendingPathComponent(".gemini").path))]
    }

    static var isInstalled: Bool {
        guard let s = readJSON(settingsURL), let hooks = s["hooks"] as? [String: Any] else { return false }
        return (hooks["PermissionRequest"] as? [[String: Any]])?.contains(where: isOurs) ?? false
    }

    /// one of ours: a hook pointing at carroto (by URL or by the script)
    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let mine: ([String: Any]) -> Bool = { h in
            ((h["url"] as? String)?.contains("127.0.0.1:\(port)/") ?? false) || ((h["command"] as? String)?.contains("carroto-hook.sh") ?? false)
        }
        if mine(entry) { return true }
        return (entry["hooks"] as? [[String: Any]])?.contains(where: mine) ?? false
    }

    private static func readJSON(_ u: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: u) else { return [:] }                 // no file yet: start empty
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]     // nil: not plain JSON, leave it alone
    }

    private static func writeJSON(_ obj: [String: Any], _ u: URL) -> Bool {
        if let d = try? Data(contentsOf: u) { try? d.write(to: u.appendingPathExtension("before-carroto")) }   // a backup, every time
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? out.write(to: u, options: .atomic)) != nil
    }

    /// Put carroto's entries into one hooks map (event → list), replacing any old ones of ours, keeping everything else.
    private static func merge(_ hooks: inout [String: Any], _ ours: [(String, [String: Any])], on: Bool) {
        let events = Set(ours.map(\.0) + ["PermissionRequest", "Notification", "Stop", "beforeShellExecution", "stop", "BeforeTool", "AfterAgent"])
        for e in events {
            var list = (hooks[e] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            if on { list += ours.filter { $0.0 == e }.map(\.1) }
            if list.isEmpty { hooks.removeValue(forKey: e) } else { hooks[e] = list }
        }
    }

    /// Add (or remove) carroto's hooks for every tool on this Mac. Backs each file up first. Returns the tools switched.
    @discardableResult
    static func setInstalled(_ on: Bool) -> Bool {
        if on { writeHookScript() }
        var ok = true
        for tool in tools where tool.has || tool.name == "claude" {
            guard var s = readJSON(tool.file) else { ok = ok && tool.name != "claude"; continue }
            var hooks = s["hooks"] as? [String: Any] ?? [:]
            let group = { (matcher: String?, hook: [String: Any]) -> [String: Any] in
                var g: [String: Any] = ["hooks": [hook]]; if let m = matcher { g["matcher"] = m }; return g
            }
            switch tool.name {
            case "claude":
                merge(&hooks, [("PermissionRequest", group("*", ["type": "http", "url": url("permission"), "timeout": 120])),
                               ("Notification", group(nil, ["type": "http", "url": url("notify"), "timeout": 5])),
                               ("Stop", group(nil, ["type": "http", "url": url("stop"), "timeout": 5]))], on: on)
            case "codex":
                merge(&hooks, [("PermissionRequest", group(".*", ["type": "command", "command": cmd("permission", "codex"), "timeout": 120])),
                               ("Stop", group(nil, ["type": "command", "command": cmd("stop", "codex"), "timeout": 5]))], on: on)
            case "cursor":
                s["version"] = s["version"] ?? 1
                merge(&hooks, [("beforeShellExecution", ["command": cmd("permission", "cursor"), "timeout": 120]),
                               ("stop", ["command": cmd("stop", "cursor"), "timeout": 5])], on: on)
            case "gemini":   // only the tools that change things (reading files doesn't need asking)
                merge(&hooks, [("BeforeTool", group("run_shell_command|write_file|replace|web_fetch", ["type": "command", "command": cmd("permission", "gemini"), "timeout": 120000])),
                               ("AfterAgent", group(nil, ["type": "command", "command": cmd("stop", "gemini"), "timeout": 5000]))], on: on)
            default: break
            }
            if hooks.isEmpty { s.removeValue(forKey: "hooks") } else { s["hooks"] = hooks }
            if tool.name == "cursor", hooks.isEmpty, s.keys.sorted() == ["version"] { try? FileManager.default.removeItem(at: tool.file); continue }
            ok = writeJSON(s, tool.file) && ok
        }
        return ok
    }

    /// "claude code, codex" — which tools he's watching (for his bubble)
    static var watchedNames: String {
        tools.filter { $0.has || $0.name == "claude" }.map { ["claude": "claude code", "codex": "codex", "cursor": "cursor", "gemini": "gemini"][$0.name]! }.joined(separator: ", ")
    }
}

// MARK: - The approval card

/// A card above him: what Claude wants to do, and Deny / Allow. Esc = Deny is too easy to hit by accident, so Esc just
/// hides it (the request then falls back to the terminal after a while).
final class ApprovalPanel: NSObject {
    private var window: NSWindow?
    private var onAnswer: ((Bool) -> Void)?

    func show(title: String, detail: String, waiting: Int, above frame: NSRect, answer: @escaping (Bool) -> Void) {
        close()
        onAnswer = answer
        let w: CGFloat = 340
        let detailFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let dH = min(110, max(18, ceil((detail as NSString).boundingRect(with: NSSize(width: w - 36, height: 600), options: [.usesLineFragmentOrigin], attributes: [.font: detailFont]).height)))
        let h: CGFloat = 104 + dH + (waiting > 0 ? 16 : 0)
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
        t.frame = NSRect(x: 54, y: h - 42, width: w - 70, height: 18); t.lineBreakMode = .byTruncatingTail; box.addSubview(t)

        let card = NSView(frame: NSRect(x: 14, y: 56 + (waiting > 0 ? 16 : 0), width: w - 28, height: dH + 16))
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor.white.cgColor; card.layer?.cornerRadius = 12
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = detailFont; d.textColor = Sticker.ink; d.maximumNumberOfLines = 8
        d.frame = NSRect(x: 10, y: 8, width: card.frame.width - 20, height: dH); card.addSubview(d)
        box.addSubview(card)

        if waiting > 0 {
            let more = NSTextField(labelWithString: "+\(waiting) more waiting")
            more.font = CarrotoFonts.hand(13); more.textColor = Sticker.brown
            more.frame = NSRect(x: 16, y: 52, width: 200, height: 16); box.addSubview(more)
        }
        func pill(_ title: String, _ fill: NSColor, _ halo: NSColor, _ fg: NSColor, x: CGFloat, action: Selector) -> NSButton {
            let b = NSButton(frame: NSRect(x: x, y: 14, width: (w - 42) / 2, height: 32))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: fg])
            b.wantsLayer = true; b.layer?.backgroundColor = fill.cgColor; b.layer?.cornerRadius = 16
            b.layer?.borderWidth = 3; b.layer?.borderColor = halo.cgColor
            b.target = self; b.action = action
            return b
        }
        box.addSubview(pill("deny", .white, Sticker.cream2, Sticker.ink, x: 14, action: #selector(deny)))
        let allow = pill("allow", Sticker.cobalt, Sticker.cobaltHalo, .white, x: 28 + (w - 42) / 2, action: #selector(allowIt))
        allow.keyEquivalent = "\r"
        box.addSubview(allow)

        win.contentView = box
        window = win
        win.orderFrontRegardless()
    }

    @objc private func allowIt() { let a = onAnswer; close(); a?(true) }
    @objc private func deny() { let a = onAnswer; close(); a?(false) }

    func close() {
        window?.orderOut(nil); window = nil; onAnswer = nil
    }
}
