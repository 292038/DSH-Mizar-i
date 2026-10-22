import SwiftUI
import Testing
import UIKit
import XCTest
import MizarKit
@testable import DSH_Mizar

/// Supplementary overall geometry and screenshots of the production leaf.
/// Element roles, 44pt hit targets, individual frames, labels and hittability
/// belong to the real mock-host XCUI coverage: a non-AX-client hosted process
/// cannot reliably enumerate SwiftUI's virtual accessibility tree. These tests
/// deliberately do not claim that fitting the root proves its children fit.
@Suite(.serialized)
@MainActor
struct TurnResponseToolbarLayoutTests {
    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func narrowToolbarHasFiniteHostedExtent(_ size: DynamicTypeSize) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now).addingTimeInterval(60)
        let year = calendar.component(.year, from: now)
        let sameYear = try #require(calendar.date(from: DateComponents(year: year, month: 1, day: 1, hour: 23, minute: 59)))
        let previousYear = try #require(calendar.date(from: DateComponents(year: year - 1, month: 12, day: 31, hour: 23, minute: 59)))
        for date in [today, sameYear, previousYear] {
            let turn = ConversationTurn(turn: 1, prompts: [], steps: [], startedAt: date, endedAt: date,
                                        endedReason: "completed", lastTurn: 1, endSeq: 100,
                                        tokenUsage: TurnTokenUsage(totalTokens: 9_007_199_254_740_991), branchUnavailable: false)
            let model = AppModel(conversations: InMemoryConversationCache())
            let controller = UIHostingController(rootView:
                TurnResponseToolbar(turn: turn, sessionId: "layout-only", text: "The full original response", at: date)
                    .environment(model)
                    .environment(\.dynamicTypeSize, size)
                    .padding(.horizontal, 16)
            )
            let proposed = CGSize(width: 320, height: 10_000)
            let fitting = controller.sizeThatFits(in: proposed)
            #expect(fitting.width.isFinite && fitting.height.isFinite)
            #expect(fitting.width > 0 && fitting.width <= 320)
            #expect(fitting.height >= 44, "A root smaller than its mandatory action height is not a valid toolbar extent")
            #expect(fitting.height < proposed.height, "A finite toolbar must not consume the unbounded measurement proposal")
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: max(200, fitting.height + 100))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(250))
            controller.view.layoutIfNeeded()
            #expect(controller.view.bounds.width == 320)
            #expect(controller.view.bounds.height >= fitting.height)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            #expect(image.size.width == 320)
            #expect(image.size.height >= fitting.height)
            XCTContext.runActivity(named: "Supplementary production toolbar 320pt \(size) \(date.timeIntervalSince1970)") { activity in
                let attachment = XCTAttachment(image: image)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
    }
}
