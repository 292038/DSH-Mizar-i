import MizarKit
import SwiftUI

/// The connected computer's official wallets, never the phone's relay credits.
struct BalanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let controllerOverride: DeepSeekBalanceController?
    private let refreshOverride: (@MainActor () async -> Void)?

    /// Internal offline-hosting seam. Default construction uses the live model unchanged.
    init(
        controller: DeepSeekBalanceController? = nil,
        refresh: (@MainActor () async -> Void)? = nil
    ) {
        controllerOverride = controller
        refreshOverride = refresh
    }

    private var controller: DeepSeekBalanceController { controllerOverride ?? model.deepSeekBalance }
    private func refresh() async {
        if let refreshOverride { await refreshOverride() }
        else { await model.refreshDeepSeekBalance() }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("balance.explanation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                switch controller.state {
                case .ready(let balance):
                    Section("balance.paid") { wallets(balance.wallets) }
                    if !balance.bonusWallets.isEmpty {
                        Section("balance.bonus") { wallets(balance.bonusWallets) }
                    }
                    Section {
                        Button {
                            // Only this explicit user action opens the fixed official page.
                            openURL(DeepSeekBalance.topUpURL)
                        } label: {
                            Label("balance.top-up", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityIdentifier("balance.topUp")
                        Text("balance.top-up-note")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .loading:
                    ProgressView("balance.loading")
                        .accessibilityIdentifier("balance.status")
                default:
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("balance.status")
                }
                Section {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("balance.refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled((controllerOverride == nil && model.balanceConnectionTag == nil) || controller.state == .loading)
                    .accessibilityIdentifier("balance.refresh")
                }
            }
            .navigationTitle("balance.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("balance.done")
                }
            }
            .refreshable { await refresh() }
            .task(id: model.balanceConnectionTag) { await refresh() }
        }
    }

    private func wallets(_ rows: [DeepSeekWallet]) -> some View {
        ForEach(rows, id: \.currency) { row in
            LabeledContent(row.currency) {
                Text(row.balance)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("balance.amount.\(row.currency)")
            }
        }
    }

    private var statusMessage: LocalizedStringKey {
        switch controller.state {
        case .disconnected: "balance.disconnected"
        case .idle: "balance.loading"
        case .unsupported: "balance.unsupported"
        case .signedOut: "balance.signed-out"
        case .unavailable: "balance.unavailable"
        case .failed: "balance.failed"
        case .loading: "balance.loading"
        case .ready: "balance.title"
        }
    }
}
