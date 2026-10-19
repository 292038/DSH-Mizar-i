//
//  Typewriter.swift
//  MizarKit
//
//  How a finished answer is typed onto the screen.
//
//  The host sends a turn's answer once, whole: the summary protocol deliberately
//  does not stream per-token updates to the phone. The desktop application does
//  show an answer arriving token by token while the model writes it, and a
//  summary that appears between one frame and the next reads as a screen that
//  refreshed rather than as a model that finished talking.
//
//  So this is the phone's stand-in for that arrival: a schedule that says which
//  character of a message is visible at a given moment. It is *not* an animation
//  curve and it never reads a clock -- a plan is built from a string, and the
//  reader asks it what is visible at some elapsed time. That keeps the pacing
//  testable without a screen, a display link or a wait.
//
//  The pacing is chosen to read as a fast model voice rather than as an effect
//  applied to text:
//
//    - a base rate near a fast token stream, fast enough that a paragraph does
//      not feel like a loading state;
//    - small, deterministic jitter per character so the rhythm is not the
//      metronome a fixed timer produces;
//    - a longer beat after sentence-ending punctuation and newlines, and a
//      shorter one after commas, which is where a model's tokens settle;
//    - a hard ceiling on the whole schedule, because an effect that outlasts the
//      answer by seconds is a worse reading experience than no effect at all.
//
//  The schedule is deterministic for one string: the same text always types the
//  same way, so a message redrawn after a scroll does not change its rhythm (and
//  tests can pin it).
//

import Foundation

/// When each character of a message becomes visible.
public struct TypewriterPlan: Sendable, Equatable {
    /// How many characters the message has.
    public let totalCharacters: Int
    /// How long the whole message takes to appear.
    public let duration: Duration
    /// When each character becomes visible, ascending, one entry per character.
    ///
    /// Stored rather than recomputed: the reader asks for a count on every frame
    /// of the reveal, and a binary search over a precomputed table is the
    /// cheapest honest answer. The last entry equals ``duration``.
    private let revealTimes: [Duration]

    /// How fast the voice types, in characters per second, before pauses.
    ///
    /// Fast on purpose. A model's own token stream is around forty tokens a
    /// second at full tilt, which for Chinese is a little over a hundred
    /// characters; a summarised answer replayed at that rate feels live. Much
    /// slower and the answer reads as a deliberate loading animation.
    public static let defaultCharactersPerSecond: Double = 180

    /// The longest a reveal may take, whatever the message length.
    ///
    /// Two seconds. Past that the operator is waiting for an effect instead of
    /// reading an answer, which is exactly the trade this feature is not worth
    /// making -- a long answer is one the reader can already start on.
    public static let defaultMaximumDuration: Duration = .seconds(2)

    /// The shortest reveal worth showing.
    ///
    /// A two-character answer that appears in six milliseconds is a flicker, and
    /// a flicker is the one thing worse than an instant answer. A tenth of a
    /// second still reads as "it landed" without being a wait.
    public static let defaultMinimumDuration: Duration = .seconds(0.1)

    /// Build the schedule for one message.
    ///
    /// - Parameters:
    ///   - text: the message's characters, in the order they appear on screen.
    ///   - charactersPerSecond: the base rate before punctuation pauses.
    ///   - maximumDuration: the ceiling for the whole schedule.
    ///   - minimumDuration: the floor for the whole schedule.
    public init(
        text: String,
        charactersPerSecond: Double = TypewriterPlan.defaultCharactersPerSecond,
        maximumDuration: Duration = TypewriterPlan.defaultMaximumDuration,
        minimumDuration: Duration = TypewriterPlan.defaultMinimumDuration,
    ) {
        let characters = Array(text)
        totalCharacters = characters.count

        guard !characters.isEmpty else {
            duration = .zero
            revealTimes = []
            return
        }

        // Seeded from the text so the plan is deterministic: one message always
        // types the same way, however many times the row is drawn.
        var random = SplitMix64(seed: Self.seed(for: characters))
        // The per-character jitter is ±22%: enough that the rhythm breathes,
        // small enough that it never reads as stutter.
        let weights = characters.map { character in
            Self.weight(of: character) * (0.78 + random.nextUnit() * 0.44)
        }
        let totalWeight = weights.reduce(0, +)
        let base = totalWeight / max(charactersPerSecond, 1)

        // Clamped twice: once to the operator's ceiling, once to the floor that
        // keeps a one-word answer from being a single-frame flash.
        let seconds = min(
            max(base, Self.seconds(minimumDuration)),
            Self.seconds(maximumDuration),
        )
        let unit = seconds / totalWeight

        var times: [Duration] = []
        times.reserveCapacity(characters.count)
        var elapsed = 0.0
        for weight in weights {
            elapsed += weight * unit
            times.append(.seconds(elapsed))
        }
        revealTimes = times
        duration = times.last ?? .zero
        // The last timestamp is the moment its character becomes visible; the
        // schedule is not over until the reveal is, which is that same moment.
    }

