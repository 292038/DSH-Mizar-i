import MizarKit
import SwiftUI

/// The connected computer's official wallets, never the phone's relay credits.
///
/// One page, always the same page. The wallet cards are drawn from the moment
/// the window opens -- a refresh moves only what is *inside* the amount column,
/// never the column itself -- because a panel that is 200 points tall while it
/// loads and 260 when it lands is a panel that jumps under the finger that just
/// tapped refresh. What the amount column holds is the state:
///
///   - a figure, once a balance has arrived;
///   - a placeholder of the figure's own size while one is being read;
///   - 未知 when there is nothing to read it from (no computer, no account, an
///     older plugin) -- the honest answer, and the one the layout has room for.
struct BalanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let controllerOverride: DeepSeekBalanceController?
    private let refreshOverride: (@MainActor () async -> Void)?
    /// The last balance that did arrive, for its currency layout only.
    ///
    /// The controller drops a balance the moment a new query starts -- an amount
    /// from the previous account must never be shown against the new one -- but
    /// the *rows* are not an amount: keeping them means a refresh redraws the
    /// same card instead of a differently-shaped one.
    @State private var lastKnown: DeepSeekBalance?

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
        .onChange(of: controller.state, initial: true) { _, state in
            // The rows outlive the amount: see `lastKnown`.
            if case .ready(let balance) = state { lastKnown = balance }
        }
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

            // Both cards, whatever the state: the finished page's shape is the
            // page. Only the amount column changes.
            let rows = walletRows
            walletSection("balance.paid", rows: rows.paid)
            if !rows.bonus.isEmpty {
                walletSection("balance.bonus", rows: rows.bonus)
            }

            // Said only when there is something to act on -- an old plugin, a
            // signed-out account, a query that failed. Offline is not one of
            // them: the amounts say 未知 and the connection is the footer's own
            // sentence, not this window's.
            if let note = statusNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.rise)
                    .accessibilityIdentifier("balance.status")
            }

            // Always offered, and always in the same place: a top-up is a trip
            // to DeepSeek's own page, which needs no balance to be read first.
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
        }
    }

    /// One wallet card: its title, then one row per currency.
    ///
    /// - Parameters:
    ///   - title: the card's heading.
    ///   - rows: the currencies to draw, with what each amount may say.
    private func walletSection(_ title: LocalizedStringKey, rows: [WalletSlot]) -> some View {
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
                        amount(row)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
    }

    /// What one row says about its amount.
    ///
    /// The three shapes share one column, so the card does not re-lay out when
    /// a figure arrives: a figure, a placeholder of the same height, or 未知.
    ///
    /// - Parameter row: the currency and its state.
    /// - Returns: the trailing half of the row.
    @ViewBuilder
    private func amount(_ row: WalletSlot) -> some View {
        switch row.amount {
        case .value(let value):
            Text(Self.displayAmount(value))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .contentTransition(.numericText())
                .accessibilityIdentifier("balance.amount.\(row.currency)")
        case .loading:
            AmountSkeleton()
                .accessibilityLabel(Text("balance.loading"))
                .accessibilityIdentifier("balance.loading.\(row.currency)")
        case .unknown:
            Text("Unknown")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("balance.unknown.\(row.currency)")
        }
    }

    /// The two cards' rows, and what each amount may say right now.
    private var walletRows: (paid: [WalletSlot], bonus: [WalletSlot]) {
        let state = controller.state
        let known: DeepSeekBalance? = if case .ready(let ready) = state { ready } else { lastKnown }
        // One row per card when nothing has ever been read: DeepSeek bills in
        // CNY, and a card with no rows is a card that looks broken.
        let paid = known?.wallets.map(\.currency) ?? ["CNY"]
        let bonus = known?.bonusWallets.map(\.currency) ?? ["CNY"]
        return (
            paid.map { slot(currency: $0, state: state, in: known?.wallets) },
            bonus.map { slot(currency: $0, state: state, in: known?.bonusWallets) },
        )
    }

    /// What one currency's amount may say, given the controller's state.
    ///
    /// - Parameters:
    ///   - currency: which wallet.
    ///   - state: what the controller is doing.
    ///   - rows: the wallets the last answer carried, when there were any.
    /// - Returns: the slot to draw.
    private func slot(
        currency: String,
        state: DeepSeekBalanceController.State,
        in rows: [DeepSeekWallet]?,
    ) -> WalletSlot {
        switch state {
        case .ready:
            let value = rows?.first { $0.currency == currency }?.balance
            return WalletSlot(currency: currency, amount: value.map { .value($0) } ?? .unknown)
        case .idle, .loading:
            // Idle is the moment between the window opening and the first query
            // leaving, which is a load from the operator's side.
            return WalletSlot(currency: currency, amount: .loading)
        default:
            return WalletSlot(currency: currency, amount: .unknown)
        }
    }

    /// What a card's amount column holds.
    private struct WalletSlot {
        let currency: String
        let amount: AmountSlot
    }

    /// The three things an amount column can say.
    private enum AmountSlot {
        case value(String)
        case loading
        case unknown
    }

    /// Why the amounts say nothing, when there is a reason worth acting on.
    private var statusNote: LocalizedStringKey? {
        switch controller.state {
        case .ready, .loading, .idle, .disconnected: nil
        case .unsupported: "balance.unsupported"
        case .signedOut: "balance.signed-out"
        case .unavailable: "balance.unavailable"
        case .failed: "balance.failed"
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

}

/// The amount column while a balance is being read.
///
/// A bar the width and height of a figure, breathing slowly: it says "a number
/// is coming and it goes here", which is the one thing a spinner in a table cell
/// does not. Under Reduce Motion it holds still rather than pulsing -- the shape
/// is the message, and the breath is only the reassurance.
private struct AmountSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(.fill.secondary)
            .frame(width: 64, height: 14)
            .opacity(reduceMotion ? 0.7 : 1)
            .phaseAnimator([false, true], content: { bar, dim in
                bar.opacity(dim && !reduceMotion ? 0.45 : 0.9)
            }, animation: { _ in
                .easeInOut(duration: 0.9)
            })
    }
}
