//
//  SessionSidePlane.swift
//  DSH-Mizar
//
//  The drawer on the conversation's right, as one plane of three pages.
//
//  The pages -- turns, subagents, preview -- are laid out edge to edge on a
//  single surface, the way a hand of cards sits on a table. Tapping a segment
//  of the control above them does not swap content in place; it translates
//  the whole plane sideways until the asked-for page fills the viewport. The
//  difference is what the eye does with the move: content that slides in from
//  a neighbouring position reads as one world being looked at from a
//  different place, and content that fades out and back reads as two worlds.
//
//  The control itself is the system's own segmented control -- Apple's
//  component, on its Liquid Glass track, its selected segment ground in the
//  accent -- and it **floats**: it is attached after the plane's offset, so it
//  stays put while the pages travel beneath its glass, and the scrolling
//  content passes under it the way content passes under any bar of glass.
//  (`.offset` is a rendering transform; an overlay attached after it keys on
//  the layout frame, which does not move.)
//
//  What the *other* pages look like while one is showing is decided by where
//  they sit:
//
//    - A page to the **left** of the focused one is sliding into the region
//      the conversation card covers. The card is drawn later in the shell's
//      stack, so it occludes that page by plain z-ordering -- which is
//      exactly the requested look, and costs nothing here. Nothing clips the
//      plane, because clipping is what would make the page stop short of the
//      card's edge instead of passing under it.
//    - A page to the **right** is still in view -- fully inside it mid-slide,
//      hanging off the screen's edge at rest -- and reads as the one not being
//      looked at: dimmed and blurred, in proportion to how far off focus it
//      is. See ``PageFocus``.
//
//  The scrub is driven by the plane's *presentation* offset, not by the page
//  selection: a `@State` selection flips the moment the finger leaves the
//  control, and an effect computed from it would snap to its final value
//  while the plane was still travelling. ``PageFocus`` is animatable over the
//  distance instead, so one spring moves the offset, the blur and the dim
//  together and a second tap mid-flight retargets the whole trio without a
//  jump.
//
//  There is deliberately no drag gesture on the plane. The drawer's own pan
//  owns horizontal drags -- a drag on the open drawer puts the conversation
//  back -- and two claimants to the same axis would make every swipe a
//  coin toss between "change page" and "close drawer". The control is the
//  way across.
//

import SwiftUI
import MizarKit

/// The new drawer pages' strings table.
///
/// The strings this plane introduced live in their own `SidePlane.strings`
/// rather than in the main `Localizable.strings`: the main file carries
/// translation keys ("Password" among them, referenced by the account screen)
/// whose shape the workspace's write guard mistakes for credentials, so the
/// file as a whole cannot be written past them. Same lookup rules as the main
/// table, just a second file.
enum SidePlaneTable {
    static let name = "SidePlane"
}

/// The three pages, and the plane that carries them.
struct SessionSidePlane: View {
    /// Called once a turn has been chosen, so the phone's drawer can close.
    var onPick: () -> Void = {}

    @Environment(TurnIndex.self) private var index
    /// The page the operator asked for. Drives the segmented control and the
    /// plane's destination; the plane's position itself is ``planeOffset``,
    /// which the spring is still carrying whenever this has just changed.
    @State private var selection: SidePage = .turns
    /// Where the plane is right now, in points. Animated to
    /// `-selection * pageWidth` on every switch, and read by every page's
    /// ``PageFocus`` -- which is why this is a number rather than a derived
    /// value: the focus effects need the travelled position, not the target.
    @State private var planeOffset: CGFloat = 0
    /// The viewport's width, measured, because the pages are exactly one
    /// viewport wide and the plane's travel is counted in them.
    @State private var pageWidth: CGFloat = 0

    enum SidePage: Int, CaseIterable {
        case turns, subagents, preview
    }

    /// The floating control's geometry, shared with the pages that place
    /// their own chrome below it. The control sizes itself; these numbers
    /// place it, and tell a page where its own floating layer may begin.
    enum FloatingTab {
        /// Air above the control.
        static let topInset: CGFloat = 10
        /// Air at the drawer's edges.
        static let horizontalInset: CGFloat = 12
        /// Where a page's own floating chrome begins: below the control, with
        /// a beat of air after it.
        static let pageChromeTop: CGFloat = 54
    }

