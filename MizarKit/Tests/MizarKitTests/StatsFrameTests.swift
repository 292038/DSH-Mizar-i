//
//  StatsFrameTests.swift
//  MizarKitTests
//
//  A usage frame that carries less than the last one.
//
//  The host reads each field from its own projection, and a projection answers
//  with what it has right now: a session whose agent is cold has no model
//  selection and no context pressure, and a title only exists once a model has
//  read the conversation. So "this reply has fewer fields than the last one" is
//  the ordinary case, not a failure.
//
//  Reported from the phone as the figures *vanishing* on the way into a session
//  — "刚点进去一个会话，然后该会话的标题、正在使用的模型、上下文用量显示全部消失"
//  — because the stored frame drew them and the host's answer replaced it a
//  moment later. These are the rules that stop that.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Usage frames")
struct StatsFrameTests {
    private let usage = TokenUsage(
        uncachedInputTokens: 10,
        outputTokens: 20,
        cacheReadTokens: 30,
        cacheWriteTokens: 40,
        billedInputTokens: 80,
    )

    private let pressure = ContextPressure(
        window: 128_000,
        pressureTokens: 44_800,
        projectedTokens: 44_800,
        percent: 35,
        breakdown: nil,
    )

    private let selection = ModelSelectionPair(
        lastUsed: ModelSelection(provider: "deepseek-official", model: "deepseek-flash", reasoningEffort: "high"),
        next: nil,
    )

    @Test("a reply that carries less keeps what the last one had")
    func mergeKeepsWhatIsMissing() {
        // The exact shape of the report: a cold session answers with the token
        // meter and nothing else, because the other three projections have
        // nothing to say until the agent has run.
        let known = SessionStatsFrame(
            tokenUsage: usage,
            context: pressure,
            model: selection,
            title: "Refactor the parser",
        )
        let cold = SessionStatsFrame(tokenUsage: usage)

        let merged = cold.merging(known)
        #expect(merged.title == "Refactor the parser")
        #expect(merged.model?.lastUsed?.model == "deepseek-flash")
        #expect(merged.context?.percent == 35)
        #expect(merged.tokenUsage == usage)
    }

    @Test("a reply that carries more wins")
    func mergePrefersTheNewerField() {
        // Merging is not "keep the old": a field the host did answer with is the
        // current one, and holding a stale context figure would trade one wrong
        // screen for another.
        let known = SessionStatsFrame(context: pressure, model: selection, title: "Old")
        let fresh = SessionStatsFrame(
            context: ContextPressure(
                window: 128_000,
                pressureTokens: 64_000,
                projectedTokens: 64_000,
                percent: 50,
                breakdown: nil,
            ),
            title: "New",
        )

        let merged = fresh.merging(known)
        #expect(merged.title == "New")
        #expect(merged.context?.percent == 50)
        // And what the newer frame did not mention is still there.
        #expect(merged.model?.lastUsed?.model == "deepseek-flash")
    }

    @Test("an empty name is not a name")
    func mergeIgnoresAnEmptyName() {
        // A projection being worked out answers with an empty string rather than
        // nothing, and an empty title blanks the navigation bar -- the same loss
        // as a missing one, arriving by a different route.
        let known = SessionStatsFrame(permissionPreset: "workspace-write", title: "Refactor the parser")
        let stillWorking = SessionStatsFrame(permissionPreset: "", title: "")

        let merged = stillWorking.merging(known)
        #expect(merged.title == "Refactor the parser")
        #expect(merged.permissionPreset == "workspace-write")
    }

    @Test("nothing to merge into is not a problem")
    func mergeWithoutHistory() {
        let only = SessionStatsFrame(title: "First")
        #expect(only.merging(nil) == only)
        #expect(only.merging(SessionStatsFrame()) == only)
        // An empty frame adds nothing to a real one either.
        #expect(SessionStatsFrame().merging(only) == only)
    }

    @Test("an empty frame says so")
    func emptyFrameIsEmpty() {
        // What a session nobody has run answers with, and the reason the screen
        // asks again rather than settling on it.
        #expect(SessionStatsFrame().isEmpty)
        #expect(!SessionStatsFrame(title: "Named").isEmpty)
        #expect(!SessionStatsFrame(tokenUsage: usage).isEmpty)
    }

    @Test("a frame survives the cache it is written to")
    func frameSurvivesTheCache() throws {
        // The merge is worthless if the merged frame cannot be stored and read
        // back: this is what the screen draws before the network answers.
        let frame = SessionStatsFrame(
            tokenUsage: usage,
            cacheHit: CacheHit(ratio: 0.75, displayPercent: "75.0%"),
            context: pressure,
            stats: Throughput(turns: 3, steps: 9, llmMs: 1200, toolMs: 300, ttftMs: 400, decodeTokensPerSecond: 30),
            model: selection,
            permissionPreset: "workspace-write",
            title: "Refactor the parser",
        )
        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(SessionStatsFrame.self, from: encoded)
        #expect(decoded == frame)
    }
}
