//
//  AppFlowTests.swift
//  DSH-MizarUITests
//
//  Regression cover for the screens that were, until now, verified by taking a
//  screenshot and looking at it.
//
//  That is not a rhetorical complaint. Adding localisation produced three
//  screenshots showing English strings while the bundle on disk already had the
//  Chinese ones, because `simctl install` had left the previous binary running.
//  Manual verification reported a failure that did not exist. These tests exist
//  so the next one of those is caught by a machine.
//
//  They run against `scripts/mock-host.mjs`, which serves the real protocol with
//  record shapes taken from a live host. A pending approval only exists while an
//  agent is blocked on a tool call, so the real host cannot be asked to produce
//  one on demand -- and on this machine it cannot produce one at all, because
//  every turn ends in MISSING_CREDENTIAL before reaching a tool.
//
//  Elements are found by accessibility identifier, never by label: a query for
//  "Allow once" passes only in English, and the title not being a stable name is
//  the entire point of the localisation work.
//

import XCTest

final class AppFlowTests: XCTestCase {
    /// The mock host, which must be running before this suite is.
    private static let mockPairingURI =
        "mizar://pair?h=127.0.0.1%3A19395&c=MOCK-CODE&n=Mock%20Mac&v=1"

    /// A second Mac, on a second port, with its own identity.
    ///
    /// Every piece of state the app keeps is scoped to a machine, and a single
    /// mock cannot show that: it answers every read with the same host id, the
    /// same sessions and the same providers, so a screen drawn from one Mac's
    /// answer under another Mac's name looks exactly like a screen drawn
    /// correctly. `node scripts/mock-host.mjs 19396` is a *different* machine --
    /// its own host id, its own name, its own session ids, its own model
    /// catalogue -- which is what makes "this belongs to that Mac" assertable.
    private static let secondMockPairingURI =
        "mizar://pair?h=127.0.0.1%3A19396&c=MOCK-CODE&n=Mock%20Mac%20(second)&v=1"