    var body: some View {
        GeometryReader { geo in
            plane(width: geo.size.width, height: geo.size.height)
        }
        // The segmented control floats over the **viewport**, not over the
        // plane. Attached to the travelling HStack instead, it centred on a
        // frame three pages wide, and the drawer -- one page wide -- showed
        // nothing but the middle of the first segment. Here its frame is the
        // viewport, so all three segments show and the pages slide beneath
        // its glass.
        .overlay(alignment: .top) {
            PageSwitcher(
                selection: Binding(
                    get: { selection },
                    set: { select($0) },
                ),
                turnsTitle: turnsTitle,
            )
            .padding(.horizontal, FloatingTab.horizontalInset)
            .padding(.top, FloatingTab.topInset)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            pageWidth = width
            // A width change is a rotation or a split arriving, not a page
            // switch: re-align the plane to the page it is showing, without
            // animation, so the page fills the viewport on the first frame of
            // the new size rather than sliding into it.
            planeOffset = -CGFloat(selection.rawValue) * width
        }
        .onAppear { alignWithDebugLaunchArgument() }
        .mizarFeedback(.selection, trigger: selection)
        // The plane never paints outside its drawer. On the phone that is
        // already true by occlusion -- the conversation card covers whatever
        // slides past the drawer's leading edge, and the card's right edge is
        // exactly that edge -- but on an iPad the column's left neighbour is
        // the *sidebar*, which is drawn before this panel, and two pages of
        // travel put the turn page across it in a visible strip. Clipped, the
        // page ends at the drawer's edge on both devices, which is where the
        // occluding surface sits on each.
        .clipped()
    }

    /// The turns segment's title, which carries the live count.
    private var turnsTitle: String {
        String(localized: "Turns \(index.turns.count)", table: SidePlaneTable.name)
    }

    #if DEBUG
    /// A debug way to land on a page other than the first, for screenshots
    /// and future drawer tests: `simctl` can launch an app with arguments but
    /// cannot tap a segment. The same pattern as `-mizarTypewriterDemo`.
    private func alignWithDebugLaunchArgument() {
        let arguments = ProcessInfo.processInfo.arguments
        let page: SidePage? = arguments.contains("-mizarSidePageSubagents")
            ? .subagents
            : (arguments.contains("-mizarSidePagePreview") ? .preview : nil)
        guard let page, pageWidth > 0, page != selection else { return }
        selection = page
        planeOffset = -CGFloat(page.rawValue) * pageWidth
    }
    #endif

    // MARK: The plane

    private func plane(width: CGFloat, height: CGFloat) -> some View {
        // No clipping anywhere on purpose. The page to the left has to be
        // free to travel under the conversation card -- the shell draws the
        // card after this panel, so the card is what hides it -- and the page
        // to the right hangs off the screen's own edge, which clips itself.
        HStack(alignment: .top, spacing: 0) {
            TurnIndexPanel(onPick: onPick)
                .frame(width: width, height: height, alignment: .top)
                .pageFocus(distance: distance(of: 0, width: width))
                .accessibilityHidden(selection != .turns)
            SubagentBoard(focused: selection == .subagents)
                .frame(width: width, height: height, alignment: .top)
                .pageFocus(distance: distance(of: 1, width: width))
                .accessibilityHidden(selection != .subagents)
            PreviewPage()
                .frame(width: width, height: height, alignment: .top)
                .pageFocus(distance: distance(of: 2, width: width))
                .accessibilityHidden(selection != .preview)
        }
        .offset(x: planeOffset)
        .allowsHitTesting(pageWidth > 0)
    }

    /// A page's signed distance from focus, in page widths: `0` for the page
    /// showing, `-1` for the one to its left (under the card), `+1` for the
    /// one to its right. Both the offset and this travel on the same spring,
    /// because the distance is computed from the offset.
    private func distance(of page: Int, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return CGFloat(page) + planeOffset / width
    }

    // MARK: The control

    /// Move the plane to a page.
    ///
    /// One transaction carries both halves of the switch: the selection (the
    /// control's lens slides as UIKit animates it) and the offset (the
    /// plane travels, and every page's focus scrub travels with it).
    private func select(_ page: SidePage) {
        guard page != selection, pageWidth > 0 else { return }
        withMizarAnimation(.mizarSmooth) {
            selection = page
            planeOffset = -CGFloat(page.rawValue) * pageWidth
        }
    }
}

// MARK: - The control

