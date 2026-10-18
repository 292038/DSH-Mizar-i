//
//  ScreenshotTour.swift
//  DSH-MizarUITests
//
//  Walks the app through its screens and writes a picture of each.
//
//  Not a test of anything: it is how `docs/screenshots` is made, against the
//  mock host, and it is skipped unless a folder to write to is given --
//
//    TEST_RUNNER_MIZAR_SHOTS=/tmp/tour scripts/ios.sh test "iPhone 18 Pro" \
//      -only-testing:DSH-MizarUITests/ScreenshotTour
//
//  `TEST_RUNNER_` is xcodebuild's prefix for passing a variable through to the
//  test runner; the runner sees `MIZAR_SHOTS`.
//

import XCTest

final class ScreenshotTour: XCTestCase {
    private var folder: URL!
    private static let pairing = "mizar://pair?h=127.0.0.1%3A19395&c=MOCK-CODE&n=Mock%20Mac&v=1"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MIZAR_SHOTS"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_MIZAR_SHOTS to a folder to write the tour to")
        }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    private func reset(pending: Bool) {
        let url = URL(string: "http://127.0.0.1:19395/reset?\(pending ? "" : "pending=0")")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let done = expectation(description: "reset")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 6)
    }

    private func launch(session: String?, language: String, pending: Bool) -> XCUIApplication {
        reset(pending: pending)
        let app = XCUIApplication()
        var arguments = ["-mizarPairURI", Self.pairing, "-mizarFreshStart", "-mizarSkipPermissionPrompts",
                         "-AppleLanguages", "(\(language))"]
        if let session { arguments += ["-mizarSelectSession", session] }
        app.launchArguments = arguments
        app.launch()
        let skip = app.buttons["rename.skip"]
        if skip.waitForExistence(timeout: 20) { skip.tap() }
        return app
    }

    /// Wait until something can be touched where it is drawn -- not merely
    /// exists -- so a tap does not land where a moving control used to be.
    @discardableResult
    private func settled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        let ok = XCTWaiter().wait(for: [ready], timeout: timeout) == .completed
        Thread.sleep(forTimeInterval: 0.5)
        return ok
    }

    private func shoot(_ name: String, settle: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testTour() {
        for language in ["en", "zh-Hans"] {
            let suffix = language == "en" ? "" : "-zh"

            // The sidebar, as a launch with nothing selected shows it.
            var app = launch(session: nil, language: language, pending: true)
            _ = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            app.buttons["workspace./Users/you/projects/demo"].staticTexts.element(boundBy: 0).tap()
            shoot("01-sidebar\(suffix)")

            // A conversation, with the requests docked above the composer.
            app.terminate()
            app = launch(session: "first", language: language, pending: true)
            _ = app.textFields["composer.field"].waitForExistence(timeout: 20)
            shoot("02-conversation-dock\(suffix)", settle: 2.5)

            // The sidebar out, and the conversation pushed aside as a card.
            app.buttons["shell.sidebarToggle"].tap()
            shoot("03-sidebar-card\(suffix)")
            settled(app.buttons["shell.dismissSidebar"])
            app.buttons["shell.dismissSidebar"].tap()

            // Typing tucks the requests away.
            settled(app.textFields["composer.field"])
            app.textFields["composer.field"].tap()
            app.textFields["composer.field"].typeText("Run the tests again")
            shoot("04-typing\(suffix)")
            // The tucked pill brings them back and puts the keyboard away.
            let tucked = app.buttons["interactions.tucked"]
            if settled(tucked) { tucked.tap() }

            // The question card, from the deck.
            if language == "en" {
                let next = app.buttons["interactions.next"]
                if settled(next) { next.tap() }
                shoot("05-question\(suffix)")
            }

            // The model picker.
            app.buttons["composer.model"].tap()
            shoot("06-model\(suffix)")
            app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1).tap()

            // Home, and the settings.
            app.terminate()
            app = launch(session: nil, language: language, pending: false)
            _ = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            settled(app.buttons["shell.dismissSidebar"])
            app.buttons["shell.dismissSidebar"].tap()
            shoot("07-home\(suffix)", settle: 1.6)
            app.buttons["shell.sidebarToggle"].tap()
            // Tapped until the sheet is up: a tap that lands while the sidebar
            // is still settling is a tap on a control that is moving.
            for _ in 0..<3 {
                settled(app.buttons["sidebar.settings"])
                app.buttons["sidebar.settings"].tap()
                if app.buttons["settings.done"].waitForExistence(timeout: 4) { break }
            }
            shoot("08-settings\(suffix)")
            app.terminate()
        }
    }
}
