import XCTest

@MainActor
final class ComposerMentionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSkillsAndAgentsShareMentionPickerButSkillsAreNotCommands() {
        verifyMentionPicker(busy: false)
    }

    func testCommandsAgentsAndSkillsStayAvailableWhileProcessing() {
        verifyMentionPicker(busy: true)
    }

    private func verifyMentionPicker(busy: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "composer-mentions"
        app.launchEnvironment["OPENCLIENT_MENTION_FIXTURE_BUSY"] = busy ? "1" : "0"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        XCTAssertEqual(input.value as? String, "@")
        let agent = app.buttons["chat.agentMention.review"]
        let skill = app.buttons["chat.skillMention.review"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        XCTAssertTrue(skill.waitForExistence(timeout: 5))
        XCTAssertTrue(agent.isHittable)
        XCTAssertTrue(skill.isHittable)
        let longSkill = app.buttons["chat.skillMention.audit-xcode-security-settings"]
        XCTAssertTrue(longSkill.exists)
        XCTAssertEqual(longSkill.frame.height, skill.frame.height, accuracy: 1, "Long names must remain on one line")
        if busy {
            let stop = app.buttons["chat.stream.stop"]
            if stop.exists {
                XCTAssertFalse(stop.frame.intersects(skill.frame), "Stop must not cover a suggestion")
            }
        }
        capture(app, "Mention-Picker-Collision")

        skill.tap()
        XCTAssertEqual(input.value as? String, "@review ")
        input.typeText("@rele")
        let release = app.buttons["chat.skillMention.release"]
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        XCTAssertFalse(agent.exists)
        XCTAssertFalse(skill.exists)
        release.tap()
        XCTAssertEqual(input.value as? String, "@review @release ")
        capture(app, "Mention-Multiple-Skills")

        replaceText(in: input, with: "@review")
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        agent.tap()
        XCTAssertEqual(input.value as? String, "@review ")

        replaceText(in: input, with: "/")
        XCTAssertTrue(app.buttons["chat.command.compact"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.command.release"].exists)
        XCTAssertFalse(app.buttons["chat.command.skill:review"].exists)
        XCTAssertFalse(release.exists)
        capture(app, "Commands-Without-Skills")
    }

    private func replaceText(in input: XCUIElement, with text: String) {
        // These fixture drafts fit on one line. Tap beyond the text to place
        // the caret at its end rather than relying on hardware-key routing.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        XCTAssertEqual(input.value as? String, "")
        input.typeText(text)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-Hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
