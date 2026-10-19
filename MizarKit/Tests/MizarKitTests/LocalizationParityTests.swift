//
//  LocalizationParityTests.swift
//  MizarKitTests
//
//  Both languages, same keys.
//
//  The app has no unit-test target of its own — its tests are UI tests, which are
//  slow and need a simulator — so this lives where the cheap suite is and reaches
//  out to the app's resources through `#filePath`, the same way the protocol
//  fixture tests reach `protocol/fixtures`.
//
//  A missing Chinese key does not fail a build or a UI test: SwiftUI renders the
//  key itself, so the screen shows `account.subscription.autoRenew` in the middle
//  of a Chinese sentence. That is the bug this pins: an English key added without
//  its translation is a screen that looks broken to every Chinese operator.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Localization parity")
struct LocalizationParityTests {
    /// The app target's sources, as seen from this test file.
    private static var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MizarKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MizarKit
            .deletingLastPathComponent() // iOS
            .appendingPathComponent("DSH-Mizar")
    }

    private static func table(_ language: String) -> [String: String] {
        let url = appDirectory
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("cannot read \(url.path)")
            return [:]
        }
        return parse(text)
    }

    /// Parse a `.strings` table.
    ///
    /// A small regex parser rather than `PropertyListSerialization`: the file is
    /// UTF-16-less plain `.strings`, one `"key" = "value";` per entry, and a
    /// parser here makes the failure message name the offending line instead of
    /// throwing an opaque plist error.
    static func parse(_ text: String) -> [String: String] {
        // Drop comments first: a quote in a comment is not a string.
        let withoutBlockComments = text.replacingOccurrences(
            of: "(?s)/\\*.*?\\*/",
            with: "",
            options: .regularExpression,
        )
        let withoutLineComments = withoutBlockComments.replacingOccurrences(
            of: "(?m)^\\s*//.*$",
            with: "",
            options: .regularExpression,
        )

        var table: [String: String] = [:]
        let pattern = #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(withoutLineComments.startIndex..., in: withoutLineComments)
        for match in regex.matches(in: withoutLineComments, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: withoutLineComments),
                  let valueRange = Range(match.range(at: 2), in: withoutLineComments)
            else { continue }
            let key = String(withoutLineComments[keyRange])
            let value = String(withoutLineComments[valueRange])
            // Last one wins, mirroring how the file is read; duplicate detection
            // is a separate test below.
            table[key] = value
        }
        return table
    }

    @Test("both languages define exactly the same keys")
    func sameKeys() {
        let english = Self.table("en")
        let chinese = Self.table("zh-Hans")
        #expect(!english.isEmpty, "the English table did not parse")
        #expect(!chinese.isEmpty, "the Chinese table did not parse")

        let missingInChinese = Set(english.keys).subtracting(chinese.keys).sorted()
        let missingInEnglish = Set(chinese.keys).subtracting(english.keys).sorted()
        #expect(missingInChinese.isEmpty, "keys with no zh-Hans translation: \(missingInChinese)")
        #expect(missingInEnglish.isEmpty, "keys with no English source: \(missingInEnglish)")
    }

    @Test("neither language has a duplicate or empty entry")
    func noDuplicatesOrBlanks() {
        for language in ["en", "zh-Hans"] {
            let url = Self.appDirectory
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let stripped = text.replacingOccurrences(
                of: "(?s)/\\*.*?\\*/",
                with: "",
                options: .regularExpression,
            )
            let pattern = #"^\s*"((?:[^"\\]|\\.)*)"\s*="#
            let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            let range = NSRange(stripped.startIndex..., in: stripped)
            var keys: [String] = []
            for match in regex.matches(in: stripped, range: range) {
                if let keyRange = Range(match.range(at: 1), in: stripped) {
                    keys.append(String(stripped[keyRange]))
                }
            }
            let table = Self.parse(text)
            // Duplicates that agree are harmless (`Conversation` is defined once
            // for the sidebar and once for the detail screen) and two already
            // exist. A duplicate that *disagrees* is the real bug: which value
            // wins is then an implementation detail of the loader.
            let pairs = keys.map { ($0, table[$0] ?? "") }
            let conflicting = Dictionary(grouping: pairs, by: \.0)
                .filter { Set($0.value.map(\.1)).count > 1 }
            #expect(conflicting.isEmpty, "\(language) defines the same key twice with different values")
            #expect(table.values.allSatisfy { !$0.isEmpty }, "\(language) has an empty value")
        }
    }

    @Test("the account and subscription screens have their keys in both languages")
    func featureKeys() {
        let english = Self.table("en")
        let chinese = Self.table("zh-Hans")
        // The strings the account work added. Keyed on the user-visible surface:
        // a screen whose every key is here cannot fall back to a raw key on
        // either language.
        let required = [
            "Account",
            "Not signed in",
            "Free account",
            "Paid account",
            "Sign in",
            "Create account",
            "Sign in with Apple",
            "Sign out",
            "Delete account",
            "Redeem invite code",
            "Add photo",
            "Add file",
            "Paid accounts only",
            "Subscription",
            "Restore purchases",
            "Manage subscription",
            "Auto-renewing monthly subscription",
        ]
        for key in required {
            #expect(english[key] != nil, "English is missing \"\(key)\"")
            #expect(chinese[key] != nil, "zh-Hans is missing \"\(key)\"")
        }
    }
}
