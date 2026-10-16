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

    /// How long to wait for the host to answer.
    private static let patience: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
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
    private static func resetMockHost(pending: Bool = true, slow: Int = 0) {
        var query = pending ? "" : "?pending=0"
        if slow > 0 { query += query.isEmpty ? "?slow=\(slow)" : "&slow=\(slow)" }
        guard let url = URL(string: "http://127.0.0.1:19395/reset\(query)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        // Bounded, because a mock host that is not running is a suite that is
        // about to fail on its own terms -- not one to hang on here.
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
    private static func failMockHost(_ method: String) {
        guard let url = URL(string: "http://127.0.0.1:19395/fail?method=\(method)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
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
        guard let url = URL(string: "http://127.0.0.1:19395/slow?ms=\(milliseconds)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
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

    /// Launch the app, optionally pairing and opening a session on the way in.
    /// - Parameters:
    ///   - pairing: whether to pass a pairing URI.
    ///   - session: a session to open, or `nil` to stay on the list.
    ///   - language: a language to force, or `nil` to follow the system.
    ///   - pending: whether the mock should offer a pending approval and question.
    ///   - slow: how long the mock should stall every answer, in milliseconds.
    ///   - freshStart: whether to throw the stored data away first.
    ///   - naming: whether to wait for the naming prompt before returning.
    ///     It is offered *after* a first download, so a test about that download
    ///     would spend the whole of it here instead of looking at it.
    /// - Returns: the running application.
    private func launch(
        pairing: Bool = true,
        session: String? = "first",
        language: String? = "en",
        pending: Bool = true,
        slow: Int = 0,
        naming: Bool = true,
        freshStart: Bool = true,
    ) -> XCUIApplication {
        Self.resetMockHost(pending: pending, slow: slow)
        let app = XCUIApplication()
        app.launchArguments = Self.arguments(
            pairing: pairing,
            session: session,
            language: language,
            freshStart: freshStart,
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
    /// - Returns: the arguments.
    private static func arguments(
        pairing: Bool,
        session: String?,
        language: String?,
        freshStart: Bool,
    ) -> [String] {
        var arguments: [String] = []
        if pairing { arguments += ["-mizarPairURI", mockPairingURI] }
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
        // not pass.
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
        control.tap()
        let after = settingState(identifier, in: app)
        XCTAssertNotNil(after, "the switch reports no state after being tapped")
        XCTAssertNotEqual(before, after, "the switch did not move when it was tapped")

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
        settingControl(identifier, in: reopened).tap()
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
        let app = launch(session: nil, slow: 500, naming: false)
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
        let app = launch()
        expect(app.buttons["approval.allowOnce"], "there is no way to allow")
        expect(app.buttons["approval.reject"], "there is no way to reject")
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
        chinese.terminate()

        let english = launch(language: "en", pending: false)
        let englishFailure = english.staticTexts["The turn ended without a response"]
        XCTAssertTrue(reveal(englishFailure, in: english), "the failure card did not translate")
        XCTAssertEqual(
            english.textFields["composer.field"].value as? String,
            "Ask your agent…",
            "the interface did not follow English",
        )
    }
}