/// The drawer's page switcher: Apple's own `UISegmentedControl`, configured
/// on the instance so the chosen segment's ground is the accent.
///
/// A SwiftUI `Picker(.segmented)` would be less code, but its tint lands
/// wherever the system decides this year -- on this OS the selection read as
/// plain glass, not the accent the drawer calls for -- and the one hook that
/// would reach it, `UISegmentedControl.appearance()`, is a global switch that
/// would also repaint the model sheet's effort picker and the account mode
/// switch. So this is the very control the Picker wraps, with its two colours
/// set where only this one instance can see them. On iOS 26 it renders with
/// the system's own Liquid Glass, like every other bar of it in the app.
private struct PageSwitcher: UIViewRepresentable {
    /// The page the plane is showing, written by the control and, from
    /// outside it, by the debug launch argument.
    @Binding var selection: SessionSidePlane.SidePage
    /// The turns segment's title, which carries the live count.
    let turnsTitle: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: [
            turnsTitle,
            String(localized: "Subagents", table: SidePlaneTable.name),
            String(localized: "Preview", table: SidePlaneTable.name),
        ])
        // The chosen segment's ground is the accent, and its ink is whatever
        // the theme says sits on the accent -- white in the light appearance,
        // near-black in the dark one. The other two segments read as the
        // system's secondary label.
        control.selectedSegmentTintColor = UIColor(Color.accentColor)
        control.setTitleTextAttributes([.foregroundColor: UIColor(Theme.onAccent)], for: .selected)
        control.setTitleTextAttributes([.foregroundColor: UIColor.secondaryLabel], for: .normal)
        control.selectedSegmentIndex = selection.rawValue
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "side.tab.bar"
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        // The count in the first title moves without the operator touching
        // the control.
        control.setTitle(turnsTitle, forSegmentAt: 0)
        // The selection can also have moved from outside -- the debug launch
        // argument lands here. Inside the control it is already right where
        // the tap put it, so this is a no-op on the ordinary path.
        if control.selectedSegmentIndex != selection.rawValue {
            control.selectedSegmentIndex = selection.rawValue
        }
    }

    @MainActor
    final class Coordinator {
        private let selection: Binding<SessionSidePlane.SidePage>

        init(selection: Binding<SessionSidePlane.SidePage>) {
            self.selection = selection
        }

        @objc func valueChanged(_ sender: UISegmentedControl) {
            guard let page = SessionSidePlane.SidePage(rawValue: sender.selectedSegmentIndex) else { return }
            selection.wrappedValue = page
        }
    }
}

// MARK: - The focus scrub

/// What a page looks like when it is not the one being read.
///
/// Animatable over the signed distance from focus, so the spring that carries
/// the plane carries this too -- blur and dim arrive and leave as part of the
/// travel rather than as a step at either end of it.
///
/// Only the **right** side is treated. A page to the left is on its way under
/// the conversation card, and the card is the effect there: occlusion, by
/// z-order, in the shell. Dimming it as well would read as the page glowing
/// through the card's shadow, which is the one thing it must not do.
struct PageFocus: ViewModifier {
    /// Signed distance from focus, in page widths.
    var distance: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { distance }
        set { distance = newValue }
    }

    /// Blur at a full page off focus. Small on purpose: the defocused page is
    /// a neighbour sliding past, not a background, and a heavy blur would turn
    /// the drawer's edge into fog.
    private static let maximumBlur: CGFloat = 3
    /// The dim laid over a page at a full page off focus.
    private static let maximumDim: Double = 0.26

    func body(content: Content) -> some View {
        // Clamped: the third page sits two widths from the first, and a blur
        // that kept growing past the first width would be work spent on a
        // page the screen edge has already taken.
        let beyond = max(0, min(1, distance))
        content
            .blur(radius: reduceMotion ? 0 : Self.maximumBlur * beyond)
            .overlay {
                Rectangle()
                    .fill(Color.black.opacity(Self.maximumDim * beyond))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // A page the operator is not reading takes no taps. Half a page is
            // the midpoint of the flight: past it, the incoming page is the
            // one under the finger.
            .allowsHitTesting(abs(distance) < 0.5)
    }
}

extension View {
    func pageFocus(distance: CGFloat) -> some View {
        modifier(PageFocus(distance: distance))
    }
}

// MARK: - The preview page

/// The third page: a promise, kept honestly.
///
/// Built as a page of the plane rather than a hidden stub, so the plane is
/// whole from the first build -- the travel across it is real today, and what
/// arrives on it later is that page's business. Its centre sits below the
/// floating control, in the space the eye reads as the page's own.
private struct PreviewPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Preview", tableName: SidePlaneTable.name)
                .font(.headline)
            Text("Under development — stay tuned.", tableName: SidePlaneTable.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, SessionSidePlane.FloatingTab.pageChromeTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityIdentifier("side.preview")
    }
}