    /// How many characters are visible after some time has passed.
    ///
    /// - Parameter elapsed: time since the reveal began.
    /// - Returns: a count in `0...totalCharacters`, non-decreasing in `elapsed`.
    public func revealedCount(after elapsed: Duration) -> Int {
        guard totalCharacters > 0, elapsed > .zero else { return 0 }
        guard elapsed < duration else { return totalCharacters }
        // Number of reveal times at or before `elapsed`. The table is ascending,
        // so this is a binary search rather than a scan: it runs on every frame.
        var low = 0
        var high = revealTimes.count
        while low < high {
            let middle = (low + high) / 2
            if revealTimes[middle] <= elapsed {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// How many characters are visible after some number of seconds.
    ///
    /// The seconds form of ``revealedCount(after:)`` for callers that hold a
    /// `TimeInterval` rather than a `Duration`.
    ///
    /// - Parameter seconds: time since the reveal began.
    /// - Returns: a count in `0...totalCharacters`.
    public func revealedCount(after seconds: TimeInterval) -> Int {
        revealedCount(after: .seconds(seconds))
    }

    /// Whether the reveal is over.
    ///
    /// - Parameter elapsed: time since the reveal began.
    /// - Returns: whether every character is visible.
    public func isFinished(after elapsed: Duration) -> Bool {
        totalCharacters == 0 || elapsed >= duration
    }

    /// The time a character becomes visible, for tests and for the schedule's
    /// own documentation.
    ///
    /// - Parameter index: a zero-based character index.
    /// - Returns: when that character appears, or `nil` outside the message.
    public func revealTime(ofCharacterAt index: Int) -> Duration? {
        guard index >= 0, index < revealTimes.count else { return nil }
        return revealTimes[index]
    }

    // MARK: - Pacing

    /// How long one character is worth relative to the base rate.
    ///
    /// Not an easing curve: a model's stream has a rhythm of its own, and the
    /// rhythm is in where the tokens settle. A full stop is a breath; a comma is
    /// half of one; a space is quick because it costs no reading.
    ///
    /// - Parameter character: the character about to appear.
    /// - Returns: a weight, `1.0` for ordinary text.
    private static func weight(of character: Character) -> Double {
        switch character {
        case "\n":
            3.6
        case "。", "！", "？", "…":
            3.2
        case "，", "、", "；", "：":
            2.4
        case ".", "!", "?":
            2.8
        case ";", ":":
            2.2
        case ",":
            1.9
        case " ":
            0.55
        default:
            1
        }
    }

    /// The seed for one message's jitter.
    ///
    /// FNV-1a over the message's Unicode scalars. Any deterministic hash works;
    /// this one is short, stable across processes, and needs no import.
    ///
    /// - Parameter characters: the message.
    /// - Returns: the seed.
    private static func seed(for characters: [Character]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for character in characters {
            for scalar in character.unicodeScalars {
                hash ^= UInt64(scalar.value)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }

    /// A duration as `TimeInterval`.
    ///
    /// - Parameter duration: the duration.
    /// - Returns: the same value in seconds.
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The small deterministic random source the plan's jitter needs.
///
/// SplitMix64: four lines, no dependency, and a fixed algorithm rather than the
/// system generator so a plan is the same in a test and on a phone.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The next 64 random bits.
    /// - Returns: a value.
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A value in `[0, 1)`.
    /// - Returns: the value.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
