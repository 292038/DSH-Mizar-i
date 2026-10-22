import MizarKit
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import DSH_Mizar

/// Supplementary real production-view hosting, not a reconstructed layout or golden.
/// A non-AX-client hosted SwiftUI view does not reliably expose virtual AX children.
/// Exact per-control frames, hit targets, long-route compression, full amount labels
/// and absence of visual truncation therefore belong to the mock-paired XCUITest.
/// These tests prove only finite root fitting, real rendering and controller state;
/// attached images are evidence for inspection, not an automatic no-clipping claim.
@MainActor @Suite(.serialized)
struct BalanceLayoutSnapshotTests {
    @Test(arguments: [false, true])
    func actualSidebarRendersWithin320Root(_ accessibilitySize: Bool) async throws {
        let root = SidebarView()
            .environment(AppModel())
            .environment(ShellState())
            .environment(\.dynamicTypeSize, accessibilitySize ? .accessibility5 : .large)
        let hosted = try await BalanceGeometryHost(root: root, width: 320, height: 844)
        defer { hosted.close() }
        hosted.expectFiniteRoot(width: 320, height: 844)
        hosted.attachEvidence(name: "supplementary-sidebar-320-\(accessibilitySize ? "AX5" : "large")")
    }

    @Test(arguments: [false, true])
    func actualWalletPageRendersLongMulticurrencySnapshot(_ accessibilitySize: Bool) async throws {
        let amounts = ["12345678901234567890.000000000001", "0", "98765432109876543210.123456789012", "1.234567890123456789e-20"]
        let controller = DeepSeekBalanceController()
        try await prepare(controller, amounts: amounts)
        let root = BalanceView(controller: controller, refresh: {})
            .environment(AppModel())
            .environment(\.dynamicTypeSize, accessibilitySize ? .accessibility5 : .large)
        let hosted = try await BalanceGeometryHost(root: root, width: 320, height: 2400)
        defer { hosted.close() }
        hosted.expectFiniteRoot(width: 320, height: 2400)
        guard case .ready(let snapshot) = controller.state else {
            Issue.record("The no-network production page must retain its injected ready snapshot")
            return
        }
        #expect(snapshot.wallets.map(\.balance) == Array(amounts.prefix(2)))
        #expect(snapshot.bonusWallets.map(\.balance) == Array(amounts.suffix(2)))
        #expect(snapshot.wallets.map(\.currency) == ["CNY", "USD"])
        #expect(snapshot.bonusWallets.map(\.currency) == ["CNY", "USD"])
        hosted.attachEvidence(name: "supplementary-balance-320-\(accessibilitySize ? "AX5" : "large")")
    }

    @Test(arguments: [false, true])
    func actualHostedPageRespondsToUnsupportedAndFailedState(_ unsupported: Bool) async throws {
        let controller = DeepSeekBalanceController()
        try await prepare(controller, amounts: ["123.00001", "0", "5", "1e-9"])
        let hosted = try await BalanceGeometryHost(
            root: BalanceView(controller: controller, refresh: {}).environment(AppModel()),
            width: 320, height: 1200
        )
        defer { hosted.close() }
        guard case .ready = controller.state else {
            Issue.record("Fixture must start from ready, not merely render an empty state")
            return
        }
        controller.configure(
            tag: HostTag(hostId: "offline-layout", epoch: 2),
            readHost: { Self.hostInfo },
            readBalance: {
                if unsupported { return .unsupported }
                throw DeepSeekBalanceValidation.invalidResponse
            }
        )
        await controller.refresh()
        try await hosted.settle()
        #expect(controller.state == (unsupported ? .unsupported : .failed))
        hosted.expectFiniteRoot(width: 320, height: 1200)
        hosted.attachEvidence(name: "supplementary-balance-\(unsupported ? "unsupported" : "failed")")
        // Exact absence of amount/top-up AX nodes is checked in XCUITest, not
        // inferred from this controller-state assertion or from an empty AX tree.
    }

    private static var hostInfo: HostInfo {
        HostInfo(hostId: "offline-layout", hostName: "Offline fixture", home: "/fixture", protocolVersion: 1,
                 plugin: HostPlugin(id: "dsh-mizar", capabilities: ["deepseek.balance.v1"]))
    }

    private func prepare(_ controller: DeepSeekBalanceController, amounts: [String]) async throws {
        let json: [String: Any] = [
            "status": "ready",
            "wallets": [["currency": "CNY", "balance": amounts[0]], ["currency": "USD", "balance": amounts[1]]],
            "bonusWallets": [["currency": "CNY", "balance": amounts[2]], ["currency": "USD", "balance": amounts[3]]],
            "topUpURL": "https://platform.deepseek.com/top_up",
        ]
        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: JSONSerialization.data(withJSONObject: json))
        controller.configure(tag: HostTag(hostId: "offline-layout", epoch: 1), readHost: { Self.hostInfo }, readBalance: { response })
        await controller.refresh()
    }
}

@MainActor private final class BalanceGeometryHost {
    let window: UIWindow
    private let controller: UIViewController
    private let fitting: CGSize
    private let previousKeyWindow: UIWindow?

    init<V: View>(root: V, width: CGFloat, height: CGFloat) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let hosting = UIHostingController(rootView: root)
        fitting = hosting.sizeThatFits(in: CGSize(width: width, height: height))
        controller = hosting
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        try await settle()
    }

    func settle() async throws {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        controller.view.layoutIfNeeded()
    }

    func expectFiniteRoot(width: CGFloat, height: CGFloat) {
        #expect(fitting.width.isFinite && fitting.height.isFinite)
        #expect(fitting.width > 0 && fitting.height > 0)
        #expect(fitting.width <= width + 1)
        #expect(fitting.height <= height + 1)
        #expect(abs(controller.view.bounds.width - width) <= 1)
        #expect(abs(controller.view.bounds.height - height) <= 1)
        #expect(!window.isHidden)
        #expect(controller.view.window === window)
    }

    func attachEvidence(name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        #expect(image.size == window.bounds.size)
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}
