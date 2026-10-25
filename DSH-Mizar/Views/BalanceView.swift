import MizarKit
import SwiftUI

/// The connected computer's official wallets, never the phone's relay credits.
struct BalanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    private var refreshDisabled: Bool {
        (controllerOverride == nil && model.balanceConnectionTag == nil) || controller.state == .loading
    }

    private func refresh() async {
        if let refreshOverride { await refreshOverride() }
        else { await model.refreshDeepSeekBalance() }
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            if dynamicTypeSize.isAccessibilitySize {
                // Keep the window compact without clipping enlarged text or the
                // top-up action. The header and its controls stay in place.
                ScrollView { detail }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: 260)
            } else {
                detail
            }
        }
        .padding(18)
        .frame(width: PopoverSize.compact.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("balance.panel")
        .task(id: model.balanceConnectionTag) { await refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("balance.title")
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.fill.tertiary, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(refreshDisabled)
            .accessibilityLabel(Text("balance.refresh"))
            .accessibilityIdentifier("balance.refresh")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.fill.tertiary, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Done"))
            .accessibilityIdentifier("balance.done")
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("balance.explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch controller.state {
            case .ready(let balance):
                walletSection("balance.paid", rows: balance.wallets)
                if !balance.bonusWallets.isEmpty {
                    walletSection("balance.bonus", rows: balance.bonusWallets)
                }
                Button {
                    // Only this explicit user action opens the fixed official page.
                    openURL(DeepSeekBalance.topUpURL)
                } label: {
                    Label("balance.top-up", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("balance.topUp")
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("balance.loading")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("balance.status")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            default:
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("balance.status")
            }
        }
    }

    private func walletSection(_ title: LocalizedStringKey, rows: [DeepSeekWallet]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.currency) { index, row in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 14)
                    }
                    LabeledContent(row.currency) {
                        Text(Self.displayAmount(row.balance))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("balance.amount.\(row.currency)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
    }

    /// Display-only rounding. MizarKit retains the host's exact decimal string;
    /// Decimal avoids the precision loss and scientific-notation drift of Double.
    static func displayAmount(_ value: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        guard var amount = Decimal(string: value, locale: locale), !amount.isNaN else { return "—" }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &amount, 2, .plain)
        guard !rounded.isNaN else { return "—" }
        let parts = NSDecimalString(&rounded, locale).split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? "0"
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        return "\(whole).\(String((fraction + "00").prefix(2)))"
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
