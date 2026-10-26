import XCTest
import UIKit

/// Exercises the shipping V1 and V2 question panels with local-only DEBUG submissions.
@MainActor
final class QuestionPresentationUITests: XCTestCase {
    private let draft = "First line of retained answer\nSecond line with implementation details"
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLegacyExpandedQuestionDraftAndSubmission() throws { try exercise(legacy: true) }
    func testV2ExpandedQuestionDraftAndSubmission() throws { try exercise(legacy: false) }
    func testLegacyOptionExcludesRetainedCustomDraft() throws { try exercise(legacy: true, submitCustom: false) }
    func testV2OptionExcludesRetainedCustomDraft() throws { try exercise(legacy: false, submitCustom: false) }

    func testV2MultiselectCustomTextOnlyDirectSubmission() throws { try exerciseMultiselect(includeOption: false) }
    func testV2MultiselectOptionAndMultilineDirectSubmission() throws { try exerciseMultiselect(includeOption: true) }

    private func exerciseMultiselect(includeOption: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "question"
        app.launchEnvironment["OPENCLIENT_V2_QUESTION_FIXTURE"] = "1"
        app.launchEnvironment["OPENCLIENT_QUESTION_MULTI_REGRESSION"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let expand = app.buttons["question.expand.visual-question"]
        XCTAssertTrue(expand.waitForExistence(timeout: 15))
        capture(app, "Multi-inline-card-edge")
        expand.tap()
        let close = app.buttons["question.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture(app, "Multi-expanded-long-prompt")
        let editors = app.textFields.matching(identifier: "question.customAnswer")
        let editor = editors.element(boundBy: editors.count - 1)
        let submits = app.buttons.matching(identifier: "form.submit.visual-question")
        let submit = submits.element(boundBy: submits.count - 1)
        XCTAssertFalse(submit.isEnabled, "An empty required multiselect must not submit")
        reveal(editor, app: app)
        capture(app, "Multi-scrolled-custom-card-edge")
        editor.tap()
        editor.typeText(draft)
        XCTAssertTrue(submit.isEnabled, "Pending custom text alone must satisfy the required multiselect")
        XCTAssertFalse(app.buttons["Add"].exists, "Session forms submit custom drafts directly")
        capture(app, "Multi-pending-text-enables-submit")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        reveal(editor, app: app)
        XCTAssertEqual(editor.value as? String, draft)
        if includeOption {
            let options = app.buttons.matching(identifier: "form.option.approaches.Approach 8")
            let option = options.element(boundBy: options.count - 1)
            reveal(option, app: app, upward: false)
            option.tap()
            XCTAssertTrue(option.isSelected)
            reveal(editor, app: app)
            XCTAssertEqual(editor.value as? String, draft)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            expand.tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            reveal(editor, app: app)
            XCTAssertEqual(editor.value as? String, draft)
            XCTAssertTrue(option.isSelected, "Closing must preserve option selection as well as pending custom text")
        }
        capture(app, "Multi-reopened-retained-draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        capture(app, "Multi-landscape-scroll-edge")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let result = app.staticTexts["form.fixture.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(result.label.data(using: .utf8))) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["approaches"])
        XCTAssertEqual(payload["approaches"] as? [String], includeOption ? ["Approach 8", draft] : [draft])
        capture(app, "Multi-direct-submission-payload")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<14 {
            if element.exists && element.isHittable && element.frame.minY > 90 && element.frame.maxY < app.frame.height - 150 { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.65 : 0.3))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.3 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func exercise(legacy: Bool, submitCustom: Bool = true) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let prefix = legacy ? "V1" : "V2"
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "question"
        app.launchEnvironment["OPENCLIENT_V2_QUESTION_FIXTURE"] = "1"
        app.launchEnvironment["OPENCLIENT_QUESTION_REGRESSION"] = "1"
        app.launchEnvironment["OPENCLIENT_QUESTION_LEGACY"] = legacy ? "1" : "0"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let expand = app.buttons["question.expand.visual-question"]
        XCTAssertTrue(expand.waitForExistence(timeout: 15))
        capture(app, prefix + "-inline-long-question")
        expand.tap()
        let close = app.buttons["question.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture(app, prefix + "-expanded-long-question")
        // The covered inline tree remains in XCTest's hierarchy. Target page one
        // of the presented copy, rather than the first (covered) editor.
        let editors = app.textFields.matching(identifier: "question.customAnswer")
        let editor = editors.element(boundBy: editors.count - 2)
        reveal(editor, app: app)
        capture(app, prefix + "-scrolled-editor")
        editor.tap()
        editor.typeText(draft)
        capture(app, prefix + "-multiline-keyboard")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        reveal(editor, app: app)
        XCTAssertEqual(editor.value as? String, draft)
        let options = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Approach 8"))
        let option = options.element(boundBy: options.count - 1)
        reveal(option, app: app, upward: false)
        option.tap()
        let second = app.buttons.matching(identifier: "Question 2").allElementsBoundByIndex.last!
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(second.value as? String, "Current")
        capture(app, prefix + "-option-selected-page-two")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(second.value as? String, "Current", "Reopening must retain the selected page")
        capture(app, prefix + "-reopened-page-two")
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "All devices")).allElementsBoundByIndex.last!
        let restoredPage = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)], timeout: 5) == .completed
        continueAfterFailure = true
        XCTAssertTrue(restoredPage, "The visible carousel page must agree with the retained page indicator after reopening")
        continueAfterFailure = false
        if !restoredPage {
            // Keep the regression failure above, but exercise submission independently.
            app.buttons.matching(identifier: "Question 1").allElementsBoundByIndex.last!.tap()
            app.buttons.matching(identifier: "Question 2").allElementsBoundByIndex.last!.tap()
        }
        target.tap()
        app.buttons.matching(identifier: "Question 1").allElementsBoundByIndex.last!.tap()
        reveal(editor, app: app)
        XCTAssertEqual(editor.value as? String, draft, "Selecting an option must not erase a custom draft")
        let use = app.buttons.matching(identifier: "Use Custom Answer").allElementsBoundByIndex.last!
        reveal(use, app: app)
        capture(app, prefix + "-retained-inactive-draft")
        use.tap()
        XCTAssertTrue(use.waitForNonExistence(timeout: 5))
        if !submitCustom {
            reveal(option, app: app, upward: false)
            option.tap()
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        capture(app, prefix + "-expanded-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        let submit = app.buttons.matching(identifier: legacy ? "question.submit.visual-question" : "form.submit.visual-question").allElementsBoundByIndex.last!
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let result = app.staticTexts["form.fixture.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), "Submitting the local fixture should dismiss the expanded panel")
        XCTAssertFalse(close.exists)
        let data = try XCTUnwrap(result.label.data(using: .utf8))
        let payload = try JSONSerialization.jsonObject(with: data)
        if legacy {
            XCTAssertEqual(payload as? [[String]], [[submitCustom ? draft : "Approach 8"], ["All devices"]])
        } else {
            let values = try XCTUnwrap(payload as? [String: Any])
            XCTAssertEqual(values["framework"] as? String, submitCustom ? draft : "Approach 8")
            XCTAssertEqual(values["target"] as? String, "All devices")
        }
        capture(app, prefix + "-local-submission-result")
    }
}

@MainActor
final class ChatHeaderUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private var isRunningOniPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            || ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.localizedCaseInsensitiveContains("iPad") == true
    }

    func testShortTitlePillIsWiderThanEntireModelGroup() {
        for window in [false, true] {
            let app = launch(window: window, shortTitle: true)
            XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
            assertEssentialControls(app, modelTitle: "GPT-6 Astra", reasoning: "Default")
            capture(app, "Toolbar-Short-Title-Balance-\(window ? "Window" : "Root")")
            app.terminate()
        }
    }

    func testLongModelAndReasoningStayVisibleWithoutToolbarOverflow() {
        let appearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = appearance }
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = launch(window: dark, large: true, longModel: true)
            XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
            capture(app, "Toolbar-Long-\(dark ? "Dark" : "Light")")
            assertEssentialControls(app, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
            app.terminate()
        }
    }

    private func assertEssentialControls(_ app: XCUIApplication, modelTitle: String, reasoning: String) {
        let usesToolbarModel = app.buttons["chat.toolbar.model"].exists
        let modelIdentifier = usesToolbarModel ? "chat.toolbar.model" : "chat.composer.model"
        let model = app.buttons[modelIdentifier]
        XCTAssertTrue(model.exists)
        XCTAssertTrue(model.isHittable)
        XCTAssertTrue((model.value as? String ?? "").contains(modelTitle))
        XCTAssertTrue((model.value as? String ?? "").contains(reasoning))
        let title = app.staticTexts["\(modelIdentifier).title"]
        let variant = app.staticTexts["\(modelIdentifier).reasoning"]
        XCTAssertTrue(title.exists)
        XCTAssertTrue(variant.exists)
        XCTAssertLessThanOrEqual(title.frame.maxX, model.frame.maxX)
        XCTAssertLessThanOrEqual(variant.frame.maxX, model.frame.maxX)
        if usesToolbarModel {
            XCTAssertLessThanOrEqual(model.frame.width, 192)
            XCTAssertGreaterThanOrEqual(model.frame.height, 44)
            let logo = app.descendants(matching: .any).matching(identifier: "chat.toolbar.providerLogo").firstMatch
            XCTAssertTrue(logo.exists)
            XCTAssertGreaterThanOrEqual(logo.frame.minX, max(title.frame.maxX, variant.frame.maxX))
            XCTAssertLessThanOrEqual(logo.frame.maxX, model.frame.maxX)
        }
        let ring = app.buttons["chat.toolbar.context"]
        XCTAssertTrue(ring.isHittable)
        if usesToolbarModel {
            XCTAssertEqual(ring.frame.width, 44, accuracy: 1)
            XCTAssertGreaterThanOrEqual(ring.frame.minX, app.buttons["chat.header"].frame.maxX)
            XCTAssertGreaterThanOrEqual(model.frame.minX, ring.frame.maxX)
            let header = app.buttons["chat.header"]
            let leftWidth = ring.frame.maxX - header.frame.minX
            XCTAssertGreaterThan(leftWidth, model.frame.width)
            XCTAssertLessThanOrEqual(ring.frame.minX - header.frame.maxX, 4.5)
            let geometry = XCTAttachment(string: "header=\(header.frame) leftGroupWidth=\(leftWidth) model=\(model.frame) context=\(ring.frame)")
            geometry.name = "Toolbar-Rendered-Widths"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        let bar = app.navigationBars.firstMatch
        if usesToolbarModel {
            XCTAssertEqual(bar.buttons.count, 4, "Back, header, context, and model must remain in the bar without an overflow item")
            XCTAssertLessThanOrEqual(model.frame.maxX, bar.frame.maxX)
        }
        XCTAssertFalse(bar.buttons["More"].exists)
        XCTAssertFalse(bar.buttons["ellipsis"].exists)
        XCTAssertFalse(bar.buttons["More actions"].exists)
        XCTAssertFalse(bar.buttons["Open Streaming Debug Log"].exists)
        XCTAssertGreaterThan(model.frame.width, 44)
        XCTAssertLessThanOrEqual(model.frame.maxX, app.frame.maxX)
    }

    func testModelReasoningAndContextActionsRemainUsableInRootAndWindow() {
        for window in [false, true] {
            let app = launch(window: window)
            XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
            assertEssentialControls(app, modelTitle: "GPT-6 Astra", reasoning: "High")
            let picker = app.buttons[app.buttons["chat.toolbar.model"].exists ? "chat.toolbar.model" : "chat.composer.model"]
            picker.tap()
            app.collectionViews.buttons["Model"].firstMatch.tap()
            app.collectionViews.buttons["OpenAI"].firstMatch.tap()
            app.buttons["GPT-6 Astra Extended Context Research Preview"].tap()
            XCTAssertTrue((picker.value as? String ?? "").contains("GPT-6 Astra Extended Context Research Preview"))
            picker.tap()
            app.collectionViews.buttons["Reasoning"].firstMatch.tap()
            app.buttons["Extended Deliberation For Complex Tasks"].tap()
            assertEssentialControls(app, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
            if window { XCTAssertEqual(app.staticTexts["chat.header.fixture.root"].value as? String, "astra|high") }
            else { XCTAssertEqual(app.staticTexts["chat.header.fixture.root"].value as? String, "astra-long|extended_deliberation_for_complex_tasks") }
            app.buttons["chat.toolbar.context"].tap()
            XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 3))
            capture(app, "Toolbar-Context-\(window ? "Window" : "Root")")
            app.terminate()
        }
    }

    func testCompactToolbarFits320PointPaneAndRespondsToRotation() {
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        let app = launch(window: true, large: true, longModel: true, narrow: true)
        XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
        assertEssentialControls(app, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
        capture(app, "Toolbar-320")
        app.terminate()
        let expanded = launch(window: false, longModel: true)
        XCTAssertTrue(expanded.buttons["chat.header"].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        assertEssentialControls(expanded, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
        capture(expanded, "Toolbar-Rotated")
        expanded.terminate()
    }

    func testHeaderTabsInRootAndWindow() {
        for window in [false, true] {
            let app = launch(window: window)
            defer { app.terminate() }
            let fixture = window ? "Window" : "Root"
            let header = app.buttons["chat.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 15))
            header.tap()

            XCTAssertTrue(app.textFields["chat.header.rename.title"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["chat.header.expand"].exists)

            // Only navigate seeded surfaces: never toggle MCP or create a terminal.
            for tab in ["MCP", "Files", "Terminal", "Chat", "Terminal"] {
                let button = app.buttons.matching(NSPredicate(format: "label == %@", tab)).firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing \(tab) tab in \(fixture)")
                XCTAssertTrue(button.isHittable)
                button.tap()
                XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 3))
                XCTAssertTrue(button.isSelected, "The \(tab) tab should be selected")
            }
            capture(app, "Header-Tabs-Terminal-Popover-\(fixture)")
            let popoverHierarchy = XCTAttachment(string: app.debugDescription)
            popoverHierarchy.name = "Header-Tabs-Popover-Hierarchy-\(fixture)"
            popoverHierarchy.lifetime = .keepAlways
            add(popoverHierarchy)

            for tab in ["MCP", "Files", "Chat"] {
                let button = app.buttons.matching(NSPredicate(format: "label == %@", tab)).firstMatch
                XCTAssertTrue(button.isHittable)
                button.tap()
                XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 3))
                XCTAssertTrue(button.isSelected)
            }
            XCTAssertTrue(app.textFields["chat.header.rename.title"].isHittable)
        }
    }

    func testHeaderSelectionAndRenameRootAndWindow() {
        for window in [false, true] {
            let app = launch(window: window)
            let header = app.buttons["chat.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 15))
            XCTAssertGreaterThanOrEqual(header.frame.height, 44)
            capture(app, "Header-Bar-\(window ? "Window" : "Root")")
            header.tap()
            let agent = app.buttons["chat.header.agent.ReviewAgent"]
            XCTAssertTrue(agent.waitForExistence(timeout: 3))
            capture(app, "Header-\(window ? "Window" : "Root")")
            let transcript = app.collectionViews["chat.scroll"]
            let popover = app.otherElements["chat.header.popover"].firstMatch
            if popover.exists, transcript.exists {
                XCTAssertLessThanOrEqual(popover.frame.width, transcript.frame.width + 1)
                XCTAssertGreaterThanOrEqual(popover.frame.width, transcript.frame.width - 64)
            }
            XCTAssertTrue(app.staticTexts["ReviewAgent agent description"].exists)
            agent.tap()
            XCTAssertTrue(header.label.contains("ReviewAgent"))
            header.tap()
            let field = app.textFields["chat.header.rename.title"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            let originalTitle = field.value as? String
            field.tap()
            field.typeText("Renamed B")
            let renamedTitle = field.value as? String ?? ""
            XCTAssertTrue(renamedTitle.contains("Renamed B"))
            XCTAssertNotEqual(renamedTitle, originalTitle)
            app.buttons["chat.header.rename.save"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                "chat.header", renamedTitle)).firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["chat.header.fixture.root"].label, window ? "header-a" : "header-b")
            capture(app, "Header-Renamed-\(window ? "Window" : "Root")")
            app.terminate()
        }
    }

    func testHeaderLongTitleLargeTypeLightDarkAndScrollableAgents() {
        let original = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = original }
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = launch(window: true, large: true)
            let header = app.buttons["chat.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 15))
            capture(app, "Header-Large-\(dark ? "Dark" : "Light")")
            header.tap()
            XCTAssertTrue(app.textFields["chat.header.rename.title"].waitForExistence(timeout: 3))
            capture(app, "Header-Popover-Large-\(dark ? "Dark" : "Light")")
            XCTAssertTrue(app.switches["chat.header.liveActivity"].isHittable)
            app.terminate()
        }
    }

    func testHeaderMenuWhileComposerKeyboardIsVisible() {
        let app = launch(window: true)
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Keep this draft")
        assertEssentialControls(app, modelTitle: "GPT-6 Astra", reasoning: "High")
        app.buttons["chat.header"].tap()
        let list = app.collectionViews["chat.header.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        let title = app.textFields["chat.header.rename.title"]
        XCTAssertTrue(title.isHittable)
        capture(app, "Header-Keyboard")
        app.terminate()
    }

    func testHeaderAppearanceComposerStylePreviewPreservesPopoverAndDraft() {
        let app = launch(window: true)
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Keep this appearance draft")

        app.buttons["chat.header"].tap()
        let appearance = app.buttons["chat.header.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()

        let composerStyle = app.buttons["chat.appearance.composer-style"]
        if isRunningOniPad {
            XCTAssertFalse(composerStyle.exists)
            XCTAssertTrue(app.switches["configurations.show-tool-calls"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.switches["configurations.show-reasoning-blocks"].exists)
            capture(app, "Appearance-iPad-Composer-Style-Hidden")
            app.navigationBars["Appearance Settings"].buttons.firstMatch.tap()
            let currentAgent = app.buttons["chat.header.agent.build"]
            XCTAssertTrue(currentAgent.waitForExistence(timeout: 3))
            currentAgent.tap()
            XCTAssertTrue(input.waitForExistence(timeout: 3))
            XCTAssertEqual(input.value as? String, "Keep this appearance draft")
            app.terminate()
            return
        }

        XCTAssertTrue(composerStyle.waitForExistence(timeout: 3))
        composerStyle.tap()

        let picker = app.segmentedControls["configurations.composer-style"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let preview = app.descendants(matching: .any)["chat.appearance.composer-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertEqual(preview.buttons.count, 0)
        XCTAssertEqual(preview.textFields.count, 0)
        XCTAssertEqual(preview.textViews.count, 0)

        picker.buttons["Assistant"].tap()
        XCTAssertTrue(picker.buttons["Assistant"].isSelected)
        XCTAssertTrue(app.navigationBars["Composer Style"].exists, "Changing layout must not dismiss the header popover")
        XCTAssertTrue(preview.label.contains("Assistant"))

        picker.buttons["Messenger"].tap()
        XCTAssertTrue(picker.buttons["Messenger"].isSelected)
        XCTAssertTrue(app.navigationBars["Composer Style"].exists)
        picker.buttons["Assistant"].tap()
        XCTAssertTrue(picker.buttons["Assistant"].isSelected)

        app.navigationBars["Composer Style"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Appearance Settings"].waitForExistence(timeout: 3))
        app.navigationBars["Appearance Settings"].buttons.firstMatch.tap()
        let agent = app.buttons["chat.header.agent.build"]
        XCTAssertTrue(agent.waitForExistence(timeout: 3))
        agent.tap()

        XCTAssertTrue(input.waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "Keep this appearance draft")
        XCTAssertTrue(app.buttons["chat.composer.model"].waitForExistence(timeout: 3))
        app.buttons["chat.header"].tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()
        composerStyle.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.buttons["Assistant"].isSelected)
        app.terminate()
    }

    func testIPadAssistantComposerAgentSelectionPreservesDraftInRootAndWindowForBothStoredStyles() throws {
        guard isRunningOniPad else {
            throw XCTSkip("The Assistant composer agent selector is specific to iPad.")
        }

        for window in [false, true] {
            for assistant in [false, true] {
                let app = launch(window: window, narrow: true, assistant: assistant)
                let input = app.textViews["chat.input"]
                XCTAssertTrue(input.waitForExistence(timeout: 15))
                input.tap()
                input.typeText("Keep this agent draft")

                let agent = app.buttons["chat.composer.agent"]
                let model = app.buttons["chat.composer.model"]
                XCTAssertTrue(agent.waitForExistence(timeout: 3))
                XCTAssertTrue(agent.isHittable)
                XCTAssertTrue(model.isHittable)
                XCTAssertGreaterThanOrEqual(agent.frame.width, 44)
                XCTAssertGreaterThanOrEqual(agent.frame.height, 44)
                XCTAssertGreaterThanOrEqual(model.frame.width, 44)
                XCTAssertGreaterThanOrEqual(model.frame.height, 44)
                XCTAssertLessThanOrEqual(agent.frame.maxX, model.frame.minX + 1)
                XCTAssertLessThanOrEqual(model.frame.maxX, input.frame.maxX + 1)
                XCTAssertEqual(agent.value as? String, "build")

                agent.tap()
                let reviewAgent = app.buttons.matching(
                    NSPredicate(format: "label ==[c] %@", "ReviewAgent")
                ).firstMatch
                XCTAssertTrue(reviewAgent.waitForExistence(timeout: 3))
                reviewAgent.tap()

                XCTAssertEqual(agent.value as? String, "ReviewAgent")
                XCTAssertTrue(app.buttons["chat.header"].label.contains("ReviewAgent"))
                XCTAssertEqual(app.staticTexts["chat.header.fixture.agent"].label, "ReviewAgent")
                XCTAssertEqual(input.value as? String, "Keep this agent draft")
                let menu = app.buttons["chat.composer.menu"]
                XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
                XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
                capture(app, "Agent-iPad-\(window ? "Window" : "Root")-\(assistant ? "Assistant" : "Messenger")")
                app.terminate()
            }
        }
    }

    func testAssistantHeaderAndContextStayInNavigationBarWhileKeyboardIsVisible() {
        for fixture in [(name: "Root", window: false, narrow: false), (name: "Window-320", window: true, narrow: true)] {
            let app = launch(window: fixture.window, narrow: fixture.narrow, assistant: true)
            let input = app.textViews["chat.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            capture(app, "Header-Assistant-Before-Keyboard-\(fixture.name)")
            assertAssistantHeaderLayout(app)

            input.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
                input.tap()
            }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            input.typeText("Keep the Assistant composer active")
            capture(app, "Header-Assistant-Keyboard-\(fixture.name)")
            assertAssistantHeaderLayout(app)

            app.buttons["chat.header"].tap()
            let list = app.collectionViews["chat.header.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 3))
            app.buttons["chat.header.agent.build"].tap()
            XCTAssertTrue(list.waitForNonExistence(timeout: 3))

            app.buttons["chat.toolbar.context"].tap()
            XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 3))
            capture(app, "Header-Assistant-Context-\(fixture.name)")
            app.terminate()
        }
    }

    func testAssistantHeaderUsesLeadingLandscapeAndTrailingPortrait() {
        let app = launch(window: false, assistant: true)
        addTeardownBlock {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
        capture(app, "Header-Assistant-Portrait")
        assertAssistantHeaderLayout(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        capture(app, "Header-Assistant-Landscape")
        assertAssistantHeaderLayout(app, expectsLeading: true)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        capture(app, "Header-Assistant-Portrait-After-Rotation")
        assertAssistantHeaderLayout(app)
    }

    func testMessengerComposerPlusMenuWithKeyboardAndReopening() {
        exerciseComposerPlusMenu(assistant: false)
    }

    func testAssistantComposerPlusMenuWithKeyboardAndReopening() {
        exerciseComposerPlusMenu(assistant: true)
    }

    private func exerciseComposerPlusMenu(assistant: Bool) {
        let app = launch(window: false, assistant: assistant)
        defer { app.terminate() }
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let menu = app.buttons["chat.composer.menu"]
        let tools = app.navigationBars["Message Tools"]

        // Exercise an empty composer, then repeat with a retained draft and keyboard.
        for draft in ["", "Keep this draft"] {
            if !draft.isEmpty {
                input.tap()
                input.typeText(draft)
            }
            XCTAssertTrue(menu.isHittable)
            menu.tap()
            XCTAssertTrue(tools.waitForExistence(timeout: 5))
            let photos = app.buttons["chat.composer.photos"]
            XCTAssertTrue(photos.waitForExistence(timeout: 3))
            XCTAssertTrue(photos.isHittable)
            XCTAssertTrue(app.buttons["chat.composer.files"].isHittable)
            capture(app, "Composer-Plus-\(assistant ? "Assistant" : "Messenger")-\(draft.isEmpty ? "Empty" : "Draft")")
            photos.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
            XCTAssertTrue(tools.waitForNonExistence(timeout: 5))
            if !draft.isEmpty { XCTAssertEqual(input.value as? String, draft) }

            // A completed picker must leave the plus trigger reusable.
            menu.tap()
            XCTAssertTrue(tools.waitForExistence(timeout: 5))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            XCTAssertTrue(tools.waitForNonExistence(timeout: 5))
        }
    }

    func testAssistantComposerMenuOpensDismissesAndModelMenuRemainsUsable() {
        let app = launch(window: false, assistant: true)
        XCTAssertTrue(app.buttons["chat.composer.menu"].waitForExistence(timeout: 15))

        let composerMenu = app.buttons["chat.composer.menu"]
        composerMenu.tap()
        let tools = app.navigationBars["Message Tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        XCTAssertTrue(composerMenu.exists)
        capture(app, "Assistant-Attachment-Popover")

        let photos = app.buttons["chat.composer.photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 3))
        photos.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        let model = app.buttons["chat.composer.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.exists)
        XCTAssertGreaterThanOrEqual(model.frame.width, 44)
        XCTAssertGreaterThanOrEqual(model.frame.height, 44)
        let modelHittable = expectation(
            for: NSPredicate(format: "hittable == true"),
            evaluatedWith: model
        )
        wait(for: [modelHittable], timeout: 3)
        model.tap()
        let modelGroup = app.collectionViews.buttons["Model"].firstMatch
        XCTAssertTrue(modelGroup.waitForExistence(timeout: 3))
        capture(app, "Assistant-Model-Menu-Open")
        modelGroup.tap()
        let provider = app.collectionViews.buttons["OpenAI"].firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 3))
        provider.tap()
        let longModel = app.buttons["GPT-6 Astra Extended Context Research Preview"]
        XCTAssertTrue(longModel.waitForExistence(timeout: 3))
        longModel.tap()
        XCTAssertTrue((model.value as? String ?? "").contains("GPT-6 Astra Extended Context Research Preview"))
        Thread.sleep(forTimeInterval: 0.5)
        capture(app, "Assistant-Glass-Model-Long-Title")
        app.terminate()
    }

    func testAssistantComposerModelUsesIntrinsicWidthAndFits320Pane() {
        let short = launch(window: false, assistant: true)
        let shortInput = short.textViews["chat.input"]
        let shortModel = short.buttons["chat.composer.model"]
        let shortMenu = short.buttons["chat.composer.menu"]
        XCTAssertTrue(shortInput.waitForExistence(timeout: 15))
        XCTAssertTrue(shortModel.waitForExistence(timeout: 3))
        XCTAssertTrue(shortMenu.waitForExistence(timeout: 3))
        shortInput.tap()
        shortInput.typeText("Verify model width")
        let shortSend = short.buttons["chat.send"]
        XCTAssertTrue(shortSend.waitForExistence(timeout: 3))
        let shortTitle = short.staticTexts["chat.composer.model.title"]
        let shortReasoning = short.staticTexts["chat.composer.model.reasoning"]
        XCTAssertTrue(shortTitle.exists)
        XCTAssertTrue(shortReasoning.exists)
        XCTAssertGreaterThanOrEqual(shortModel.frame.width, 44)
        XCTAssertGreaterThanOrEqual(shortModel.frame.height, 44)
        XCTAssertGreaterThanOrEqual(shortSend.frame.width, 44)
        XCTAssertGreaterThanOrEqual(shortSend.frame.height, 44)
        XCTAssertGreaterThanOrEqual(shortMenu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(shortMenu.frame.height, 44)
        XCTAssertLessThan(shortModel.frame.maxX, shortSend.frame.minX,
            "The short model button must not expand into the trailing composer controls")
        XCTAssertLessThanOrEqual(shortModel.frame.width, 180,
            "The known short fixture model should remain intrinsically sized")
        XCTAssertLessThanOrEqual(shortModel.frame.maxX, max(shortTitle.frame.maxX, shortReasoning.frame.maxX) + 16,
            "The short model button should end at its visible text padding instead of filling the row")
        if isRunningOniPad {
            XCTAssertGreaterThanOrEqual(shortSend.frame.minX - shortModel.frame.maxX, 100,
                "The 650-point iPad fixture should retain substantial space after the short model")
        }
        capture(short, "Assistant-Short-Model-Before-Menu")
        shortModel.tap()
        XCTAssertTrue(short.collectionViews.buttons["Model"].firstMatch.waitForExistence(timeout: 3))
        capture(short, "Assistant-Short-Model-Menu-Open")
        short.terminate()

        let long = launch(window: true, longModel: true, narrow: true, assistant: true)
        let input = long.textViews["chat.input"]
        let model = long.buttons["chat.composer.model"]
        let menu = long.buttons["chat.composer.menu"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(model.frame.width, 44)
        XCTAssertGreaterThanOrEqual(model.frame.height, 44)
        XCTAssertLessThanOrEqual(model.frame.maxX, input.frame.maxX + 1,
            "The long model label must fit the actual 320-point composer pane")
        XCTAssertGreaterThanOrEqual(long.buttons["chat.composer.menu"].frame.width, 44)
        XCTAssertGreaterThanOrEqual(long.buttons["chat.composer.menu"].frame.height, 44)
        capture(long, "Assistant-320-Long-Model")
        model.tap()
        XCTAssertTrue(long.collectionViews.buttons["Model"].firstMatch.waitForExistence(timeout: 3))
        capture(long, "Assistant-320-Model-Menu-Open")
        long.terminate()
    }

    private func assertAssistantHeaderLayout(_ app: XCUIApplication, expectsLeading: Bool = false) {
        let header = app.buttons["chat.header"]
        let context = app.buttons["chat.toolbar.context"]
        let bar = app.navigationBars.firstMatch
        let back = bar.buttons["Sessions"]
        let headerFrame = header.exists ? header.frame : .null
        let contextFrame = context.exists ? context.frame : .null
        let trailingGap = context.exists ? bar.frame.maxX - contextFrame.maxX : .infinity
        let leadingSafeGap = back.exists ? back.frame.minX - bar.frame.minX : .infinity
        let geometry = XCTAttachment(string: "app=\(app.frame) navigationBar=\(bar.frame) back=\(back.exists ? back.frame : .null) headerExists=\(header.exists) headerHittable=\(header.isHittable) header=\(headerFrame) contextExists=\(context.exists) contextHittable=\(context.isHittable) context=\(contextFrame) leadingSafeGap=\(leadingSafeGap) trailingGap=\(trailingGap)")
        geometry.name = "Assistant-Toolbar-Frame-Evidence"
        geometry.lifetime = .keepAlways
        add(geometry)

        XCTAssertTrue(header.isHittable)
        XCTAssertTrue(context.isHittable)
        XCTAssertEqual(context.frame.width, 44, accuracy: 1)
        XCTAssertGreaterThanOrEqual(context.frame.minX, header.frame.maxX)
        XCTAssertLessThanOrEqual(context.frame.minX - header.frame.maxX, 4.5)

        XCTAssertLessThanOrEqual(context.frame.maxX, bar.frame.maxX)
        if expectsLeading {
            XCTAssertTrue(back.exists)
            XCTAssertGreaterThanOrEqual(header.frame.minX, back.frame.maxX - 8,
                "The Assistant title should remain beside the native back control in landscape")
            XCTAssertLessThanOrEqual(header.frame.minX - back.frame.maxX, 24,
                "The Assistant title should not leave a large gap after the native back control")
            XCTAssertLessThan(header.frame.midX, bar.frame.midX,
                "The Assistant group should remain leading in landscape")
        }
        if !expectsLeading && app.frame.width < 600 {
            XCTAssertGreaterThan(context.frame.midX, bar.frame.midX,
                "The Assistant pill should remain trailing in portrait")
            // Liquid Glass extends four points beyond the context button's AX hit frame.
            XCTAssertEqual(trailingGap, 24, accuracy: 1, "The single Assistant pill should reach the 20-point visual margin")
        }
        XCTAssertFalse(bar.buttons["More"].exists)
        XCTAssertFalse(bar.buttons["ellipsis"].exists)
        XCTAssertFalse(bar.buttons["More actions"].exists)
    }

    private func waitForLandscape(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if app.frame.width > app.frame.height { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForPortrait(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if app.frame.height > app.frame.width { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func launch(window: Bool, large: Bool = false, longModel: Bool = false, narrow: Bool = false,
                        shortTitle: Bool = false, assistant: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_HEADER_FIXTURE"] = "1"
        app.launchEnvironment["OPENCLIENT_HEADER_WINDOW"] = window ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_MANY_AGENTS"] = large ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_LONG_MODEL"] = longModel ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_NARROW"] = narrow ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_SHORT_TITLE"] = shortTitle ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_ASSISTANT"] = assistant ? "1" : "0"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
