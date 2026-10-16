import XCTest

@MainActor
final class ActivityAnnouncementUITests: XCTestCase {
    func testLayoutChoicesApplyToActivityAndUnreadDemoIsInteractive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "activity"
        app.launchEnvironment["OPENCLIENT_ACTIVITY_ANNOUNCEMENT"] = "1"
        app.launch()
        defer { app.terminate() }

        let grouping = app.segmentedControls["announcement.activity.grouping"]
        XCTAssertTrue(grouping.waitForExistence(timeout: 10))
        capture(app, "activity-announcement-recent")
        XCTAssertTrue(element("announcement.activity.preview.recent", in: app).exists)
        grouping.buttons["Status"].tap()
        let layout = app.segmentedControls["announcement.activity.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        XCTAssertTrue(element("announcement.activity.preview.list", in: app).exists)
        capture(app, "activity-announcement-list")
        layout.buttons["Board"].tap()
        XCTAssertTrue(element("announcement.activity.preview.board", in: app).exists)
        capture(app, "activity-announcement-board")
        grouping.buttons["Recent"].tap()
        XCTAssertFalse(layout.exists)
        grouping.buttons["Status"].tap()
        XCTAssertTrue(layout.buttons["Board"].isSelected, "Remember the selected status layout across grouping changes")

        let read = app.buttons["announcement.activity.tryRead"]
        // On iPad the sheet is inset; app-wide swipes can miss its scroll view.
        let announcementScroll = app.scrollViews.containing(.segmentedControl, identifier: "announcement.activity.grouping").firstMatch
        XCTAssertTrue(announcementScroll.exists)
        for _ in 0..<6 where !read.isHittable { announcementScroll.swipeUp() }
        XCTAssertTrue(read.isHittable)
        XCTAssertEqual(read.value as? String, "Unread")
        capture(app, "activity-announcement-unread")
        read.tap()
        XCTAssertEqual(read.value as? String, "Read")
        capture(app, "activity-announcement-read")
        read.tap()
        XCTAssertEqual(read.value as? String, "Unread")
        app.buttons["new-features.continue"].tap()
        XCTAssertTrue(element("activity.board", in: app).waitForExistence(timeout: 5), "The sheet must apply the choice to real Activity")
        capture(app, "activity-announcement-applied")
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