    /// How long to wait for the host to answer.
    private static let patience: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
        // Every test starts against a host that answers, whatever the last one
        // left behind. `/offline?on=1` is switched back by a `defer` inside the
        // one test that uses it -- and an assertion with
        // `continueAfterFailure = false` aborts by raising, which skips Swift
        // `defer`s. One aborted test was therefore enough to leave the fixture
        // refusing every connection for the rest of the suite, and the next test
        // then failed reporting a bug in the app that was a bug in the fixture.
        Self.setMockOffline(false)
    }

    /// Put the mock host's conversation back to its fixture.
    ///
    /// The mock remembers what has been sent to it -- that is what makes the send
    /// path testable at all -- but it remembered it for the life of the process,
    /// which is the whole suite. Every test after the first send ran against a
    /// longer conversation than the one before it, so a test that scrolled to
    /// find a message found a different amount of content depending on which
    /// tests had run first. A suite whose failures depend on test order is a
    /// suite whose failures cannot be trusted, and two of them were exactly that.
    ///
    /// - Parameters:
    ///   - pending: whether the mock should offer a pending approval and
    ///     question. They fill most of a phone screen, which is correct
    ///     behaviour and useless to a test about what is underneath them.
    ///   - slow: how long the mock should stall every answer, in milliseconds.
    ///     For the two screens that exist to report how long something is
    ///     taking, which cannot be observed against a host that answers instantly.
    private static func resetMockHost(
        pending: Bool = true,
        slow: Int = 0,
        skew: Int = 0,
        pageLimit: Int? = nil,
        running: Bool = true,
    ) {
        var query = pending ? "" : "?pending=0"
        if slow > 0 { query += query.isEmpty ? "?slow=\(slow)" : "&slow=\(slow)" }
        // A host whose clock is ahead of the phone's, and a host that refuses a
        // page too large to deliver. Both are states the real host reaches on
        // its own, and neither can be produced from the app's side.
        if skew > 0 { query += query.isEmpty ? "?skew=\(skew)" : "&skew=\(skew)" }
        if let pageLimit { query += query.isEmpty ? "?pageLimit=\(pageLimit)" : "&pageLimit=\(pageLimit)" }
        // A host whose session has stopped, so no Live Activity is posted. What
        // this is for is a test that must not be run in the same process as the
        // widget extension.
        if !running { query += query.isEmpty ? "?running=0" : "&running=0" }
        guard let url = URL(string: "http://127.0.0.1:19395/reset\(query)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        // Bounded, because a mock host that is not running is a suite that is
        // about to fail on its own terms -- not one to hang on here.
        _ = done.wait(timeout: .now() + 6)
    }

    /// Put the *second* Mac's fixture back, on the other port.
    ///
    /// The same reset as ``resetMockHost(pending:slow:skew:pageLimit:running:)``,
    /// for the other machine. A test that switches between two Macs has two
    /// fixtures to keep apart, and one of them left carrying the previous test's
    /// sends while the other was reset is a test whose second half measures the
    /// first.
    ///
    /// - Parameter running: whether that machine's session reports itself as
    ///   running. `false` by default, which keeps the Live Activity out of a test
    ///   about two session lists.
    private static func resetSecondMockHost(running: Bool = false) {
        // The cards are off, like the test that uses this helper wants: they
        // fill the conversation and one of them sits over the composer, which
        // is where this test taps.
        var query = "?pending=0"
        if !running { query += "&running=0" }
        guard let url = URL(string: "http://127.0.0.1:19396/reset\(query)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Make the mock host refuse connections, or stop refusing them.
    ///
    /// - Parameter off: whether it should be unreachable.
    private static func setMockOffline(_ off: Bool) {
        guard let url = URL(string: "http://127.0.0.1:19395/offline?on=\(off ? 1 : 0)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Make the mock host fail every answer to one method, from now on.
    ///
    /// For the reads a screen makes more than once: what a *later* failure does
    /// to figures an earlier read already drew. Cleared by the next `/reset`,
    /// like the rest of the mock's state.
    ///
    /// - Parameter method: the wire method to refuse.
    /// - Returns: whether the mock confirmed it is refusing that method. Checked
    ///   rather than assumed, because a knob that did not take turns every
    ///   assertion after it into an assertion about something else -- which cost
    ///   an afternoon of reading a failure screen as a bug in the app.
    @discardableResult
    private static func failMockHost(_ method: String) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:19395/fail?method=\(method)") else { return false }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.value = (parsed["failMethod"] as? String) == method ? 1 : 0
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value == 1
    }

    /// Make the mock host answer `session.stats` like a cold session.
    ///
    /// Not a failure: the same frame with the projections that need a warm agent
    /// left empty, which is what a phone gets for a session nothing has run in
    /// yet. A screen that replaces what it has with it loses the title, the
    /// model and the context figure.
    ///
    /// - Parameter cold: whether to answer that way.
    private static func setMockStatsCold(_ cold: Bool) {
        let variant = cold ? "cold" : "full"
        guard let url = URL(string: "http://127.0.0.1:19395/stats?variant=\(variant)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Stall every answer the mock host gives, from now on.
    ///
    /// Called mid-test rather than at launch: the launch itself is a download,
    /// and making that slow too would leave the screen under test unreachable --
    /// the refresh button is disabled while the first download runs.
    ///
    /// - Parameter milliseconds: how long each answer should take.
    private static func stallMockHost(_ milliseconds: Int) {
        slowMockHost(milliseconds, method: nil)
    }

    /// Stall one method's answers, leaving the rest immediate.
    ///
    /// The other half of ``stallMockHost(_:)``, for a test that needs one slow
    /// read rather than a slow app: a reload held open on `session.messages`
    /// while the send that is being measured answers straight away.
    ///
    /// - Parameters:
    ///   - milliseconds: how long each answer to that method should take.
    ///   - method: the wire method to stall.
    private static func stallMockHost(_ milliseconds: Int, method: String) {
        slowMockHost(milliseconds, method: method)
    }

    /// - Parameters:
    ///   - milliseconds: how long each stalled answer should take.
    ///   - method: the one method to stall, or `nil` for every method.
    private static func slowMockHost(_ milliseconds: Int, method: String?) {
        let named = method.map { "&method=\($0)" } ?? ""
        guard let url = URL(string: "http://127.0.0.1:19395/slow?ms=\(milliseconds)\(named)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Hold the mock's conversation reads, or let them go.
    ///
    /// A stall is a race, and this is not: a delay long enough to be measured on
    /// a loaded machine is a delay long enough for whatever was meant to overlap
    /// it to have finished first. Held, the reload under test is still in flight
    /// when the next thing happens -- by construction rather than by timing, so
    /// the assertion about a second load landing on top of it is deterministic.
    ///
    /// - Parameter holding: whether to hold them.
    /// - Returns: how many held answers the release let go, so that a test can
    ///   say it released something rather than assume it did.
    @discardableResult
    private static func holdMockConversationReads(_ holding: Bool) -> Int? {
        guard let url = URL(string: "http://127.0.0.1:19395/hold?messages=\(holding ? 1 : 0)") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.value = parsed["released"] as? Int
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value
    }

    /// What the mock host has seen of overlapping conversation reads.
    ///
    /// `inFlight` is how many `session.messages` requests it is answering right
    /// now and `peak` the most it ever answered at once, both since the last
    /// reset. Neither is visible from the app: two overlapping loads are both
    /// answered correctly and settle on the same conversation, so "one load was
    /// in flight, not two" is a fact only the host holds.
    ///
    /// - Returns: the counts, or `nil` when the mock is not answering.
    private static func mockLoads() -> (inFlight: Int, peak: Int)? {
        guard let url = URL(string: "http://127.0.0.1:19395/loads?reset=1") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.counts = (parsed["inFlight"] as? Int, parsed["peak"] as? Int)
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        guard let counts = box.counts, let inFlight = counts.0, let peak = counts.1 else { return nil }
        return (inFlight, peak)
    }

    /// What the mock host has been asked, by method, since the last reset.
    ///
    /// The one piece of evidence a refresh made with no screen leaves where a
    /// test can read it. The host's count is a fact about the wire, not about
    /// either process's opinion of itself.
    ///
    /// - Returns: method name to count, empty when the mock is not answering.
    private static func mockMethodCounts() -> [String: Int] {
        guard let url = URL(string: "http://127.0.0.1:19395/loads") else { return [:] }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let methods = parsed["methods"] as? [String: Any]
            else { return }
            box.methods = methods.compactMapValues { ($0 as? NSNumber)?.intValue }
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.methods
    }

    /// Wait until an element's label says something.
    ///
    /// The figures in the composer bar come from a read that lands after the
    /// screen does, so a plain `label.contains` is an assertion about a snapshot
    /// taken at an arbitrary moment -- and it failed the once, on the run where
    /// the read happened to be slower. Polling is what the rest of this file
    /// does for the same reason.
    ///
    /// - Parameters:
    ///   - element: what to watch.
    ///   - text: what its label should contain.
    /// - Returns: whether it got there.
    private func labelLands(_ element: XCUIElement, containing text: String) -> Bool {
        let arrived = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element,
        )
        return XCTWaiter().wait(for: [arrived], timeout: Self.patience) == .completed
    }

    /// Open a workspace and wait for a row inside it.
    ///
    /// The condition is the row rather than the tap, so a tap that is lost -- to
    /// the naming sheet still animating away, which is where this went wrong --
    /// costs a retry instead of twenty seconds of waiting for something that will
    /// not happen.
    ///
    /// - Parameters:
    ///   - heading: the workspace's heading, found by its identifier.
    ///   - row: a row that only exists inside the workspace.
    ///   - attempts: how many times to try.
    /// - Returns: whether the row turned up.
    @discardableResult
    private func expand(_ heading: XCUIElement, revealing row: XCUIElement, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if row.exists { return true }
            guard heading.waitForExistence(timeout: 5), heading.isHittable else { continue }
            // The heading's own title, not the button and not a coordinate: a
            // tap at the centre of the button lands on the empty space between
            // the title and the count and does not toggle it -- measured on both
            // destinations, three attempts in a row leaving the workspace
            // folded. `heading` is the button, and its first static text is the
            // title, which is the element an operator actually taps.
            let title = heading.staticTexts.element(boundBy: 0)
            guard title.exists else { continue }
            title.tap()
            if row.waitForExistence(timeout: 3) { return true }
        }
        return row.exists
    }

    /// The row for one session, under either name it can be drawn with.
    ///
    /// The title is the host's once it has given one, and otherwise the working
    /// directory and the session's id -- so a query for the pretty name alone
    /// finds nothing on a phone whose host has not named the session yet, which
    /// is a test that fails for a reason of its own making.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - title: the host's title for the session.
    ///   - directory: the last path component of its working directory.
    /// - Returns: the element to tap.
    private func sessionRow(in app: XCUIApplication, titled title: String, in directory: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(directory) · "),
        ).firstMatch
    }

    /// Scroll through the conversation until an element is in the tree.
    ///
    /// A `LazyVStack` builds only what is near the screen, so an element that is
    /// in the data can be absent from the accessibility hierarchy entirely --
    /// and `waitForExistence` cannot see what the app has not built. The
    /// conversation opens anchored to its newest message, so anything older than
    /// that needs scrolling to before it can be asserted on.
    ///
    /// Both directions. The content is longer than the screen -- prompts,
    /// turn rows, answers, the failure card -- and a helper that only travelled
    /// one way reported a row as missing from a screen it was on. It used to have
    /// a second reason, that expanding a turn moved rows in both directions;
    /// turns are no longer expandable, and this is kept because the list is still
    /// longer than the display.
    ///
    /// - Parameters:
    ///   - element: what to look for.
    ///   - app: the running app.
    ///   - swipes: how many screenfuls to travel in each direction.
    /// - Returns: whether it turned up.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        // Give the screen a moment to draw before touching it. Swiping at a
        // conversation that is still loading scrolls nothing and reports the
        // row as absent from a screen it is about to be on -- which is how this
        // helper failed intermittently on a test that had passed a dozen times.
        if element.waitForExistence(timeout: 5) { return true }
        for direction in [0, 1] {
            for _ in 0..<swipes {
                if element.exists { return true }
                // Zero travels towards older messages, one towards newer.
                if direction == 0 { app.swipeDown() } else { app.swipeUp() }
            }
        }
        return element.exists
    }

    /// A value written on URLSession's queue and read once the wait is over.
    ///
    /// `@unchecked Sendable` with the semaphore below as the synchronisation: the
    /// write happens before `signal()` and the read after `wait()`.
    private final class Box: @unchecked Sendable {
        var value: Int?
        /// Two counts at once, for the one endpoint that reports a pair.
        var counts: (Int?, Int?)?
        /// What the mock host was asked, by method.
        var methods: [String: Int] = [:]
    }

    /// How many sockets the mock host has accepted since the suite last reset it.
    ///
    /// A reconnect is invisible from the app's side -- the data looks the same
    /// afterwards -- so the only way to assert that a failure did *not* cost a
    /// fresh socket is to count them at the host.
    ///
    /// - Returns: the count, or `nil` when the mock is not answering.
    private static func mockConnections() -> Int? {
        guard let url = URL(string: "http://127.0.0.1:19395/connections") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.value = parsed["connections"] as? Int
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value
    }

    /// Launch the app, optionally pairing and opening a session on the way in.
    /// - Parameters:
    ///   - pairing: whether to pass a pairing URI.
    ///   - session: a session to open, or `nil` to stay on the list.
    ///   - language: a language to force, or `nil` to follow the system.
    ///   - pending: whether the mock should offer a pending approval and question.
    ///   - slow: how long the mock should stall every answer, in milliseconds.
    ///   - skew: how far ahead of the phone the mock's clock should be, in
    ///     milliseconds. Zero for every test that is not about the two clocks
    ///     disagreeing.
    ///   - pageLimit: the largest page the mock will answer, when a test wants
    ///     the host to refuse one that will not fit.
    ///   - running: whether the mock's session reports itself as running. `false`
    ///     keeps the Live Activity out of the run, for a test about the screens
    ///     rather than about the island.
    ///   - freshStart: whether to throw the stored data away first.
    ///   - naming: whether to wait for the naming prompt before returning.
    ///     It is offered *after* a first download, so a test about that download
    ///     would spend the whole of it here instead of looking at it.
    ///   - pairingURIs: the Macs to pair with on the way in, in order. One is the
    ///     ordinary case; two is a phone that manages more than one machine, which
    ///     is the only setup in which cross-machine state can be observed at all.
    /// - Returns: the running application.
    private func launch(
        pairing: Bool = true,
        session: String? = "first",
        language: String? = "en",
        pending: Bool = true,
        slow: Int = 0,
        skew: Int = 0,
        pageLimit: Int? = nil,
        running: Bool = true,
        naming: Bool = true,
        freshStart: Bool = true,
        pairingURIs: [String] = [mockPairingURI],
    ) -> XCUIApplication {
        Self.resetMockHost(pending: pending, slow: slow, skew: skew, pageLimit: pageLimit, running: running)
        let app = XCUIApplication()
        app.launchArguments = Self.arguments(
            pairing: pairing,
            session: session,
            language: language,
            freshStart: freshStart,
            pairingURIs: pairingURIs,
        )
        app.launch()
        if naming { dismissNamingIfPresented(app) }
        return app
    }

    /// The launch arguments one run of the app is started with.
    ///
    /// Kept apart from ``launch(pairing:session:language:pending:slow:naming:freshStart:)``
    /// so that a test which relaunches the app can say what the *second* launch
    /// looks like. That is the only way to check anything that has to outlive a
    /// process -- a stored pairing, a switch position -- because everything else
    /// in this suite throws the app away between assertions.
    ///
    /// - Parameters:
    ///   - pairing: whether to pass a pairing URI.
    ///   - session: a session to open, or `nil` to stay on the list.
    ///   - language: a language to force, or `nil` to follow the system.
    ///   - freshStart: whether to throw the stored data away first.
    ///   - pairingURIs: the Macs to pair with, in order.
    /// - Returns: the arguments.
    private static func arguments(
        pairing: Bool,
        session: String?,
        language: String?,
        freshStart: Bool,
        pairingURIs: [String] = [mockPairingURI],
    ) -> [String] {
        var arguments: [String] = []
        // Repeated, and in order: the app pairs with each in turn, which is how a
        // phone that manages two Macs gets that way without a test having to walk
        // the pairing screen twice.
        if pairing { for uri in pairingURIs { arguments += ["-mizarPairURI", uri] } }
        if let session { arguments += ["-mizarSelectSession", session] }
        if let language { arguments += ["-AppleLanguages", "(\(language))"] }
        // The stored conversations outlive a relaunch, which is the point of
        // them -- and means a test that did not ask for a clean one would be
        // measuring an earlier run's fixture merged with this one's.
        if freshStart { arguments += ["-mizarFreshStart"] }
        // The system prompts are real and belong to the app, not to a test:
        // answered by an alert, every assertion after them measures the alert.
        arguments += ["-mizarSkipPermissionPrompts"]
        return arguments
    }

    /// Open the settings tab.
    ///
    /// The tab is found by position and never by its label: the label is 设置 in
    /// Chinese, and a query for "Settings" passes only in one language.
    ///
    /// - Parameter app: the running app.
    private func openSettings(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons.element(boundBy: 1)
        let opener = tab.exists ? tab : app.buttons.element(boundBy: 1)
        expect(opener, "there is no settings tab")
        opener.tap()
    }

    /// The control for one switch on the settings screen.
    ///
    /// Three queries, in order, because how SwiftUI exposes a `Toggle` has moved
    /// between OS versions: the classic `switches` query, the newer `toggles`
    /// one -- `XCUIElement.ElementType.toggle` is a separate type -- and finally
    /// any element carrying the identifier, which is what a `List` row does when
    /// the control inside it is not itself exposed. The first version of this
    /// test asked `switches` alone and reported a screen full of switches as
    /// having none.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    /// - Returns: the element to tap.
    private func settingControl(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        for candidate in [app.switches[identifier], app.toggles[identifier]] where candidate.exists {
            return candidate
        }
        // The identifier reached a row rather than a control. Tapping the row is
        // normally enough -- a `Toggle` row toggles from anywhere on it -- but the
        // control inside is tried first when there is one, because it is the
        // thing the tap is meant for.
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for inner in [row.switches.firstMatch, row.toggles.firstMatch] where inner.exists {
            return inner
        }
        return row
    }

    /// Whether one switch is on, read from whichever element reports it.
    ///
    /// The identifier can land on the control or on the row that contains it, so
    /// both are tried and the value is taken from the first that has one.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    /// - Returns: the state, or `nil` when nothing reported one.
    private func settingState(_ identifier: String, in app: XCUIApplication) -> Bool? {
        let candidates = [
            app.switches[identifier],
            app.toggles[identifier],
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch,
        ]
        for candidate in candidates where candidate.exists {
            if let state = Self.onValue(candidate) { return state }
            // The identifier reached a row: the state is on something inside it,
            // which may carry no identifier of its own. Bounded, because this
            // walks the accessibility tree of one row.
            let inside = candidate.descendants(matching: .any)
            for index in 0..<min(inside.count, 12) {
                if let state = Self.onValue(inside.element(boundBy: index)) { return state }
            }
        }
        return nil
    }

    /// Tap a switch, aiming at the control rather than at the row.
    ///
    /// `element.tap()` taps the centre of whatever frame the element reports, and
    /// a SwiftUI `Toggle` row is exposed as a switch whose frame is sometimes the
    /// whole row -- so the centre of it is the *label*, and a tap there did
    /// nothing at all. Aiming near the trailing edge lands on the switch in both
    /// cases: it is still inside a switch that reports its own frame, and it is
    /// the switch that lives at the trailing edge of a row that reports the row's.
    ///
    /// - Parameters:
    ///   - control: the element to tap.
    ///   - app: the running app, for nothing but symmetry with the other helpers.
    private func flip(_ control: XCUIElement, in app: XCUIApplication) {
        _ = app
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Wait until a switch reports a different state.
    ///
    /// Polled rather than read once: the write goes through SwiftUI's binding and
    /// comes back as a re-render, which is a frame later than the tap.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    ///   - before: the state it had.
    /// - Returns: whether it moved.
    private func settingChanges(_ identifier: String, in app: XCUIApplication, from before: Bool?) -> Bool {
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.settingState(identifier, in: app) != before },
            object: nil,
        )
        return XCTWaiter().wait(for: [moved], timeout: 5) == .completed
    }

    /// A switch's value, as a `Bool`.
    /// - Parameter element: the element to read.
    /// - Returns: whether it is on, or `nil` when it reports nothing.
    private static func onValue(_ element: XCUIElement) -> Bool? {
        switch (element.value as? String)?.lowercased() {
        case "1", "on", "true": true
        case "0", "off", "false": false
        default: nil
        }
    }

    /// The element carrying an identifier whose label says something.
    ///
    /// A SwiftUI `Label` puts its identifier on both the text and the symbol --
    /// the symbol's label is "Account" -- so asking for "the" element with an
    /// identifier is ambiguous, and `XCUIElementQuery` throws rather than
    /// choosing. The one whose label contains the expected text is the one
    /// wanted, and both callers here are checking text.
    ///
    /// - Parameters:
    ///   - identifier: the accessibility identifier.
    ///   - app: the running app.
    ///   - text: what the label should contain.
    /// - Returns: the element, or the first match when none says it.
    private func labelled(_ identifier: String, in app: XCUIApplication, contains text: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        for index in 0..<matches.count where matches.element(boundBy: index).label.contains(text) {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    /// Scroll the settings list until a row has been built.
    ///
    /// A SwiftUI `List` is lazy in the same way the conversation is: a row below
    /// the fold is not in the accessibility tree at all, and `waitForExistence`
    /// cannot see what the app has not built.
    ///
    /// - Parameters:
    ///   - element: the row to look for.
    ///   - app: the running app.
    ///   - swipes: how far to travel.
    /// - Returns: whether it turned up.
    @discardableResult
    private func revealInSettings(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.exists { return true }
        }
        return element.exists
    }

    /// Skip the naming prompt.
    ///
    /// Pairing offers a name once, which is a product feature and not what these
    /// tests are about; a test that leaves it up is a test that measures the
    /// sheet.
    ///
    /// It is offered *after* the first download -- the download is the whole
    /// screen, and a prompt presented over it would be answered blind -- so the
    /// wait has to outlast a download rather than a screen transition. Five
    /// seconds was enough for a transition and not for a download, and the
    /// symptom was an intermittent failure in whichever test ran slowest: the
    /// sheet was still up, covering the screen every assertion was about.
    ///
    /// - Parameter app: the launched app.
    private func dismissNamingIfPresented(_ app: XCUIApplication) {
        let skip = app.buttons["rename.skip"]
        if skip.waitForExistence(timeout: Self.patience) { skip.tap() }
    }

    /// Wait for an element to exist.
    /// - Parameters:
    ///   - element: the element.
    ///   - message: what to say when it never appears.
    private func expect(_ element: XCUIElement, _ message: String) {
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.patience),
            "\(message) (waited \(Self.patience)s)",
        )
    }

    // MARK: - Sessions

    func testSessionListNamesTheHostAndOffersANewSession() {
        let app = launch(session: nil)
        expect(app.staticTexts["Mock Mac (fixture)"], "the host's name is not shown")
        expect(app.buttons["sessions.new"], "there is no way to start a session")
        expect(app.buttons["sessions.refresh"], "there is no way to refresh")
        // The row is titled by its directory, which is what tells two sessions
        // apart when neither has a title yet.
        expect(app.staticTexts["demo"], "the session row is missing")
    }

    func testAnUnpairedLaunchOffersPairing() {
        let app = launch(pairing: false, session: nil)
        // A launch without a pairing URI either finds one stored from an earlier
        // launch and connects, or has none and shows the pairing screen. Both are
        // correct; what must not happen is neither.
        // A never-paired phone now says what to do rather than showing an empty
        // list, and offers the scanner directly.
        let unpaired = app.buttons["unpaired.scan"]
        let sessions = app.buttons["sessions.new"]
        let appeared = unpaired.waitForExistence(timeout: Self.patience)
            || sessions.waitForExistence(timeout: Self.patience)
        XCTAssertTrue(appeared, "the app reached neither the pairing screen nor the session list")
    }

    /// The second tab: the four sections, each with something in it.
    ///
    /// Asked for as a bar with "对话" on the left and "设置" on the right, and as
    /// a settings screen rather than a placeholder. What is asserted is that each
    /// of the four sections has its control -- the switches, the export button
    /// and the source link -- because a screen can be present and empty.
    func testTheSecondTabOpensSettings() {
        let app = launch(session: nil)
        openSettings(app)
        // 通知: the four switches, and the system permission they sit under.
        expect(settingControl("settings.notify.turn-finished", in: app), "there is no 任务完成 switch")
        expect(settingControl("settings.notify.turn-interrupted", in: app), "there is no 任务中断 switch")
        expect(settingControl("settings.notify.question", in: app), "there is no 模型询问 switch")
        expect(settingControl("settings.notify.approval", in: app), "there is no 权限授予 switch")
        expect(
            app.descendants(matching: .any).matching(identifier: "settings.notify.authorization").firstMatch,
            "the system notification permission is not shown",
        )
        // 实时活动.
        expect(settingControl("settings.liveActivity", in: app), "there is no live activity switch")
        // 日志 and 关于 are below the fold on a phone.
        XCTAssertTrue(
            revealInSettings(app.buttons["settings.logs.export"], in: app),
            "there is no log export button",
        )
        XCTAssertTrue(
            revealInSettings(app.descendants(matching: .any)["settings.about.version"], in: app),
            "the about section is missing",
        )
        // Both tabs, so a bar that switched to a screen it cannot leave would
        // not pass. Scrolled back to the top first: on iOS 26 the tab bar steps
        // out of the way while a list is scrolled down, and a tap on a minimised
        // bar does not switch tabs -- which is correct behaviour, and meant this
        // test was tapping a bar that had put itself away.
        for _ in 0..<4 { app.swipeDown() }
        let conversation = app.tabBars.buttons.element(boundBy: 0)
        conversation.tap()
        expect(app.buttons["sessions.new"], "the conversation tab does not come back")
    }

    /// A switch is a setting, not a picture of one.
    ///
    /// The value asserted is the one the switch moved to rather than its default,
    /// because the app's defaults outlive a test run -- `xcodebuild test`
    /// reinstalls the app but does not wipe its container, so a suite that
    /// insisted on "on" would fail on the second run and pass on the third.
    /// What matters is that the change survives the process, which is the whole
    /// difference between a switch and a decoration.
    func testANotificationSwitchSurvivesARelaunch() {
        let app = launch(session: nil)
        openSettings(app)
        // The identifier is built from the notification kind's wire name, which
        // is hyphenated -- `settings.notify.turn-finished`, not `turnFinished`.
        let identifier = "settings.notify.turn-finished"
        let control = settingControl(identifier, in: app)
        expect(control, "there is no 任务完成 switch")
        let before = settingState(identifier, in: app)
        XCTAssertNotNil(
            before,
            "the switch reports no state to read: \(control.debugDescription)",
        )
        flip(control, in: app)
        XCTAssertTrue(
            settingChanges(identifier, in: app, from: before),
            "the switch did not move when it was tapped: \(control.debugDescription)",
        )
        let after = settingState(identifier, in: app)

        // The same phone, the same app, a new process. Nothing here is in memory
        // only, or this is where it shows.
        app.terminate()
        let reopened = launch(session: nil, freshStart: false)
        openSettings(reopened)
        expect(settingControl(identifier, in: reopened), "the settings screen did not come back")
        XCTAssertEqual(
            settingState(identifier, in: reopened),
            after,
            "the switch did not survive a relaunch",
        )
        // Put it back, so the next run of this suite starts where this one did.
        flip(settingControl(identifier, in: reopened), in: reopened)
    }

    /// The export button produces a zip and offers it.
    ///
    /// The two things that must not be flaky: the file is made, and something
    /// offers it. The file is asserted first and always; the share sheet is the
    /// system's `UIActivityViewController`, so it is recognised rather than
    /// driven -- picking a destination in it is a test of iOS, not of this app.
    /// The archive itself is checked outside the test, by unzipping it from the
    /// app's container.
    func testTheLogExportMakesAZipAndOffersIt() {
        let app = launch(session: nil)
        openSettings(app)
        let export = app.buttons["settings.logs.export"]
        XCTAssertTrue(revealInSettings(export, in: app), "there is no log export button")
        export.tap()
        // The row that names the file, which is also what tells the operator the
        // export happened after the share sheet has been dismissed.
        let produced = app.descendants(matching: .any).matching(identifier: "settings.logs.lastArchive").firstMatch
        // The file's name as text as well, because a `List` row is a container
        // whose accessibility shape is the system's to decide: if the identifier
        // lands somewhere that is not an element, the name is still on screen.
        let named = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ".zip")).firstMatch
        XCTAssertTrue(
            produced.waitForExistence(timeout: Self.patience) || named.exists,
            "the export produced no file",
        )
        XCTAssertTrue(
            named.waitForExistence(timeout: 5) || produced.label.contains(".zip"),
            "the export did not name the zip it made",
        )
        // And it is offered: the share sheet comes up on its own, without a
        // second tap. It is asserted and then left alone -- the first version of
        // this test swiped it away, and the swipe never came back from
        // "wait for the app to idle", which killed the test after every
        // assertion in it had already passed. Choosing a destination in that
        // sheet is a test of iOS, not of this app; the archive's contents are
        // checked outside the suite, by unzipping it from the app's container.
        XCTAssertTrue(
            app.otherElements["ActivityListView"].waitForExistence(timeout: Self.patience),
            "the export was made but nothing offered to share it",
        )
    }

    /// 关于: where it comes from, what it is, and who made it.
    func testTheAboutSectionShowsTheVersionAndBothCredits() {
        let app = launch(session: nil)
        openSettings(app)
        let source = app.buttons["settings.about.source"]
        XCTAssertTrue(revealInSettings(source, in: app), "there is no source code button")
        XCTAssertTrue(source.isEnabled, "the source code button cannot be tapped")

        let version = labelled("settings.about.version", in: app, contains: ".")
        XCTAssertTrue(version.waitForExistence(timeout: 5), "the version is not shown")
        // A version, not a specific version: the release is cut elsewhere, and a
        // test that fails on a bump is a test somebody deletes.
        XCTAssertNotNil(
            version.label.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression),
            "the version row does not show a version: \(version.label)",
        )

        // 开发者鸣谢: two names, on two rows. Not one paragraph with a line break
        // in it -- which is why the y positions are compared rather than the text.
        // The text element of each `Label`, not its symbol: a `Label` gives both
        // the same identifier, and the symbol's label is "Account".
        let shirazu = labelled("settings.credits.shirazu", in: app, contains: "ShirazuNagisa")
        let arowey = labelled("settings.credits.arowey", in: app, contains: "Arowey")
        XCTAssertTrue(revealInSettings(arowey, in: app), "the credits are missing")
        XCTAssertTrue(shirazu.exists, "the first credit is missing")
        XCTAssertTrue(shirazu.label.contains("ShirazuNagisa"), "the first credit is mislabelled: \(shirazu.label)")
        XCTAssertTrue(arowey.label.contains("Arowey"), "the second credit is mislabelled: \(arowey.label)")
        XCTAssertNotEqual(
            shirazu.frame.origin.y,
            arowey.frame.origin.y,
            "the two credits are on one line, not one per row",
        )
        // The link is asserted and not tapped. Tapping it opens Safari, and every
        // assertion after that would be about Safari.
    }

    /// Chinese-first: the settings screen follows the phone's language.
    func testTheSettingsScreenFollowsTheLanguage() {
        // The section headers, which are interface copy, in Chinese.
        let chinese = launch(session: nil, language: "zh-Hans")
        openSettings(chinese)
        expect(settingControl("settings.notify.turn-finished", in: chinese), "there is no notifications section")
        expect(chinese.staticTexts["通知"], "通知 is not on the settings screen")
        expect(chinese.staticTexts["实时活动"], "实时活动 is not on the settings screen")
        XCTAssertTrue(
            revealInSettings(chinese.staticTexts["开发者鸣谢"], in: chinese),
            "关于 is not on the settings screen",
        )
        expect(chinese.staticTexts["源代码"], "源代码 is not translated")
        // A name is not translated, in either language.
        expect(chinese.staticTexts["ShirazuNagisa"], "the first credit is missing in Chinese")
        chinese.terminate()

        // The same screen in English, so a catalogue that lost one of the two
        // languages is caught rather than the other one being taken on trust.
        let english = launch(session: nil, language: "en")
        openSettings(english)
        expect(settingControl("settings.notify.turn-finished", in: english), "there is no notifications section")
        expect(english.staticTexts["Notifications"], "the notifications section did not translate")
        expect(english.staticTexts["Live Activity"], "the live activity section did not translate")
        XCTAssertTrue(
            revealInSettings(english.staticTexts["Credits"], in: english),
            "the about section did not translate",
        )
        expect(english.staticTexts["Source code"], "the source link did not translate")
    }

    /// A first pairing downloads everything, and says how far along it is.
    ///
    /// Without the stalled mock this screen is invisible: a local host answers
    /// in milliseconds, so the whole download lives inside one runloop turn. The
    /// delay is what makes the assertion possible at all, and what it asserts is
    /// the thing that was asked for -- that the operator is shown progress
    /// rather than an empty app.
    func testAFirstPairingShowsAFullScreenDownload() {
        // A long stall, and the reason is the estimate rather than the counter.
        // The estimate exists only between one session finishing and the next --
        // `SyncProgress.remaining` refuses to guess before it has a sample -- so
        // the window this test has to catch is one session's worth of answers,
        // and at 500 ms that window is about a second wide. Measured: it was
        // missed on a loaded machine, in a suite where all 39 other tests passed.
        // 1.5 s makes the window three times wider and costs this one test eight
        // seconds.
        let app = launch(session: nil, slow: 1500, naming: false)
        XCTAssertTrue(
            app.staticTexts["firstload.title"].waitForExistence(timeout: Self.patience),
            "a first pairing downloaded the history with nothing on screen to say so",
        )
        // And it is a download, not a splash: it counts, and it says how much
        // longer. The estimate needs at least one session finished, which is
        // exactly the restraint being asserted -- a number invented before any
        // sample exists is a number that will change.
        XCTAssertTrue(
            app.staticTexts["firstload.counter"].waitForExistence(timeout: Self.patience),
            "the full-screen download showed no progress count",
        )
        XCTAssertTrue(
            app.staticTexts["firstload.eta"].waitForExistence(timeout: Self.patience),
            "the full-screen download showed no estimate",
        )
        // And it gets out of the way when it is done, handing over to the naming
        // prompt rather than sitting under it.
        dismissNamingIfPresented(app)
        XCTAssertTrue(
            app.buttons["sessions.new"].waitForExistence(timeout: Self.patience * 3),
            "the download never finished",
        )
    }

    /// A refresh reports itself in a window, with an estimate.
    ///
    /// The sheet existed and nothing presented it, so tapping refresh was a
    /// spinner in the toolbar and no idea how long the wait was.
    func testRefreshingShowsAProgressWindow() {
        let app = launch(session: nil)
        // The first download has to be finished first: the refresh button is
        // disabled while it runs, and a disabled button that does nothing would
        // fail this test for the wrong reason.
        expect(app.buttons["sessions.new"], "the session list never arrived")
        expect(app.staticTexts["demo"], "the session list is empty")

        // Slowed now, not at launch, and deliberately: the window exists to say
        // how long something is taking, so a host that answers instantly leaves
        // nothing to look at.
        Self.stallMockHost(1200)

        let refresh = app.buttons["sessions.refresh"]
        expect(refresh, "there is no way to refresh")
        refresh.tap()

        XCTAssertTrue(
            app.buttons["sync.done"].waitForExistence(timeout: Self.patience),
            "tapping refresh did not show the progress window",
        )
        // The window is the point: it says how far along, and how much longer.
        XCTAssertTrue(
            app.staticTexts["sync.counter"].waitForExistence(timeout: Self.patience),
            "the progress window showed no count",
        )
        XCTAssertTrue(
            app.staticTexts["sync.eta"].waitForExistence(timeout: Self.patience),
            "the progress window showed no estimate",
        )
        app.buttons["sync.done"].tap()
        Self.stallMockHost(0)
    }

    /// An unreachable Mac does not take away what this phone already has.
    ///
    /// The other half of the local storage: reading a conversation is entirely
    /// local once it has been synced, so a failure screen that replaces the list
    /// does not report a problem, it destroys an answer. And the phone is opened
    /// on trains, in lifts, and on the far side of a relay having a bad day.
    func testAnUnreachableMacKeepsTheStoredSessions() {
        // First: a normal launch, so there is something stored to keep.
        let first = launch(session: nil)
        expect(first.staticTexts["demo"], "the session list never synced")
        first.terminate()

        Self.setMockOffline(true)
        defer { Self.setMockOffline(false) }

        // Second: the same pairing, the same stored data, and a Mac that has
        // stopped answering.
        let app = launch(session: nil, naming: false, freshStart: false)
        XCTAssertTrue(
            app.staticTexts["demo"].waitForExistence(timeout: Self.patience),
            "an unreachable Mac hid the sessions this phone already had",
        )
        // And it says so rather than pretending everything is fine.
        XCTAssertTrue(
            app.staticTexts["sessions.error"].waitForExistence(timeout: Self.patience),
            "the app did not say the Mac was unreachable",
        )
        // But it says so quietly. The yellow banner and its Retry button were
        // reported as looking like a development build -- and the retry those
        // two words offered is already done by the read itself, by pull to
        // refresh, and by the toolbar's refresh. An error row is information;
        // the recovery lives where the operator already looks for it.
        XCTAssertFalse(
            app.buttons["Retry"].exists,
            "the list still offers a Retry control; the error must be a row, not a button",
        )

        // A refresh while unreachable must not report an all-clear. It did: the
        // pass returned without asking anything and the window said "Up to date.
        // Every conversation on this Mac is stored on this phone." -- a claim
        // about the operator's data made out of a request that was never sent.
        let refresh = app.buttons["sessions.refresh"]
        expect(refresh, "there is no way to refresh")
        refresh.tap()
        XCTAssertTrue(
            app.buttons["sync.done"].waitForExistence(timeout: Self.patience),
            "tapping refresh did not show the progress window",
        )
        XCTAssertFalse(
            app.staticTexts["Up to date"].waitForExistence(timeout: 4),
            "a refresh against an unreachable Mac claimed everything was already stored",
        )
        // The pass has finished when the window stops saying it is looking and
        // starts saying why it could not. Waiting for that is what makes the
        // second refresh below a second pass rather than a tap ignored by the
        // one still running.
        XCTAssertTrue(
            app.staticTexts["sync.problem"].waitForExistence(timeout: Self.patience),
            "the failed refresh never reported why it failed",
        )
        app.buttons["sync.done"].tap()
        XCTAssertTrue(
            app.buttons["sync.done"].waitForNonExistence(timeout: 5),
            "the progress window did not close",
        )

        // And when the Mac comes back, the list recovers through the gesture it
        // already has. Pull to refresh lands in `refreshSessions`, which opens a
        // socket when there is none -- the recovery the old Retry button did by
        // hand, now on the path the operator already uses.
        Self.setMockOffline(false)
        let pullStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let pullEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd)
        XCTAssertTrue(
            app.staticTexts["sessions.error"].waitForNonExistence(timeout: Self.patience),
            "a read that recovered left the error row on screen",
        )
    }

    // MARK: - Session detail

    func testOpeningASessionShowsTheComposer() {
        let app = launch(pending: false)
        let field = app.textFields["composer.field"]
        expect(field, "the composer is missing")

        // One button, two jobs. The running session starts with an empty field,
        // which is the stop case -- the rule DSH uses, and the rule this follows.
        expect(app.buttons["composer.stop"], "a running turn with an empty field does not offer stop")

        // Typing turns it into send, and it is refused while empty -- so the one
        // button cannot be tapped into a no-op.
        field.tap()
        field.typeText("hello")
        let send = app.buttons["composer.send"]
        expect(send, "typing did not turn the button into send")
        XCTAssertTrue(send.isEnabled, "send is disabled with text in the field")
    }

    /// A session whose workspace the host has deleted is not drawn as a
    /// workspace.
    ///
    /// The host reports two sessions: one in a workspace it has, and one in a
    /// directory it does not -- which is what a deleted workspace looks like,
    /// because deleting it removes the registry entry and leaves the session log
    /// behind. Grouping on the working directory drew both, and the deleted one
    /// was offered as somewhere to start new work.
    ///
    /// It is not gone, though, and that is deliberate: the conversation is
    /// collected under one heading of its own, because the list is the only
    /// screen that can open it. What changed is that it is no longer presented
    /// as a workspace DSH has.
    func testADeletedWorkspaceIsNotListed() {
        let app = launch(session: nil)
        expect(app.staticTexts["Mock Mac (fixture)"], "the host's name is missing")

        // The workspace the host still has is there, with its one session.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the host's own workspace is missing")

        // And the directory the host has no workspace for is not, even though a
        // session still lives in it.
        XCTAssertEqual(
            app.buttons.matching(identifier: "workspace./Users/you/projects/deleted-workspace").count,
            0,
            "a session in a deleted workspace was listed as a workspace",
        )
        // The host's second workspace holds no sessions and is drawn anyway: it
        // is on the Mac's sidebar, so it is part of the count the operator is
        // comparing.
        expect(
            app.buttons["workspace./Users/you/projects/fresh"],
            "a workspace with no sessions was left out",
        )
        // One heading for what no workspace claims, and it says what it is.
        expect(
            app.buttons["workspace.not-in-a-workspace"],
            "the session in a deleted workspace is unreachable",
        )
    }

    /// The new-session picker offers the host's workspaces, and nothing else.
    ///
    /// This is the screen the report was about: "手机app中有许多电脑端dsh已经删除的
    /// 工作区". The list below it was already filtered by the host's workspace
    /// registry; the picker was not, because it was built from the working
    /// directory of every session the host had ever listed -- and a deleted
    /// workspace leaves its session log behind, so its directory stayed on offer
    /// forever as somewhere to start new work.
    func testTheNewSessionPickerDoesNotOfferADeletedWorkspace() {
        let app = launch(session: nil)
        expect(app.buttons["sessions.new"], "the new-session button is missing")
        app.buttons["sessions.new"].tap()

        expect(
            app.staticTexts["/Users/you/projects/demo"],
            "the host's own workspace is not offered",
        )
        XCTAssertFalse(
            offersDirectory(app, "/Users/you/projects/deleted-workspace"),
            "a deleted workspace was offered as somewhere to start a session",
        )
    }

    /// A refresh reports the workspaces the host has, which is the number the
    /// operator can check against their Mac.
    ///
    /// The sheet used to say nothing about workspaces at all, so "the phone has
    /// more of them than DSH does" could only be discovered by counting rows.
    func testRefreshingReportsTheHostsWorkspaces() {
        let app = launch(session: nil)
        expect(app.buttons["sessions.refresh"], "the refresh button is missing")
        app.buttons["sessions.refresh"].tap()

        let count = app.staticTexts["sync.workspaces"]
        expect(count, "the refresh sheet does not say how many workspaces there are")
        // Two: the one holding the demo session, and the one holding none. The
        // session in a deleted workspace is not a workspace.
        XCTAssertTrue(
            labelLands(count, containing: "Workspaces: 2"),
            "the sheet reported \(count.label)",
        )
    }

    /// Whether a directory path appears anywhere the operator could tap it.
    ///
    /// Deliberately not by identifier: this has to be able to report the bug it
    /// was written for, and an identifier that does not exist yet would make it
    /// fail for the wrong reason. A path is not a localised string, so matching
    /// on the label is safe here in a way it is not for the rest of this file.
    ///
    /// Scanned by index rather than through an `NSPredicate`: a predicate is not
    /// `Sendable`, and handing one to a query is a data-race error under Swift
    /// 6's region isolation.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - path: the directory to look for.
    /// - Returns: whether it is on screen.
    private func offersDirectory(_ app: XCUIApplication, _ path: String) -> Bool {
        if app.buttons.allElementsBoundByIndex.contains(where: { $0.label.contains(path) }) {
            return true
        }
        return app.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(path) }
    }

    /// The figures the screen already has are not erased by a read that fails.
    ///
    /// Reported from the phone: "刚点进去一个会话，然后该会话的标题、正在使用的
    /// 模型、上下文用量显示全部消失", repaired by leaving the session and coming
    /// back or by leaving the app and coming back -- both of which are another
    /// read. What made them vanish was the *second* read of the same screen: the
    /// cache drew the figures, and the host's answer was assigned over them
    /// whether it had anything in it or not.
    func testTheFiguresSurviveAReadThatFails() {
        let app = launch(pending: false)
        let model = app.buttons["composer.model"]
        let context = app.buttons["composer.context"]
        expect(model, "the model is not shown above the composer")
        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context figure never loaded: \(context.label)",
        )
        XCTAssertTrue(
            labelLands(model, containing: "deepseek-flash"),
            "the model never loaded: \(model.label)",
        )

        // The host stops answering `session.stats`, the way a phone link does.
        Self.failMockHost("session.stats")
        // Away and back, which is what the operator does to repair it and what
        // makes this screen re-read everything.
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context figure was erased by a failed read: \(context.label)",
        )
        XCTAssertTrue(
            labelLands(model, containing: "deepseek-flash"),
            "the model was erased by a failed read: \(model.label)",
        )
        XCTAssertEqual(
            app.navigationBars["Mock session"].exists,
            true,
            "the session's title was erased by a failed read",
        )
    }

    /// An answer that carries less than the last one does not take anything away.
    ///
    /// The other half of the same report, and the likelier half: the host
    /// answers every field from its own projection, so a session whose agent is
    /// cold answers with a token meter and no title, no model and no context
    /// pressure. That reply is delivered successfully, which is exactly why the
    /// screen has to merge it rather than take it as the truth.
    func testTheFiguresSurviveAColdAnswer() {
        let app = launch(pending: false)
        let model = app.buttons["composer.model"]
        let context = app.buttons["composer.context"]
        expect(model, "the model is not shown above the composer")
        XCTAssertTrue(labelLands(context, containing: "35"), "the context figure never loaded")
        XCTAssertEqual(app.navigationBars["Mock session"].exists, true, "the title never loaded")

        // The session goes cold: the host still answers, with less.
        Self.setMockStatsCold(true)
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "a colder answer took the context figure away: \(context.label)",
        )
        XCTAssertTrue(
            labelLands(model, containing: "deepseek-flash"),
            "a colder answer took the model away: \(model.label)",
        )
        XCTAssertEqual(
            app.navigationBars["Mock session"].exists,
            true,
            "a colder answer took the session's title away",
        )
    }

    /// The three figures above the field, each of which is a control.
    func testTheComposerBarShowsTheModelContextAndCommands() {
        let app = launch()
        expect(app.buttons["composer.model"], "the model is not shown above the composer")
        expect(app.buttons["composer.context"], "the context figure is not shown above the composer")
        expect(app.buttons["composer.commands"], "the command button is not shown above the composer")

        // The figure is the host's number, not a placeholder. Asserted on the
        // button's label: setting one makes the button a single accessibility
        // element, so its inner Text is not a queryable child.
        let context = app.buttons["composer.context"]
        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context percentage is not the host's: \(context.label)",
        )
    }

    /// A turn's row, wherever it is in the tree.
    ///
    /// Found by identifier and by `any` descendant, deliberately. A turn row is
    /// a plain `HStack` of a glyph, some text and a count -- it is not a control
    /// any more, so it is not a button, and which element type SwiftUI gives a
    /// row of loose `Text`s is not something this test should depend on.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - turn: the turn number.
    /// - Returns: the row.
    private func turnRow(_ app: XCUIApplication, _ turn: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "turn.\(turn)").firstMatch
    }

    func testTheConversationRendersMessagesAndFailures() {
        // Nothing pending: the two interaction cards fill most of a phone screen,
        // and this test is about the conversation underneath them.
        let app = launch(pending: false)
        expect(app.staticTexts["Refactor the parser and run the tests."], "the user's message is missing")
        // The turn's one message is its answer, and it is on screen without a
        // tap. The transport no longer sends the steps that led to it.
        expect(
            app.staticTexts["The parser is now two files."],
            "the turn's answer is not on screen without a tap",
        )
        // A turn that ended badly still says so, on its own row: the state is the
        // one thing a monitoring app exists to report, and the row carries it
        // even when there is an answer under it.
        XCTAssertTrue(
            reveal(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Unfinished after "))
                    .firstMatch,
                in: app,
            ),
            "a turn that ended badly was not reported as unfinished",
        )
        // The turn that ended with *nothing to show* is the one the failure card
        // belongs to, and it is on screen: without it, that turn is a bare row
        // saying "未完成" over an empty space, and the operator is left to guess
        // whether the model ever ran.
        expect(
            app.staticTexts["The turn ended without a response"],
            "a turn that ended without a response was not surfaced",
        )
        // And the turn that ended badly *after* answering keeps its answer: a
        // notice drawn over it would take away the only thing that turn managed
        // to say, and the row's own warning already reports the state.
        expect(
            app.staticTexts["Two files changed, and it still fails."],
            "a failure notice replaced a turn's answer",
        )
    }

    /// The step count comes from the markers, not from the messages.
    ///
    /// The reported shape, and the reason the count is derived rather than
    /// counted off the items: the host sends one tiny `step/start` per step and
    /// only the **last** `assistant/message` of a turn. Turn 1 below takes three
    /// steps and arrives with one message, so a row that counted messages would
    /// read "1 steps" over a turn that took three -- and the count is the only
    /// part of a step the transport still sends.
    func testATurnRowCountsItsStepsFromTheMarkers() {
        let app = launch(pending: false)
        // Waited for first: without this the assertions below pass on a screen
        // that has not drawn yet, which is a test that proves nothing.
        expect(app.staticTexts["Refactor the parser and run the tests."], "the conversation never arrived")

        let count = app.staticTexts["3 steps"]
        XCTAssertTrue(reveal(count, in: app), "the turn's step count does not match its markers")
        // And the row is a finished one, not a failure and not still running.
        XCTAssertTrue(
            app.staticTexts["The parser is now two files."].exists,
            "the counted turn's answer is missing",
        )
    }

    /// A turn is not a disclosure any more, and tapping it reveals nothing.
    ///
    /// The old screen folded a turn's steps behind its summary bar, and the
    /// transport change took the steps away: the host sends the prompt, the
    /// turn's markers and the model's last message, and none of the narration in
    /// between. There is nothing left to expand, so the row must not offer to.
    ///
    /// The text asserted on is a step of the running turn under the old
    /// fixture, which was the shape of the thing that is no longer sent at all.
    /// The row is tapped rather than merely inspected, because "the row is not
    /// expandable" is a claim about what a tap does -- and a `DisclosureGroup`
    /// looks exactly like a plain row until someone touches it.
    func testATurnRowIsNotExpandable() {
        let app = launch(pending: false)
        // Waited for first: the row is looked up by identifier, and an identifier
        // query finds nothing at all on a screen that has not drawn.
        let row = turnRow(app, 1)
        XCTAssertTrue(reveal(row, in: app), "the turn row is missing, so nothing can be tapped")

        // The step's text is not there to begin with, and that is the first half
        // of the claim: it is not merely hidden behind a tap.
        XCTAssertFalse(
            app.staticTexts["Running the tests now."].waitForExistence(timeout: 2),
            "a step's text is in the tree, so the steps were not actually dropped",
        )

        // Tapped, as an operator would. A row that was still a `DisclosureGroup`
        // would now be open.
        row.tap()

        XCTAssertFalse(
            app.staticTexts["Running the tests now."].waitForExistence(timeout: 2),
            "tapping the turn revealed a step, so the row is still expandable",
        )
        // And nothing else was revealed either: a row that still offered a
        // disclosure would be a control, and this one is not one any more.
        XCTAssertEqual(
            app.buttons.matching(identifier: "turn.1").count,
            0,
            "the turn row is still a control",
        )
        // The answer that is there stays there, so the tap did not swap anything.
        XCTAssertTrue(
            app.staticTexts["The parser is now two files."].exists,
            "tapping the turn row changed what is on screen",
        )
    }

    /// A turn that is still working says so, and does not claim to have finished.
    ///
    /// The reported bug, exactly. A running turn has no `turn/end`, and the
    /// reader invented an end time from its last record -- so a live turn was
    /// drawn as "已完成，用时 10 秒", with the seconds measuring the age of the
    /// newest message.
    func testARunningTurnSaysItIsRunning() {
        // With nothing pending, so the conversation has the screen. The two
        // interaction cards take most of it, and they are asserted on by their
        // own tests.
        let app = launch(pending: false)

        // The state is written on the row, found by its label: the identifier
        // belongs to the row and the state belongs to the text inside it, which
        // is where a reader finds it too.
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "no turn is reported as running")

        // Turn 1 did end, and still reads as finished -- so the fix is not just
        // "everything says running".
        let finished = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Completed in "))
            .firstMatch
        XCTAssertTrue(reveal(finished, in: app), "no turn is reported as completed")
    }

    /// The running wording, in the language it was asked for in.
    ///
    /// "深度求索中，用时 %@" is the operator's string, word for word, and the
    /// running row is the one thing on this screen they want to read at a
    /// glance. Asserted in Chinese because that is where it was asked for; the
    /// English pass is asserted in the test above.
    func testTheRunningRowIsWordedAsAskedInChinese() {
        let app = launch(language: "zh-Hans", pending: false)
        // The conversation has to have landed, or this passes on a screen with
        // nothing on it.
        XCTAssertTrue(
            app.staticTexts["Refactor the parser and run the tests."]
                .waitForExistence(timeout: Self.patience),
            "the conversation never arrived",
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "深度求索中，用时 "))
                .firstMatch
                .waitForExistence(timeout: Self.patience),
            "the running row does not read \"深度求索中，用时 \" in Chinese",
        )
        // And the finished row is the wording that was already correct.
        XCTAssertTrue(
            reveal(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "已完成，用时 "))
                    .firstMatch,
                in: app,
            ),
            "the finished row does not read \"已完成，用时 \" in Chinese",
        )
    }

    /// The clock on a running turn moves.
    ///
    /// Separate from the assertion above because it is a different claim: that
    /// the elapsed time is the turn's own start measured against now, rather
    /// than a number computed once when the screen was drawn. The host is not
    /// asked anything, so this is the only evidence that the phone is doing the
    /// arithmetic itself.
    func testARunningTurnsClockMoves() {
        let app = launch(pending: false)
        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "no turn is reported as running")
        let first = running.label

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", first),
            object: running,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [moved], timeout: 10),
            .completed,
            "the running turn's clock did not move past \(first)",
        )
    }

    /// A running turn shows no answer at all, and hides nothing.
    ///
    /// Both halves of the request, and they are opposites: a half-written answer
    /// must not be presented as a conclusion, and nothing may be lost behind a
    /// tap that no longer exists to reveal it.
    ///
    /// Since the transport change the two are the same fact -- the host does not
    /// send a running turn's partial answer, so there is nothing to show and
    /// nothing to fold -- but they are asserted separately because a view that
    /// started drawing the partial answer again would fail one and pass the
    /// other.
    func testARunningTurnShowsNoAnswer() {
        let app = launch(pending: false)
        // Waited for first: without this the assertions below pass on a screen
        // that has not drawn yet, which is a test that proves nothing.
        expect(app.staticTexts["And run the whole suite."], "the running turn's prompt is missing")

        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        // Waited for: the row is what the next assertion measures against, and a
        // query that matches nothing returns a frame of zeroes rather than
        // failing.
        expect(running, "the running turn is not reported as running")

        // Its count is still shown, because the markers are still sent: a
        // running turn with nothing on its row reads as a turn that has stalled.
        XCTAssertTrue(
            app.staticTexts["2 steps"].exists,
            "the running turn's step count is missing",
        )

        // Nothing has leaked out under its row. The answer above it belongs to
        // the turn that finished -- the prompt and the row are all the running
        // turn has, because the transport does not send a partial answer -- and
        // the narration of the old fixture is not here at all.
        XCTAssertLessThan(
            app.staticTexts["Two files changed, and it still fails."].frame.minY,
            running.frame.minY,
            "the running turn's row is not below the turn that came before it",
        )
        // The prompt is above the row, and the row is the last thing in the
        // turn: nothing of the running turn's own is under it, because the
        // transport sends nothing for a turn that has not ended.
        XCTAssertLessThan(
            app.staticTexts["And run the whole suite."].frame.minY,
            running.frame.minY,
            "the running turn's prompt is not above its row",
        )
        XCTAssertFalse(
            app.staticTexts["Running the tests now."].exists,
            "a step that the transport no longer sends is on screen",
        )
    }

    /// The refresh control in the conversation, which is the way back to a
    /// session that has gone quiet without hunting for a pull gesture.
    ///
    /// It calls the same reload the pull-to-refresh does. The assertion is that
    /// it exists, that it is usable once the screen has landed, and that tapping
    /// it loads the conversation again rather than emptying it -- a reload that
    /// reported failure would draw the failure card over what was on screen.
    func testTheConversationCanBeRefreshed() {
        let app = launch(pending: false)
        // The screen has to have landed first: the button is disabled while a
        // reload is already in flight, and a disabled button that does nothing
        // would fail this for the wrong reason.
        expect(app.staticTexts["Refactor the parser and run the tests."], "the conversation never arrived")

        let refresh = app.buttons["session.refresh"]
        expect(refresh, "there is no way to refresh the conversation")
        XCTAssertTrue(refresh.isEnabled, "the refresh button is disabled on a landed screen")
        refresh.tap()

        // It comes back, and it comes back usable: the spinner it shows while it
        // works must not leave the control dead afterwards.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: refresh,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [ready], timeout: Self.patience),
            .completed,
            "the refresh button never became usable again",
        )
        XCTAssertTrue(
            app.buttons["session.refresh"].exists,
            "the refresh button vanished while it was working",
        )

        // And the conversation is still the conversation. A reload that lost it
        // is what "pull to refresh loses my history" was, in the same code path.
        XCTAssertTrue(
            reveal(app.staticTexts["Refactor the parser and run the tests."], in: app),
            "reloading the conversation emptied it",
        )
        XCTAssertFalse(
            app.staticTexts["Could not load the conversation"].exists,
            "reloading the conversation reported a failure",
        )
    }

    /// The context figure opens the breakdown it is computed from.
    ///
    /// This replaces a test for a Usage *tab*. The tab is gone: the figure lives
    /// above the field now, so the detail is one tap from the conversation
    /// instead of a screen swap away from it.
    func testTheContextFigureOpensItsBreakdown() {
        let app = launch()
        let context = app.buttons["composer.context"]
        expect(context, "the context figure is missing")
        XCTAssertTrue(
            labelLands(context, containing: "35"),
            "the context percentage is not the host's: \(context.label)",
        )
        context.tap()

        // The window and the composition come from the host's frame, so their
        // being on screen is what proves the popover is wired to it.
        expect(app.staticTexts["Window"], "the window size is not in the breakdown")
        expect(app.staticTexts["Pressure"], "the pressure figure is not in the breakdown")
        expect(app.staticTexts["Messages"], "the token breakdown is not in the popover")
    }

    /// The command button puts a command in the field rather than sending it.
    func testTheCommandButtonDraftsACommand() {
        let app = launch()
        let commands = app.buttons["composer.commands"]
        expect(commands, "the command button is missing")
        commands.tap()

        let goal = app.buttons["command.goal"]
        expect(goal, "the command list did not open")
        goal.tap()

        // Did the action run at all? The list closes only from inside the
        // button, so a list still on screen means the tap never reached it --
        // which is a different fault from a command that ran and was lost.
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !goal.exists },
            object: nil,
        )
        let outcome = XCTWaiter().wait(for: [closed], timeout: 5)
        XCTAssertEqual(outcome, .completed, "the tap did not reach the command row")

        // Drafted, not sent: a goal needs text after the slash, and firing it
        // blank would send the agent an empty instruction.
        let field = app.textFields["composer.field"]
        expect(field, "the composer is missing")
        // Polled rather than read once: the sheet leaves with an animation and
        // the field is not updated until it has gone, so a single read races it
        // and reports the placeholder as if nothing had been drafted.
        let drafted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in (field.value as? String) == "/goal " },
            object: nil,
        )
        _ = XCTWaiter().wait(for: [drafted], timeout: 10)
        XCTAssertEqual(field.value as? String, "/goal ", "the command was not drafted into the field")
    }

    // MARK: - Interactions

    func testAPendingApprovalOffersExactlyTwoOutcomes() {
        // Chinese, because the tool identifier is the thing on this card that
        // the app has to name: `write_file` is protocol data, and an operator
        // reading 请求执行 write_file is reading the host's vocabulary rather
        // than the app's.
        let app = launch(language: "zh-Hans")
        expect(app.buttons["approval.allowOnce"], "there is no way to allow")
        expect(app.buttons["approval.reject"], "there is no way to reject")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "写入文件"))
                .firstMatch.waitForExistence(timeout: Self.patience),
            "the approval card still shows the raw tool identifier",
        )
        // There is deliberately no "always allow": a grant that outlives the
        // request it was given for is a permission change, and those belong in
        // the permission picker where they are visible and reversible.
        XCTAssertEqual(
            app.buttons.matching(identifier: "approval.allowAlways").count,
            0,
            "an unconditional grant appeared",
        )
    }

    func testAQuestionBatchIsRefusedUntilItIsComplete() {
        let app = launch()
        let submit = app.buttons["question.submit"]
        expect(submit, "the submit button is missing")
        // The batch has a single-option question, which is pre-selected, and a
        // multi-option one, which is not. Submitting half a batch would leave
        // the agent waiting on the rest.
        XCTAssertFalse(submit.isEnabled, "an incomplete batch could be submitted")
        // The option's button label includes its description, so the visible
        // text is the stable handle.
        app.staticTexts["Migrate in place"].tap()
        XCTAssertTrue(submit.isEnabled, "the batch could not be completed")
    }

    func testASentMessageAppearsInTheConversation() {
        // The half of the loop nothing checked: sending is not the same as the
        // message showing up. Before this, it did not -- the app never reloaded
        // the conversation after a send, so the operator's own words were absent
        // until a pull-to-refresh.
        let app = launch()
        let field = app.textFields["composer.field"]
        expect(field, "the composer is missing")
        field.tap()
        field.typeText("does this reach the agent")

        let send = app.buttons["composer.send"]
        expect(send, "there is no way to send")
        XCTAssertTrue(send.isEnabled, "send stayed disabled with text in the field")
        send.tap()

        // The composer must have emptied, or the text being found proves nothing:
        // a query for static text also matches a field still holding the words,
        // which is exactly how an earlier version of this test passed with the
        // reload removed.
        // Found is not enough, and a plain subscript is not even usable: SwiftUI
        // leaves the typed text in the accessibility tree after the field clears,
        // so several elements carry this label. The first two versions of this
        // test passed with the reload removed for exactly that reason -- the
        // words were real, they were just still sitting where they had been
        // typed. A conversation bubble is the one above the composer.
        // First: did the send succeed? The composer clears only on success and is
        // refilled on failure, so its value says which branch ran -- and the two
        // produce the same visible symptom ("the text is still here").
        let composerField = app.textFields["composer.field"]
        expect(composerField, "the composer vanished")
        XCTAssertEqual(
            composerField.value as? String,
            "Ask your agent…",
            "the composer still holds the text, so the send did not succeed",
        )

        // Scroll until it is actually on screen. The conversation is longer than
        // the display and a new message lands at the bottom of it, so its frame
        // sits below the composer until scrolled into view -- which reads
        // identically to the message being absent. A fixed number of swipes is a
        // guess about how long the conversation is.
        let composer = app.textFields["composer.field"]
        // By label, not by identifier. `matching(identifier:)` reads the
        // accessibility *identifier*, and a message bubble sets its text as the
        // accessibility *label* -- so this query matched nothing, ever, and the
        // failure said "0 elements carry the text" while the text was on screen.
        let candidates = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "does this reach the agent"),
        )
        var inConversation: XCUIElement?
        for _ in 0..<8 {
            inConversation = (0..<candidates.count)
                .map { candidates.element(boundBy: $0) }
                .first { $0.frame.maxY < composer.frame.minY }
            if inConversation != nil { break }
            app.swipeUp()
        }
        XCTAssertNotNil(
            inConversation,
            "the message never reached the conversation (\(candidates.count) elements carry the text, none above the composer)\nHIERARCHY-START\n\(app.debugDescription)\nHIERARCHY-END",
        )
        XCTAssertEqual(composer.value as? String, "Ask your agent…", "the composer never emptied")
    }

    /// A running turn's clock, when the host's clock is ahead of the phone's.
    ///
    /// The start is the host's number and `now` is the phone's, so the two
    /// disagreeing is ordinary -- a Mac whose clock drifted, a phone that has not
    /// synced. Subtracting them gave a negative duration, and the row read
    /// "DeepSeeking for -4 s", which is not a time anybody can act on. The
    /// clamp is the kit's own rule (``ConversationTurn/elapsed(asOf:)``), which
    /// the view was not using.
    func testARunningTurnsClockIsNotNegativeWhenTheHostsClockIsAhead() {
        // Ten minutes ahead: far enough that no part of the fixture can be in the
        // past by accident, and short enough that the turn is still running.
        let app = launch(pending: false, skew: 600_000)
        // The conversation has to have landed, or this passes on an empty screen.
        expect(app.staticTexts["And run the whole suite."], "the running turn's prompt is missing")

        let running = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "DeepSeeking for "))
            .firstMatch
        expect(running, "no turn is reported as running")
        XCTAssertFalse(
            running.label.contains("-"),
            "a running turn reports a negative duration: \(running.label)",
        )
        // And it says the honest thing rather than nothing: the phone cannot know
        // how long a turn started in the future has been running.
        XCTAssertEqual(
            running.label,
            "DeepSeeking for 0 s",
            "the running row does not clamp a start the phone has not reached",
        )
    }

    /// A page too large to deliver is asked for again smaller, not given up on.
    ///
    /// The host's `RESPONSE_TOO_LARGE` is the one failure whose answer is a
    /// different request: the page was real and the socket could not carry it.
    /// Before this the app reported it, so a conversation whose history is long
    /// enough -- which is exactly the conversation somebody opens the app to
    /// read -- showed "Could not load the conversation" and nothing else.
    func testAnAnswerTooLargeToDeliverIsAskedForAgainSmaller() {
        // The host refuses the app's usual 200-message page and answers a small
        // one, which is what the real host does at its own size limit.
        let app = launch(pending: false, pageLimit: 50)

        expect(
            app.staticTexts["Refactor the parser and run the tests."],
            "the conversation never arrived: a page too large to deliver was not re-asked for",
        )
        XCTAssertFalse(
            app.staticTexts["Could not load the conversation"].exists,
            "a too-large answer was reported as a failure instead of being re-asked",
        )
        // And asking for less is a *request*, not a new socket: tearing the
        // connection down over an answer the host already sent costs a handshake
        // and re-subscribes every listener.
        XCTAssertEqual(
            Self.mockConnections(),
            1,
            "a too-large answer cost a fresh connection",
        )
    }

    /// Make the mock host's session report itself as stopped, or running again.
    ///
    /// - Parameter running: whether it is running.
    private static func setMockSessionRunning(_ running: Bool) {
        guard let url = URL(string: "http://127.0.0.1:19395/session?running=\(running ? 1 : 0)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// The Live Activity survives the moment everything finishes.
    ///
    /// The finished card draws the words "every session has finished" — and any
    /// `LocalizedStringKey` text (`Text("…")`) aborts the widget extension when
    /// WidgetKit archives the view to hand it to the process that draws a Live
    /// Activity, because stripping SwiftUI's localisable-segment attribute out of
    /// the archived string throws inside `NSAttributedString`. The file that
    /// documents this fixed it everywhere except these two strings, and the
    /// running card never draws them: the finished state is only ever reached by
    /// *updating* an activity that was started for a session that was running.
    ///
    /// XCTest fails the test itself when the extension aborts — "Critical process
    /// DSH-Mizar-LiveActivity crashed" — which is the assertion here.
    func testTheLiveActivitySurvivesEverythingFinishing() {
        let app = launch(session: nil, pending: false)
        expect(app.buttons["sessions.refresh"], "the session list never arrived")

        // Nothing is running any more, which is what the next refresh reports.
        Self.setMockSessionRunning(false)
        app.buttons["sessions.refresh"].tap()

        // A full pass over the sessions, which is where the app decides what the
        // activity should show. Waited for by the control it disables — first
        // disabled, then enabled again, because the refresh starts from a `Task`
        // and a single "is it enabled" read can beat it to the screen.
        let refresh = app.buttons["sessions.refresh"]
        let busy = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: refresh,
        )
        _ = XCTWaiter().wait(for: [busy], timeout: 5)
        let settle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: refresh,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [settle], timeout: Self.patience),
            .completed,
            "the refresh never finished",
        )
        let done = app.buttons["sync.done"]
        if done.exists { done.tap() }

        // The app is still here, with its list. A crashed widget takes the
        // activity down rather than the app, so this alone would not catch it —
        // XCTest's own "Critical process DSH-Mizar-LiveActivity crashed" is the
        // assertion this test is really making.
        XCTAssertTrue(
            app.buttons["workspace./Users/you/projects/demo"].waitForExistence(timeout: Self.patience),
            "the session list was lost",
        )
    }

    /// The refresh that runs once the app is off screen.
    ///
    /// Half of the Live Activity happens with no screen to look at: the app is
    /// backgrounded, and while it is off screen it has to re-read the session
    /// list and the running session's page, or the island only ever knows what
    /// was true when the app was last open. The assertion is the mock host's own
    /// count of what it was asked -- a request made with no screen cannot be
    /// seen on one, and the count is a fact about the wire rather than about
    /// either process's opinion of itself.
    ///
    /// It is the app's behaviour being measured, not the simulator's: the
    /// assertion the app takes on the way out is what keeps the process alive
    /// long enough to make the request at all. Measured by hand on this machine
    /// with `log stream` as well, where the app's own line names the state it was
    /// in when it updated the activity, and read "background".
    ///
    /// What is deliberately not asserted is that the activity's *content*
    /// changed. That needs the host to change its answer between the moment the
    /// app leaves the screen and the moment the refresh reads it, and the only
    /// hand on that dial is the test's own HTTP call -- made from the test
    /// runner, at a moment the app does not coordinate with. The content half is
    /// measured by hand in the report, not faked here.
    func testBackgroundingRefreshesTheSessionListAndTheRunningSession() {
        // The session list rather than a conversation: this is about what the
        // app does once it is off screen, and the screen it was on is beside the
        // point. The launch's first download is what puts the running turn in
        // the cache the refresh re-reads.
        let app = launch(session: nil, running: true)
        expect(app.buttons["sessions.refresh"], "the app never came up")
        // The launch's own reads are not what this measures. They finish in a
        // fraction of a second against this host, and the wait is long enough
        // that a straggler cannot be counted as the background refresh, while
        // still being far shorter than the test's patience.
        Thread.sleep(forTimeInterval: 3)
        _ = Self.mockLoads()

        XCUIDevice.shared.press(.home)

        // Polled rather than waited on once: the app is suspended in milliseconds
        // when it has nothing to do, and the assertion it takes on the way out
        // is what gives it the time. A single read of the counts after a fixed
        // sleep would be an assertion about the simulator's scheduler.
        var counts: [String: Int] = [:]
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            counts = Self.mockMethodCounts()
            if (counts["session.list"] ?? 0) >= 1, (counts["session.messages"] ?? 0) >= 1 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Reactivated before the assertions so a failure leaves the app on
        // screen for the next test rather than behind the home screen.
        app.activate()

        XCTAssertGreaterThanOrEqual(
            counts["session.list"] ?? 0,
            1,
            "the app was backgrounded and never re-read the session list",
        )
        XCTAssertGreaterThanOrEqual(
            counts["session.messages"] ?? 0,
            1,
            "the running session's page was not re-read off screen",
        )
    }

    /// A refusal the host chose to send does not rebuild the socket.
    ///
    /// `session.stats` is re-read on every reload, so a host-side failure there
    /// is the ordinary shape of "this one read did not work". Every failure used
    /// to reconnect -- a WebSocket, a handshake and a re-subscription -- and then
    /// ask the same question again, which the same host answered the same way.
    func testAHostSideRefusalDoesNotRebuildTheConnection() {
        let app = launch(pending: false)
        // The screen has to have landed: the reads the launch itself makes are
        // what the count below is measured from.
        expect(app.staticTexts["Refactor the parser and run the tests."], "the conversation never arrived")
        XCTAssertEqual(Self.mockConnections(), 1, "the launch opened more than one connection")

        // From here on the host refuses one method and answers everything else.
        Self.failMockHost("session.stats")
        let refresh = app.buttons["session.refresh"]
        expect(refresh, "there is no way to refresh the conversation")
        refresh.tap()

        // Wait for the reload to finish, so the count is not read mid-flight.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: refresh,
        )
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: Self.patience), .completed)

        XCTAssertEqual(
            Self.mockConnections(),
            1,
            "a refusal the host sent over a working socket tore the connection down",
        )
        // The conversation is still the conversation: nothing about this failure
        // was the connection's business.
        XCTAssertTrue(
            reveal(app.staticTexts["Refactor the parser and run the tests."], in: app),
            "a refused usage read emptied the conversation",
        )
    }

    /// What belongs to one session does not follow the operator to the next.
    ///
    /// One view draws every session, and the parts of it that were not tagged
    /// with the session they were read for are drawn for whichever session is
    /// opened next: the composer kept the text typed for the last one — which
    /// could then be sent to the wrong agent — and the conversation kept "this
    /// history has been paged to its end", so the new session's older messages
    /// could not be asked for at all.
    ///
    /// Asserted where both columns are on screen at once, which is where the
    /// detail view survives a change of selection. On a phone the conversation is
    /// pushed over the list and popping it destroys the view — and the state with
    /// it — so there is nothing here to break, and a test that pretended
    /// otherwise would pass with the bug present.
    func testSwitchingSessionsDoesNotCarryTheOtherOnesState() throws {
        // Nothing running, so no Live Activity is posted: this is a test about
        // two conversations, and the widget extension is a second process that
        // has nothing to do with either of them.
        let app = launch(session: nil, pending: false, running: false)

        // The first session, opened the way an operator opens one: the workspace
        // it is filed under, then the row.
        // By identifier, never by label: the workspace's own title is interface
        // copy and follows the device's language, while a session's title is the
        // host's data and does not.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the host's first workspace is missing")
        let first = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(
            expand(demo, revealing: first),
            "the first session never appeared under its workspace",
        )
        first.tap()
        let field = app.textFields["composer.field"]
        expect(field, "the first conversation never opened")

        // Something typed and never sent, and a history that has been paged to
        // its end, so the row that asks for older messages goes away by itself.
        field.tap()
        field.typeText("half a thought for the first session")
        XCTAssertEqual(field.value as? String, "half a thought for the first session")

        let loadOlder = app.buttons["conversation.loadOlder"]
        let exhausted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: loadOlder,
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [exhausted], timeout: Self.patience),
            .completed,
            "the first session never reported its history as paged to the end",
        )

        // Back to the list. A phone pushes the conversation over it; an iPad
        // keeps both columns, so there is nothing to come back from -- and both
        // are the app's real layouts, and the subject of the state is the same.
        let back = app.navigationBars.buttons["BackButton"]
        if back.exists { back.tap() }
        expect(demo, "the session list never came back")

        // The second session, which has a conversation of its own — different
        // prompt, different answer, and older history still to fetch.
        let orphanGroup = app.buttons["workspace.not-in-a-workspace"]
        let orphanRow = sessionRow(in: app, titled: "Orphan session", in: "deleted-workspace")
        XCTAssertTrue(
            expand(orphanGroup, revealing: orphanRow),
            "the second session never appeared under its heading",
        )
        orphanRow.tap()
        expect(app.textFields["composer.field"], "the second conversation never opened")

        XCTAssertEqual(
            app.textFields["composer.field"].value as? String,
            "Ask your agent…",
            "the first session's draft followed the operator into the second",
        )
        XCTAssertTrue(
            app.staticTexts["Older history from the other session."]
                .waitForExistence(timeout: Self.patience),
            "the second session's older page was never asked for: its paging state belonged to the first session",
        )
    }

    /// The selection bar is put away inside a conversation, and comes back.
    ///
    /// It chooses between the two screens -- the conversations and the settings
    /// -- and a conversation is not a third one: it is somewhere inside the
    /// first. Leaving it up put a second row of controls under a composer that
    /// already has two of its own.
    ///
    /// Opened by tapping, not by `-mizarSelectSession`. The launch argument sets
    /// the selection directly, so a test that used it would be measuring a
    /// screen the operator cannot reach that way.
    func testTheSelectionBarIsPutAwayInAConversation() {
        let app = launch(session: nil)
        expect(app.staticTexts["demo"], "the session list never arrived")
        // There, where it belongs: this is the screen it chooses for.
        XCTAssertEqual(app.tabBars.buttons.count, 2, "the selection bar is not on the session list")

        app.staticTexts["demo"].tap()
        let session = app.staticTexts["Mock session"]
        expect(session, "the session row never appeared")
        session.tap()
        expect(app.textFields["composer.field"], "the conversation never opened")

        XCTAssertEqual(app.tabBars.buttons.count, 0, "the selection bar is still in the conversation")

        // And it comes back on the way out, rather than being gone for good.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["demo"].waitForExistence(timeout: Self.patience),
            "the conversation did not close",
        )
        XCTAssertEqual(
            app.tabBars.buttons.count,
            2,
            "the selection bar did not come back on the session list",
        )
    }


    // MARK: - Model and permission switching

    func testTheModelPickerListsTheHostsProviders() {
        let app = launch()
        let opener = app.buttons["composer.model"]
        expect(opener, "there is no way to change the model")
        opener.tap()

        // Rows are buttons, not static text: the row carries an identifier, and
        // an identifier makes the row one accessibility element with its label
        // and description merged, so the inner Text is not separately visible.
        expect(app.buttons["model.row.deepseek-flash"], "the first model is missing")
        expect(app.buttons["model.row.deepseek-v4-pro"], "the second model is missing")
        // The provider heading is a standalone element, so it is still text.
        expect(app.staticTexts["DeepSeek"], "the provider is missing from the picker")

        // A provider that could not be listed is shown rather than hidden: its
        // models being absent is information. It sits below the models.
        app.swipeUp()
        expect(app.staticTexts["OpenRouter"], "an unavailable provider was hidden")
    }

    func testChoosingAModelRevealsItsReasoningLevels() {
        let app = launch()
        app.buttons["composer.model"].tap()
        let model = app.buttons["model.row.deepseek-flash"]
        expect(model, "the model row is missing")
        model.tap()
        // The four levels the host actually offers. The picker must not invent
        // its own, and must not offer a level the model rejects.
        expect(app.buttons["Off"], "the reasoning levels were not revealed")
        expect(app.buttons["Max"], "the highest reasoning level is missing")
    }

    func testThePermissionPickerWarnsBeforeFullAccess() {
        let app = launch()
        let opener = app.buttons["session.permissions"]
        expect(opener, "there is no way to change the permission preset")
        opener.tap()
        expect(app.buttons["permission.row.workspace-write"], "the presets are missing")

        // Only full access asks twice. A preset that grants unrestricted access
        // to the machine should not be one tap away.
        app.buttons["permission.row.danger-full-access"].tap()
        expect(app.staticTexts["Allow full access?"], "full access was granted without confirmation")
    }

    /// A model switch the host refused does not stay on screen as applied.
    ///
    /// The choice was written down *before* the call and the call's failure was
    /// swallowed, and the host has no "what is this session using" read on this
    /// side of the protocol -- so the tick drawn for a refused switch was the
    /// only answer there was, and it was wrong for the life of the process. Every
    /// `session.model.set` on the fixture fails to decode, which is why nothing
    /// noticed.
    ///
    /// Both halves are asserted, because either one alone is a smaller bug than
    /// the one reported: the picker goes back to the model that is actually in
    /// force, and it says why the switch did not happen.
    func testARefusedModelSwitchGoesBackAndSaysSo() {
        // Opened by tapping rather than by `-mizarSelectSession`. That argument
        // selects the host's *first* session, which is a different session the
        // moment the fixture's list changes, and this test is about one named
        // session's model. Tapping the row is also the path an operator takes.
        let app = launch(session: nil, pending: false)
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the host's first workspace is missing")
        var opened = false
        for _ in 0..<3 where !opened {
            let row = sessionRow(in: app, titled: "Mock session", in: "demo")
            _ = expand(demo, revealing: row)
            guard row.exists, row.isHittable else { continue }
            row.tap()
            opened = app.buttons["composer.model"].waitForExistence(timeout: 10)
        }
        XCTAssertTrue(opened, "the conversation never opened")

        // Re-queried rather than held in a `let`: a sheet coming and going
        // rebuilds the hierarchy under it, and an element captured before that is
        // a stale reference the second tap goes nowhere with.
        app.buttons["composer.model"].tap()
        XCTAssertTrue(
            app.buttons["model.row.deepseek-flash"].waitForExistence(timeout: Self.patience),
            "the picker did not open",
        )

        // A switch the host takes, so that the refusal below is a change from
        // something and the value it goes back to is one the app has agreed with
        // rather than one a test assumed. `deepseek-flash` has reasoning levels,
        // so this commits `Off`, and a taken switch closes the picker.
        app.buttons["model.row.deepseek-flash"].tap()
        expect(app.buttons["Off"], "the reasoning levels were not revealed")
        app.buttons["Off"].tap()
        XCTAssertTrue(
            waitForDisappearance(app.buttons["model.row.deepseek-flash"], timeout: Self.patience),
            "the picker stayed open over a switch the host accepted",
        )

        // Reopened: this is what is in force, said by the screen. It is also the
        // value the refusal below has to put back.
        app.buttons["composer.model"].tap()
        XCTAssertTrue(
            app.staticTexts["model.current.deepseek-flash"].waitForExistence(timeout: Self.patience),
            "the picker does not say which model is in force",
        )

        // From here the host refuses the switch, and answers everything else.
        XCTAssertTrue(Self.failMockHost("session.model.set"), "the mock did not take the refusal knob")

        // The refusal is driven through the reasoning-level control rather than
        // by tapping the model's own row, and that is about the test rather than
        // the app: a `List` row's button is not reliably hittable once the picker
        // has been closed and reopened under XCUITest, while the segmented
        // control is. What it exercises is the same `commit`, the same
        // `setModel`, and the same failure.
        // `Off`, not `High`: the second model already defaults to `High`, and a
        // segmented control whose selection does not change does not call its
        // binding -- so a tap on the level already in force commits nothing.
        app.buttons["model.row.deepseek-v4-pro"].tap()
        expect(app.buttons["Off"], "the second model's levels were not revealed")
        app.buttons["Off"].tap()

        XCTAssertTrue(
            labelled("model.error", in: app, contains: "failed on purpose")
                .waitForExistence(timeout: Self.patience),
            "a refused model switch was not reported at all",
        )
        // Back to the model that is actually in force. The picker did not close
        // over the refusal, so the operator is looking at the answer.
        XCTAssertTrue(
            app.staticTexts["model.current.deepseek-flash"].waitForExistence(timeout: 5),
            "the picker kept showing a model the host had refused, as though it were in force",
        )
        XCTAssertFalse(
            app.staticTexts["model.current.deepseek-v4-pro"].exists,
            "the refused model is still the one the picker says is in force",
        )
    }

    /// Wait until an element is gone.
    ///
    /// - Parameters:
    ///   - element: what to watch.
    ///   - timeout: how long to wait.
    /// - Returns: whether it went away.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// What belongs to one Mac does not follow the operator to the next.
    ///
    /// The app keeps the model and permission catalogues, the pending
    /// interactions and the recent host events for the machine it is talking to,
    /// and none of them were dropped when the machine changed. The catalogues are
    /// the visible half: they are read once per *connection* and never re-read,
    /// so a phone that switches Macs draws the first Mac's models in the second
    /// Mac's picker -- and the two mocks disagree about what they offer, which is
    /// the only way that is observable.
    ///
    /// Two hosts, deliberately: one mock answers every read with the same
    /// providers, the same sessions and the same host id, so a screen drawn from
    /// the wrong Mac's answer looks exactly like a screen drawn from the right
    /// one. `scripts/mock-host.mjs 19396` is a different machine.
    func testSwitchingMacsDoesNotCarryTheFirstMacsCatalog() {
        Self.resetSecondMockHost()
        let app = launch(
            session: nil,
            pending: false,
            running: false,
            pairingURIs: [Self.mockPairingURI, Self.secondMockPairingURI],
        )
        // The second Mac is the one open: the last pairing is the current one.
        if !app.staticTexts["Mock Mac (second)"].waitForExistence(timeout: Self.patience) {
            let dump = app.staticTexts.allElementsBoundByIndex.prefix(25)
                .map { $0.identifier.isEmpty ? "<no id>" : $0.identifier }
            XCTFail("the second Mac was not the one opened; screen says: \(dump)")
        }

        // The picker is inside a conversation, so one is opened first. Read the
        // second Mac's catalogue into the app by opening the picker that asks for
        // it -- which is what makes the catalogue a *cached* value rather than
        // one fetched on demand, and the value the switch below must not carry.
        let demo = app.buttons["workspace./Users/you/projects/demo"]
        expect(demo, "the second Mac's first workspace is missing")
        let secondRow = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(expand(demo, revealing: secondRow), "the second Mac's session never appeared")
        secondRow.tap()
        let opener = app.buttons["composer.model"]
        expect(opener, "the second Mac's conversation never opened")
        opener.tap()
        XCTAssertTrue(
            app.buttons["model.row.kimi-k2"].waitForExistence(timeout: Self.patience),
            "the second Mac's own catalogue is missing",
        )
        app.navigationBars.buttons["Done"].tap()
        expect(app.buttons["composer.model"], "the picker never closed")

        // Back to the list, and to the first Mac.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        expect(back, "there is no way back to the session list")
        back.tap()
        expect(app.buttons["sessions.hosts"], "the session list never came back")
        app.buttons["sessions.hosts"].tap()
        let first = app.buttons["host.row.mock-host-0000-4000-8000-000000000000"]
        expect(first, "the first Mac is not in the list")
        first.tap()
        // Choosing a machine opens it but leaves the list of machines on top:
        // the row's job is to switch, and the back button is how the operator
        // gets to the sessions they just switched to.
        let backToSessions = app.navigationBars.buttons.element(boundBy: 0)
        expect(backToSessions, "there is no way back from the host list")
        backToSessions.tap()
        expect(app.buttons["sessions.hosts"], "the first Mac's session list never arrived")

        // A conversation on the first Mac, so its picker -- and therefore its
        // catalogue -- is reachable. Opening the picker is what asks for it.
        let firstDemo = app.buttons["workspace./Users/you/projects/demo"]
        expect(firstDemo, "the first Mac's first workspace is missing")
        let firstRow = sessionRow(in: app, titled: "Mock session", in: "demo")
        XCTAssertTrue(expand(firstDemo, revealing: firstRow), "the first Mac's session never appeared")
        firstRow.tap()
        expect(app.buttons["composer.model"], "the first Mac's conversation never opened")
        app.buttons["composer.model"].tap()
        XCTAssertTrue(
            app.buttons["model.row.deepseek-flash"].waitForExistence(timeout: Self.patience),
            "the first Mac's catalogue is missing",
        )
        XCTAssertFalse(
            app.buttons["model.row.kimi-k2"].exists,
            "the second Mac's models are still offered under the first Mac",
        )
    }

    /// A send during a reload is one load on the socket, not two.
    ///
    /// `reload()` is the screen's load-bearing gate: it documents that two
    /// overlapping loads interleave on one socket, each one's failed request
    /// reconnecting out from under the other. The poll after a send went around
    /// it, so a message sent while the screen was reloading made exactly that
    /// pair -- and produced a fresh WebSocket every few seconds on the machine
    /// this was reported from.
    ///
    /// Counted at the host rather than asserted on screen: both loads are
    /// answered correctly and the conversation that settles is the same one, so
    /// the overlap itself is the whole of the defect and only the host can see it.
    func testASendDuringAReloadDoesNotStartASecondLoad() {
        let app = launch(pending: false, running: false)
        let field = app.textFields["composer.field"]
        expect(field, "the conversation never opened")
        expect(app.staticTexts["The parser is now two files."], "the conversation never arrived")

        // Held rather than stalled, for both halves of the arrangement. The
        // reload's conversation read waits at the host until this test lets it
        // go, and the send's prompt is held long enough that the poll following
        // it starts *while* that read is still waiting -- which is the overlap
        // under test, arranged rather than raced for. A delay long enough to be
        // measured on a loaded machine is a delay long enough for the other half
        // to have finished first, and this suite has already been bitten by a
        // test that measured the clock instead of the app.
        Self.holdMockConversationReads(true)
        Self.stallMockHost(3_000, method: "session.prompt")
        // From here, whatever the host has already answered is not counted.
        XCTAssertEqual(Self.mockLoads()?.inFlight, 0, "a conversation read was already in flight")

        // The reload, stopped at the host on its conversation read.
        let refresh = app.buttons["session.refresh"]
        expect(refresh, "there is no way to refresh the conversation")
        refresh.tap()

        // Then the send, which is accepted immediately and whose own refresh
        // starts three seconds later -- with the reload still in flight, because
        // this read has not been released.
        field.tap()
        field.typeText("Count the loads")
        app.buttons["composer.send"].tap()

        // Long enough for the delayed answer to arrive and for the poll after it
        // to have made its first read, if it is going to make one. Nothing about
        // this wait is what the assertion measures: the reload's read is held
        // either way, and the send's has either happened by now or never will.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(refresh.isEnabled, "the reload finished, so nothing overlapped after all")

        // Let the reload finish, and the screen settle on the conversation.
        XCTAssertNotNil(Self.holdMockConversationReads(false), "the host was not holding a read")
        XCTAssertTrue(
            reveal(app.staticTexts["Count the loads"], in: app),
            "the sent message never came back from the host",
        )

        XCTAssertEqual(
            Self.mockLoads()?.peak,
            1,
            "the host was answering two conversation reads at once: the send's poll went around the screen's reload gate",
        )
    }

    // MARK: - Localisation

    func testInterfaceFollowsTheLanguageAndContentDoesNot() {
        let chinese = launch(language: "zh-Hans", pending: false)
        // Scrolled back to: the failure card belongs to the second turn, and the
        // conversation opens on its newest one.
        let failure = chinese.staticTexts["本轮没有产生回复"]
        XCTAssertTrue(reveal(failure, in: chinese), "the failure card did not translate")
        // The composer's placeholder, which is interface copy. This used to
        // assert on the "对话" segmented control; that control is gone, and the
        // placeholder is the localised string nearest the same place on screen.
        XCTAssertEqual(
            chinese.textFields["composer.field"].value as? String,
            "给 agent 发消息…",
            "the interface did not follow Chinese",
        )
        // Message content is data from the session, not interface copy.
        let prompt = chinese.staticTexts["Refactor the parser and run the tests."]
        XCTAssertTrue(reveal(prompt, in: chinese), "message content was translated")
        // The command sheet's names are the app's words; the slash forms beside
        // them are what the host parses and stay exactly as they are.
        chinese.buttons["composer.commands"].tap()
        let chineseGoal = chinese.buttons["command.goal"]
        expect(chineseGoal, "the command list did not open")
        XCTAssertTrue(
            chineseGoal.label.contains("目标"),
            "the command name did not translate: \(chineseGoal.label)",
        )
        chinese.terminate()

        let english = launch(language: "en", pending: false)
        let englishFailure = english.staticTexts["The turn ended without a response"]
        XCTAssertTrue(reveal(englishFailure, in: english), "the failure card did not translate")
        XCTAssertEqual(
            english.textFields["composer.field"].value as? String,
            "Ask your agent…",
            "the interface did not follow English",
        )
        english.buttons["composer.commands"].tap()
        let englishGoal = english.buttons["command.goal"]
        expect(englishGoal, "the command list did not open in English")
        XCTAssertTrue(
            englishGoal.label.contains("Goal"),
            "the command name is not English: \(englishGoal.label)",
        )
    }
}
