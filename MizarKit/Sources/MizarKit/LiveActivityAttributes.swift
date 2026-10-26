//
//  LiveActivityAttributes.swift
//  MizarKit
//
//  The one type the app and the widget have to agree on.
//
//  ActivityKit routes a Live Activity to a widget by its *attributes type*: the
//  app asks for an activity of `DSHMizarActivityAttributes`, and the widget that
//  declared `ActivityConfiguration(for: DSHMizarActivityAttributes.self)` draws
//  it. The two are separate processes, built from separate targets, and they
//  share nothing except this file -- which is why it lives in MizarKit, the one
//  module both targets link.
//
//  The attributes are empty, and that is the design rather than a stub. Static
//  attributes are for what is *constant about one activity and varies between
//  activities*: a match, a flight, a delivery. This app posts one kind of
//  activity for one host, whose title row -- the icon and the literal
//  "DSH-Mizar" -- is the same on every activity it will ever post. State that
//  never varies is state that can only go stale, and the title is drawn by the
//  widget instead (see `LiveActivityWidget.swift`).
//
//  So the whole of what crosses the process boundary is the `ContentState`, and
//  that is `LiveActivityState`: the rows, their clocks, and whether anything is
//  running at all. Every rule about what it means was decided in this module
//  before either process asked -- see ``LiveActivityDecision``.
//
//  The conformance is conditional because `ActivityKit` does not exist on macOS,
//  where this package's test suite runs. The type is plain everywhere; it only
//  becomes an attributes type on a platform that has activities.
//

import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// What one DSH-Mizar Live Activity is about.
///
/// Carries nothing: see the note at the top of this file. The activity's state --
/// which is everything the widget draws -- is ``LiveActivityState``.
///
/// `Codable` here rather than only inside the conditional conformance below,
/// because an attributes type *is* `Codable` -- `ActivityAttributes` refines
/// both -- and because this way the wire shape of the type is pinned by a test
/// that runs on the host, where there is no ActivityKit to conform to.
public struct DSHMizarActivityAttributes: Codable, Sendable, Equatable {
    /// There is nothing to set. Written out because a public type with no
    /// explicit initialiser gets only the internal one, and the app target is a
    /// different module from this one.
    public init() {}
}

#if os(iOS) && canImport(ActivityKit)
extension DSHMizarActivityAttributes: ActivityAttributes {
    /// The rows and whether anything is counting.
    public typealias ContentState = LiveActivityState
}
#endif
