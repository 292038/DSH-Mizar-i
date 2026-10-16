//
//  DSHMizarLiveActivityWidget.swift
//  DSH-Mizar-LiveActivity
//
//  The island and the lock screen: what the phone shows while the Mac works.
//
//  Two processes are involved and this is the second one. The app decides what
//  the activity *is* -- which sessions are running, what to call them, when the
//  whole thing should come down -- and hands the answer over as a value
//  (`LiveActivityPhase`, in MizarKit). This file draws that value and decides
//  nothing: which of the two phases it is *is* the difference between a clock and
//  a green check.
//
//  Two things about Live Activities are not obvious and shaped everything here:
//
//    - **The clock is the system's.** `Text(_:style:.timer)` counts up from an
//      instant, redrawn by the system on its own schedule -- no `Activity.update`
//      per second, no push, no waking the app. That is why a row carries
//      `countingSince` rather than a figure, and why an activity that goes
//      minutes without an update still tells the time correctly.
//
//    - **The island tints what it draws.** There is no colour to pick inside the
//      Dynamic Island: the system draws the compact and minimal presentations in
//      its own tint on its own black background, and the lock-screen card is
//      drawn in the vibrant mode widgets use. An app-icon bitmap dropped in
//      here would therefore come out as whatever the system does to a bitmap --
//      and, less obviously, *the app's own asset catalog is not visible from
//      this process at all*: the extension has its own bundle, so `Image` here
//      can only find assets in `DSH-Mizar-LiveActivity/Assets.xcassets`. The mark
//      is a template image in that catalog (`MizarIcon`, white on transparent,
//      `template-rendering-intent`), derived from the app icon's glyph with the
//      icon's navy background dropped -- see the note on `Mark`.
//
//  Nothing here reads a model, a cache or a network: a Live Activity runs in its
//  own sandbox with no network access, and everything it may draw arrived in the
//  content state.
//

import ActivityKit
import MizarKit
import SwiftUI
import WidgetKit

/// The one Live Activity this app posts.
struct DSHMizarLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DSHMizarActivityAttributes.self) { context in
            // The Lock Screen presentation, and the banner on a device without
            // an island. The same card the expanded island draws, because there
            // is nothing about it that depends on where it is drawn.
            LiveActivityCard(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // The title row: the mark and the app's name, on the leading
                // side of the camera. `belowIfTooWide` is not decoration --
                // "DSH-Mizar" beside a glyph is wider than the space left of
                // the TrueDepth camera on a compact island, and without it the
                // label is truncated to something nobody can read.
                DynamicIslandExpandedRegion(.leading) {
                    TitleRow()
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Headline(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionRows(state: context.state)
                }
            } compactLeading: {
                // Left: who this is about.
                Mark(diameter: 15)
            } compactTrailing: {
                // Right: how long the longest-running session has been going, or
                // the check that says nothing is.
                Headline(state: context.state)
            } minimal: {
                // One slot, no left and right. The check while everything is
                // finished, because that is the fact worth the space; the mark
                // otherwise, which says which app is working without a number
                // nobody can read at this size.
                MinimalMark(state: context.state)
            }
        }
    }
}

// MARK: - The pieces both presentations draw

/// The app's mark.
///
/// `MizarIcon` in this extension's asset catalog is a **template** image: white
/// on transparent, with `template-rendering-intent` set, so the system tints it
/// for wherever it is drawn instead of pasting a bitmap of an app icon onto the
/// island's black background. It is derived from `AppIcon-1024.png` -- the
/// glyph's pixels kept, white; the icon's navy background dropped to alpha; the
/// glyph's own bounding box cropped square so the mark fills the frame rather
/// than sitting inside a square of nothing.
///
/// It is also **small** on purpose. Apple's rule for a Live Activity asset is
/// that its resolution must not exceed the presentation it is drawn in, and a
/// 1024-pixel app icon is larger than every one of them -- at which point the
/// system may refuse to start the activity at all. The imageset is 32/64/96
/// pixels, so nothing here can trip that.
private struct Mark: View {
    var diameter: CGFloat

    var body: some View {
        Image("MizarIcon")
            .resizable()
            .scaledToFit()
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(Text(verbatim: "DSH-Mizar"))
    }
}

/// The icon and the app's name, which is what the activity is about.
///
/// The name is `verbatim`: it is the app's name on the App Store and on the
/// Mac, not a phrase to be translated. An activity that reads 米扎尔 in one
/// language and DSH-Mizar in another would be a different app's card.
private struct TitleRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Mark(diameter: 16)
            Text(verbatim: "DSH-Mizar")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The island's right side: a counting clock, or the check that says nothing is.
///
/// One row's worth of information, deliberately. The compact trailing region is
/// about forty points wide, which is a duration and nothing else.
private struct Headline: View {
    let state: LiveActivityPhase

    var body: some View {
        if let longest = state.rows.first {
            // The system ticks this. No update from the app, ever, for the
            // seconds to move -- and monospaced digits so the text does not
            // jitter sideways as the numbers change.
            Text(longest.countingSince, style: .timer)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .accessibilityLabel(Text("Running time"))
        } else {
            FinishedCheck()
        }
    }
}

/// The green check every finished presentation ends with.
private struct FinishedCheck: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityLabel(Text("Every session has finished"))
    }
}

/// The smallest presentation: one slot beside the camera.
private struct MinimalMark: View {
    let state: LiveActivityPhase

    var body: some View {
        if state.rows.isEmpty {
            FinishedCheck()
        } else {
            Mark(diameter: 17)
        }
    }
}

/// The rows the decision layer produced: one or two, longest-running first.
///
/// Each row is the beginning of that session's most recent instruction and the
/// time it has been going. The cutting is not done here -- `LiveActivityDecision`
/// decides how much of an instruction survives, and this file would be a second
/// opinion about it if it cut again.
private struct SessionRows: View {
    let state: LiveActivityPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.rows) { row in
                HStack(spacing: 8) {
                    // A row with no instruction is a session the app has not
                    // read the prompt of yet. It says only how long, which is
                    // true; the session id in the operator's place would be the
                    // app talking.
                    if !row.prompt.isEmpty {
                        Text(row.prompt)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(row.countingSince, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                        .accessibilityLabel(Text("Running time"))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The whole card: the title row, then the rows.
private struct LiveActivityCard: View {
    let state: LiveActivityPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TitleRow()
            if state.rows.isEmpty {
                // Nothing is running. The decision layer has no rows to give and
                // the card says so in words rather than by being blank, because
                // an activity is only ever *started* running: `.finished` here
                // means work that has just stopped, not an empty start.
                HStack(spacing: 6) {
                    FinishedCheck()
                    Text("Every session has finished")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
            } else {
                SessionRows(state: state)
            }
        }
        .foregroundStyle(.white)
        // The icon's own navy, so the card belongs to the app whose glyph is on
        // it. Set here rather than left to the system because the card's content
        // is drawn in one colour in every mode, and a tint that changed with the
        // wallpaper would leave white text on a pale card.
        .activityBackgroundTint(Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255))
        .activitySystemActionForegroundColor(.white)
    }
}
