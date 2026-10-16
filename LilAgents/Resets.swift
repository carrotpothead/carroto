import AVFoundation
import AppKit

/// carroto's 30-second resets: small invitations between yoga breaks, done with him right there on the dock.
///
/// He sits on his stool and does it with you (Outfits/classic/far-carrot-01.mov, cactus-carrot-01.mov), talking you
/// through it (Outfits/resets/*.m4a) with his lines in his speech bubble. Off until you turn them on in the menu bar.
/// Same answers as the yoga break: let's go, in 10, not today. Never more often than every 20 minutes, and never
/// close to a yoga break (Colleague.resetTick).
enum Reset: String, CaseIterable {
    case eyes, shoulders

    /// the dock clip (one of WalkerCharacter's clips)
    var clip: String { self == .eyes ? "far" : "cactus" }
    var title: String { self == .eyes ? "look far away with me 👀" : "how are your shoulders?" }
    var detail: String {
        self == .eyes ? "20 seconds. find something far off, out a window if you can." : "30 seconds in your chair. a little cactus, a little neck."
    }
    var menuTitle: String { self == .eyes ? "Eyes Now (20 sec)" : "Shoulders Now (30 sec)" }
    /// what he says, as captions in his bubble: seconds from the moment he's sat down (his voice starts as he sits,
    /// 1.2s earlier), each just before he says it in Outfits/resets/*.m4a
    var lines: [(at: Double, text: String)] {
        switch self {
        case .eyes: return [(0.3, "now find something far away…"), (9.2, "let your eyes go soft."), (18.2, "lovely.")]
        case .shoulders: return [(0.2, "arms out like a little cactus… gently squeeze your shoulder blades together."),
                                 (7.8, "and soften…"), (13.7, "drop your left ear…"), (18.3, "let your shoulders melt down."),
                                 (21.2, "and the other side."), (24.8, "breathe out the day.")]
        }
    }

    // MARK: settings

    /// off by default: you turn them on in the menu bar
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "carrotoResets") }
        set { UserDefaults.standard.set(newValue, forKey: "carrotoResets") }
    }
    /// "not today" on a reset: no more resets until tomorrow (the yoga break still asks)
    static var declinedToday: Bool {
        get { UserDefaults.standard.string(forKey: "carrotoResetsDeclined") == today() }
        set { UserDefaults.standard.set(newValue ? today() : nil, forKey: "carrotoResetsDeclined") }
    }
    /// he talks you through it (on by default: you can't read his bubble while you're looking far away)
    static var withVoice: Bool {
        get { UserDefaults.standard.object(forKey: "carrotoResetsVoice") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "carrotoResetsVoice") }
    }
    /// his voice for it, timed from when he starts sitting down (Outfits/resets/eyes.m4a, shoulders.m4a)
    var voiceURL: URL? { Bundle.main.url(forResource: rawValue, withExtension: "m4a", subdirectory: "Outfits/resets") }
    private static var player: AVAudioPlayer?
    func speak() {
        guard Self.withVoice, let url = voiceURL else { return }
        Self.player = try? AVAudioPlayer(contentsOf: url)
        Self.player?.play()
    }

    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    static let firstAfterMinutes: Double = 20, gapMinutes: Double = 20, yogaClearanceMinutes: Double = 10

    /// the one he offers next (eyes first, then they take turns)
    static var next: Reset {
        get { Reset(rawValue: UserDefaults.standard.string(forKey: "carrotoResetNext") ?? "") ?? .eyes }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "carrotoResetNext") }
    }
    var following: Reset { self == .eyes ? .shoulders : .eyes }

    /// both clips are in this build
    static var isAvailable: Bool { allCases.allSatisfy { Outfit.url("\($0.clip)-carrot-01") != nil } }
}
