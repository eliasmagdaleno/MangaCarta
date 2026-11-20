import UIKit
import XCTest

final class LocalPDFReaderUITests: XCTestCase {
    private var storageID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        storageID = UUID().uuidString
    }

    func testPagedZoomKeepsThePageAndTurns() throws {
        let app = launchReader()
        let pageOne = pageElement(1, in: app)
        XCTAssertTrue(pageOne.waitForExistence(timeout: 15))
        selectMode("Left to Right", in: app)
        XCTAssertEqual(pageOne.label, "Page 1 of 6")
        let indicator = app.staticTexts["readerPageIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(indicator, "Page 1 of 6", timeout: 10))
        attach(app, name: "pdf-paged-page-one")

        pageOne.doubleTap()
        XCTAssertTrue(waitForLabel(pageOne, "Page 1 of 6", timeout: 5))
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        attach(app, name: "pdf-paged-zoomed-page-one")

        pageOne.doubleTap()
        app.swipeLeft()
        let pageTwo = app.descendants(matching: .any)["Page 2 of 6"]
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(indicator, "Page 2 of 6", timeout: 10))
        attach(app, name: "pdf-paged-page-two")
    }

    func testWebtoonRowsLabelRestoreAndEnd() throws {
        let app = launchReader()
        selectMode("Webtoon (Vertical)", in: app)
        let pageOne = pageElement(1, in: app)
        XCTAssertTrue(pageOne.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForFrameIntersection(pageOne, app: app, timeout: 10))
        let aspect = pageOne.frame.height / pageOne.frame.width
        XCTAssertEqual(aspect, 1.5, accuracy: 1.5 * 0.03)
        attach(app, name: "pdf-webtoon-page-one-aspect")

        let close = app.buttons["readerCloseButton"]
        XCTAssertTrue(waitForHittable(close, true, timeout: 5))
        pageOne.tap()
        XCTAssertTrue(waitForHittable(close, false, timeout: 5))
        attach(app, name: "pdf-webtoon-chrome-hidden")
        pageOne.tap()
        XCTAssertTrue(waitForHittable(close, true, timeout: 5))
        attach(app, name: "pdf-webtoon-chrome-restored")

        let pageThree = pageElement(3, in: app)
        XCTAssertTrue(scrollToPageThree(app, pageThree: pageThree))
        XCTAssertTrue(pageThree.frame.minY <= app.frame.midY)
        attach(app, name: "pdf-webtoon-page-three-before-close")
        close.tap()

        let read = readButton(in: app)
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        XCTAssertTrue(pageThree.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFrameIntersection(pageThree, app: app, timeout: 15))
        XCTAssertFalse(waitForFrameIntersection(pageOne, app: app, timeout: 3))
        attach(app, name: "pdf-webtoon-page-three-restored")

        let endMark = app.descendants(matching: .any)["End of chapter. 6 pages"]
        for _ in 0..<10 where !endMark.exists {
            app.swipeUp()
        }
        XCTAssertTrue(endMark.waitForExistence(timeout: 10))
        attach(app, name: "pdf-webtoon-end-mark")
    }

    func testRightToLeftOpensOnPageOneAndAdvancesBySwipingRight() throws {
        let app = launchReader()
        selectMode("Right to Left", in: app)
        let indicator = app.staticTexts["readerPageIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(indicator, "Page 1 of 6", timeout: 10))
        let pageOne = pageElement(1, in: app)
        XCTAssertTrue(pageOne.waitForExistence(timeout: 10))
        attach(app, name: "pdf-rtl-page-one")

        app.swipeRight()

        let pageTwo = pageElement(2, in: app)
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(indicator, "Page 2 of 6", timeout: 10))
        attach(app, name: "pdf-rtl-page-two")
    }

    private func launchReader() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-local-import", "-uitest-import-fixture", "local-pdf-reader"]
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = storageID
        app.launchEnvironment["MANGACARTA_UI_FIXTURE_BASE64"] = Self.fixtureBase64
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Library"].tap()
        let card = app.buttons["libraryCoverCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        let read = readButton(in: app)
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        XCTAssertTrue(app.buttons["readerModeMenu"].waitForExistence(timeout: 10))
        return app
    }

    private func readButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'Start Reading' OR label CONTAINS[c] 'Continue'"
        )).firstMatch
    }

    private func pageElement(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Page \(number) of 6"
        )).firstMatch
    }

    private func selectMode(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons["readerModeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func scrollToPageThree(_ app: XCUIApplication, pageThree: XCUIElement) -> Bool {
        for _ in 0..<10 where pageThree.frame.minY > app.frame.midY {
            app.swipeUp()
            if waitForPageAboveMiddle(pageThree, app: app, timeout: 2) { return true }
        }
        return pageThree.exists && pageThree.frame.minY <= app.frame.midY
    }

    private func waitForPageAboveMiddle(_ page: XCUIElement, app: XCUIApplication,
                                        timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if page.exists && page.frame.minY <= app.frame.midY { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return page.exists && page.frame.minY <= app.frame.midY
    }

    private func waitForFrameIntersection(_ element: XCUIElement, app: XCUIApplication,
                                          timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.frame.intersects(app.frame) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists && element.frame.intersects(app.frame)
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHittable(_ element: XCUIElement, _ hittable: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "hittable == %@", NSNumber(value: hittable))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static var fixtureBase64: String {
        let pageBounds = CGRect(x: 0, y: 0, width: 600, height: 900)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let data = renderer.pdfData { context in
            for pageNumber in 1...6 {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(pageBounds)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 150, weight: .bold),
                    .foregroundColor: UIColor.black
                ]
                NSString(string: "PAGE \(pageNumber)").draw(at: CGPoint(x: 90, y: 360), withAttributes: attributes)
            }
        }
        return data.base64EncodedString()
    }
}
