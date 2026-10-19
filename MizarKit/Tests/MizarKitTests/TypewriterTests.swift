//
//  TypewriterTests.swift
//  MizarKitTests
//
//  The schedule behind the answer being typed onto the screen.
//
//  The host sends a finished answer whole; the desktop shows it arriving token
//  by token. This schedule is the phone's stand-in, and it has to be quick,
//  even, and deterministic -- an effect that stutters, races, or types the same
//  message differently on every redraw is worse than no effect. These tests pin
//  the pacing rather than a screenshot: they ask the plan what is visible at
//  chosen instants, the way the view does on every frame.
//

import Foundation
import Testing

@testable import MizarKit

struct TypewriterTests {
    /// A message long enough to use the interesting parts of the schedule.
    private let prose = "重建完成，接下来要跑一遍完整测试。先确认缓存命中的统计没有回归，再把分页的边界用例补上。"

    @Test("nothing is visible at the first instant")
    func startsEmpty() {
        let plan = TypewriterPlan(text: prose)
        #expect(plan.totalCharacters == prose.count)
        #expect(plan.revealedCount(after: .zero) == 0)
        #expect(plan.revealedCount(after: -0.5) == 0)
        #expect(!plan.isFinished(after: .zero))
    }

    @Test("everything is visible when the schedule ends")
    func endsFull() {
        let plan = TypewriterPlan(text: prose)
        #expect(plan.revealedCount(after: plan.duration) == plan.totalCharacters)
        #expect(plan.isFinished(after: plan.duration))
        #expect(plan.revealedCount(after: plan.duration + .seconds(1)) == plan.totalCharacters)
    }

    @Test("a finished reveal stays finished")
    func neverGoesBackwards() {
        let plan = TypewriterPlan(text: prose)
        var last = 0
        for step in 0...40 {
            let count = plan.revealedCount(after: Duration.seconds(plan.seconds * Double(step) / 40))
            #expect(count >= last, "the reveal went backwards at step \(step)")
            #expect(count <= plan.totalCharacters)
            last = count
        }
    }

    @Test("an ordinary answer reveals in a fraction of a second")
    func fastForOrdinaryAnswers() {
        // The whole point of the feature is that it reads as a live voice: a
        // summary that takes longer than a couple of seconds is a loading state.
        let plan = TypewriterPlan(text: prose)
        #expect(plan.duration >= .seconds(0.1))
        #expect(plan.duration <= .seconds(2.01))
        let short = TypewriterPlan(text: "好的")
        #expect(short.duration >= .seconds(0.1))
        #expect(short.duration <= .seconds(0.5))
    }

    @Test("a long answer is capped rather than typed for longer")
    func longAnswerIsCapped() {
        let long = String(repeating: "这是一段很长的回答。", count: 400)
        let plan = TypewriterPlan(text: long)
        #expect(plan.duration <= .seconds(2.01))
        // The cap compresses the schedule; it does not truncate the message.
        #expect(plan.revealedCount(after: plan.duration) == long.count)
    }

    @Test("a single character still gets a beat")
    func tinyMessageIsNotAFlicker() {
        let plan = TypewriterPlan(text: "好")
        #expect(plan.totalCharacters == 1)
        #expect(plan.duration >= .seconds(0.09))
        #expect(plan.revealedCount(after: plan.duration) == 1)
    }

    @Test("an empty message is finished before it starts")
    func emptyIsInstant() {
        let plan = TypewriterPlan(text: "")
        #expect(plan.totalCharacters == 0)
        #expect(plan.duration == .zero)
        #expect(plan.revealedCount(after: .zero) == 0)
        #expect(plan.isFinished(after: .zero))
    }

    @Test("the same message always types the same way")
    func deterministic() {
        let first = TypewriterPlan(text: prose)
        let second = TypewriterPlan(text: prose)
        #expect(first.duration == second.duration)
        for step in 0...20 {
            let elapsed = Duration.seconds(first.seconds * Double(step) / 20)
            #expect(first.revealedCount(after: elapsed) == second.revealedCount(after: elapsed))
        }
    }

    @Test("a full stop is a pause, not a character like any other")
    func punctuationHoldsTheRhythm() {
        // Compare the gap before a full stop with the ordinary gap before an
        // unpunctuated character. The stop should be visibly longer -- that
        // pause is what makes the typing read as a voice rather than a timer.
        // The gap before a character is the weight of the character before it:
        // a reveal time is the sum up to and including its own character. So
        // compare the beat the full stop adds (the gap between 下 and 。) with
        // the same gap in the unpunctuated sentence (下 then 再).
        let full = TypewriterPlan(text: "先停一下。再继续")
        let stop = try! #require(full.revealTime(ofCharacterAt: 4))
        let beforeStop = try! #require(full.revealTime(ofCharacterAt: 3))
        let stopGap = stop - beforeStop

        let plain = TypewriterPlan(text: "先停一下再继续")
        let ordinary = try! #require(plain.revealTime(ofCharacterAt: 4))
        let beforeOrdinary = try! #require(plain.revealTime(ofCharacterAt: 3))
        let ordinaryGap = ordinary - beforeOrdinary

        #expect(stopGap > ordinaryGap)
        #expect(stopGap >= ordinaryGap * 2)
    }

    @Test("a newline is a longer pause than a comma")
    func newlineHoldsLongerThanComma() {
        let comma = TypewriterPlan(text: "一，二")
        let commaGap = try! #require(comma.revealTime(ofCharacterAt: 1)) - (comma.revealTime(ofCharacterAt: 0) ?? .zero)
        let newline = TypewriterPlan(text: "一\n二")
        let newlineGap = try! #require(newline.revealTime(ofCharacterAt: 1)) - (newline.revealTime(ofCharacterAt: 0) ?? .zero)
        #expect(newlineGap > commaGap)
    }

    @Test("a reveal time exists for every character and nowhere else")
    func revealTimesCoverTheMessage() {
        let plan = TypewriterPlan(text: "abc")
        #expect(plan.revealTime(ofCharacterAt: 0) != nil)
        #expect(plan.revealTime(ofCharacterAt: 2) != nil)
        #expect(plan.revealTime(ofCharacterAt: 3) == nil)
        #expect(plan.revealTime(ofCharacterAt: -1) == nil)
        #expect(plan.revealTime(ofCharacterAt: 2) == plan.duration)
    }
}

private extension TypewriterPlan {
    /// The duration as seconds, for tests that want to sample it.
    var seconds: Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
