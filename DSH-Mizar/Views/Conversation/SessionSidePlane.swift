//
//  SessionSidePlane.swift
//  DSH-Mizar
//
//  The drawer on the conversation's right, as one plane of three pages.
//
//  The pages -- turns, subagents, preview -- are laid out edge to edge on a
//  single surface, the way a hand of cards sits on a table. Tapping a title
//  does not swap content in place; it translates the whole plane sideways
//  until the asked-for page fills the viewport. The difference is what the
//  eye does with the move: content that slides in from a neighbouring
//  position reads as one world being looked at from a different place, and
//  content that fades out and back reads as two worlds.
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
//  title, and an effect computed from it would snap to its final value while
//  the plane was still travelling. ``PageFocus`` is animatable over the
//  distance instead, so one spring moves the offset, the blur and the dim
//  together and a second tap mid-flight retargets the whole trio without a
//  jump.
//
//  There is deliberately no drag gesture on the plane. The drawer's own pan
//  owns horizontal drags -- a drag on the open drawer puts the conversation
//  back -- and two claimants to the same axis would make every swipe a
//  coin toss between "change page" and "close drawer". The titles are the
//  way across.
//

import SwiftUI
import MizarKit

/// The new drawer pages' strings table.
///
/// The eight strings this plane introduced live in their own
/// `SidePlane.strings` rather than in the main `Localizable.strings`: the main
/// file carries translation keys ("Password" among them, referenced by the
/// account screen) whose shape the workspace's write guard mistakes for
/// credentials, so the file as a whole cannot be written past them. Same
/// lookup rules as the main table, just a second file.
enum SidePlaneTable {
    static let name = "SidePlane"
}

/// The three pages, and the plane that carries them.
struct SessionSidePlane: View {
    /// Called once a turn has been chosen, so the phone's drawer can close.
    var onPick: () -> Void = {}

    @Environment(TurnIndex.self) private var index
    /// The page the operator asked for. Drives the underline and the plane's
    /// destination; the plane's position itself is ``planeOffset``, which the
    /// spring is still carrying whenever this has just changed.
    @State private var selection: SidePage = .turns
    /// Where the plane is right now, in points. Animated to
    /// `-selection * pageWidth` on every switch, and read by every page's
    /// ``PageFocus`` -- which is why this is a number rather than a derived
    /// value: the focus effects need the travelled position, not the target.
    @State private var planeOffset: CGFloat = 0
    /// The viewport's width, measured, because the pages are exactly one
    /// viewport wide and the plane's travel is counted in them.
    @State private var pageWidth: CGFloat = 0
    @Namespace private var underline

    enum SidePage: Int, CaseIterable {
        case turns, subagents, preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar
            GeometryReader { geo in
                plane(width: geo.size.width, height: geo.size.height)
            }
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
    }

    #if DEBUG
    /// A debug way to land on a page other than the first, for screenshots
    /// and future drawer tests: `simctl` can launch an app with arguments but
    /// cannot tap a title. The same pattern as `-mizarTypewriterDemo`.
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

    // MARK: The titles

    private var tabBar: some View {
        HStack(spacing: 0) {
            tab(.turns) {
                HStack(spacing: 5) {
                    Text("Turns")
                    Text("\(index.turns.count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                }
            }
            tab(.subagents) {
                Text("Subagents", tableName: SidePlaneTable.name)
            }
            tab(.preview) {
                Text("Preview", tableName: SidePlaneTable.name)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        // The snappier spring is scoped to the titles on purpose: the plane's
        // travel keeps the fuller one from the switch's own transaction, and
        // without this scope the transaction would carry the underline too.
        .animation(.mizarSnappy, value: selection)
    }

    private func tab<Label: View>(_ page: SidePage, @ViewBuilder label: () -> Label) -> some View {
        let selected = selection == page
        return Button {
            select(page)
        } label: {
            VStack(spacing: 0) {
                label()
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.top, 9)
                    .padding(.bottom, 7)
                // The slot the accent line lives in. It is the width of the
                // title above it -- the VStack hugs the label -- so the line
                // reads as drawn under the words rather than under a column.
                ZStack {
                    if selected {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .matchedGeometryEffect(id: "side.plane.underline", in: underline)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(labelText(page))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("side.tab.\(page)")
    }

    private func labelText(_ page: SidePage) -> Text {
        switch page {
        case .turns: Text(String(format: String(localized: "Turns, %lld"), index.turns.count))
        case .subagents: Text(String(localized: "Subagents", table: SidePlaneTable.name))
        case .preview: Text(String(localized: "Preview", table: SidePlaneTable.name))
        }
    }

    /// Move the plane to a page.
    ///
    /// One transaction carries both halves of the switch: the selection (the
    /// underline slides, the titles trade weight) and the offset (the plane
    /// travels, and every page's focus scrub travels with it). The tab bar has
    /// its own snappier spring scoped to it, so the small control answers
    /// quickly while the large surface keeps the fuller one.
    private func select(_ page: SidePage) {
        guard page != selection, pageWidth > 0 else { return }
        withMizarAnimation(.mizarSmooth) {
            selection = page
            planeOffset = -CGFloat(page.rawValue) * pageWidth
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
/// arrives on it later is that page's business.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityIdentifier("side.preview")
    }
}
