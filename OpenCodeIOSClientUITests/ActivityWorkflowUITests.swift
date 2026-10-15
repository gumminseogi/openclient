import XCTest

/// Run on both required simulator classes. The Activity screenshot scene does not
/// route session selection into the root navigation shell. Metadata mutation uses
/// the opt-in in-memory workflow backend fixture.
final class ActivityWorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBoardSnapsMiddleColumnsAndAlignsEndColumns() {
        let app = launchActivity()
        var customIDs: [String] = []
        for title in ["Ready", "Review", "Waiting"] {
            chooseDisplayOption("New Status", in: app)
            let name = app.textFields["activity.statusName"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText(title)
            app.buttons["activity.saveStatus"].tap()
            XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        }
        chooseDisplayOption("Status", in: app)
        let headers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.section."))
        for header in headers.allElementsBoundByIndex {
            let id = String(header.identifier.dropFirst("activity.section.".count))
            if id != "in-progress" && id != "archived" { customIDs.append(id) }
        }
        XCTAssertEqual(customIDs.count, 3)
        chooseDisplayOption("Board", in: app)
        let board = element("activity.board", in: app)
        let first = element("activity.column.in-progress", in: app)
        let last = element("activity.column.archived", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let viewport = board.frame
        capture(app, "board-first-edge")
        XCTAssertEqual(first.frame.minX, viewport.minX + 16, accuracy: 3,
                       "First column must align to the UI margin, not the center")

        let middle = element("activity.column.\(customIDs[1])", in: app)
        for _ in 0..<6 {
            if middle.exists && abs(middle.frame.midX - viewport.midX) < 3 { break }
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)))
        }
        capture(app, "board-middle-centered-neighbors")
        XCTAssertEqual(middle.frame.midX, viewport.midX, accuracy: 3)
        for id in [customIDs[0], customIDs[2]] {
            let neighbor = element("activity.column.\(id)", in: app)
            XCTAssertGreaterThan(neighbor.frame.intersection(viewport).width, 12, "Both neighbors must peek into the viewport")
        }

        for _ in 0..<6 {
            if last.exists && abs(last.frame.maxX - viewport.maxX + 16) < 3 { break }
            board.swipeLeft()
        }
        capture(app, "board-last-edge")
        XCTAssertEqual(last.frame.maxX, viewport.maxX - 16, accuracy: 3,
                       "Last column must align to the UI margin, not the center")
        for _ in 0..<6 {
            if abs(first.frame.minX - viewport.minX - 16) < 3 { break }
            board.swipeRight()
        }
        capture(app, "board-first-edge-return")
        XCTAssertEqual(first.frame.minX, viewport.minX + 16, accuracy: 3)
    }

    @MainActor
    func testRecentStatusListBoardAndArchiveVisibility() {
        let app = launchActivity()
        chooseDisplayOption("Recent", in: app)
        XCTAssertTrue(app.buttons["activity.session.session-screenshot-release"].waitForExistence(timeout: 5))
        capture(app, "workflow-recent")

        chooseDisplayOption("Status", in: app)
        XCTAssertTrue(element("activity.statusList", in: app).waitForExistence(timeout: 5))
        capture(app, "workflow-status-list")

        chooseDisplayOption("Board", in: app)
        XCTAssertTrue(element("activity.board", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("activity.column.in-progress", in: app).exists)
        capture(app, "workflow-board")

        // Normalize the persisted preference through UI before testing both states.
        let archived = element("activity.column.archived", in: app)
        if !archived.exists {
            chooseDisplayOption("Show Archived", in: app)
        }
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        chooseDisplayOption("Show Archived", in: app)
        XCTAssertTrue(archived.waitForNonExistence(timeout: 5))
        capture(app, "workflow-board-archive-hidden")
        chooseDisplayOption("Show Archived", in: app)
        XCTAssertTrue(archived.waitForExistence(timeout: 5))

        chooseDisplayOption("List", in: app)
        XCTAssertTrue(element("activity.statusList", in: app).waitForExistence(timeout: 5))
        capture(app, "workflow-status-list-restored")
        chooseDisplayOption("Recent", in: app)
        XCTAssertTrue(element("activity.statusList", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["activity.session.session-screenshot-release"].exists)
    }

    @MainActor
    func testCreateCustomStatusSheet() {
        let app = launchActivity()
        chooseDisplayOption("Recent", in: app)
        chooseDisplayOption("New Status", in: app)
        let name = app.textFields["activity.statusName"]
        let save = app.buttons["activity.saveStatus"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        name.tap()
        name.typeText("   ")
        XCTAssertFalse(save.isEnabled, "Whitespace alone must not create a status")
        name.typeText("QA Review")
        XCTAssertTrue(save.isEnabled)
        capture(app, "workflow-new-status-preview")
        save.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))

        chooseDisplayOption("Status", in: app)
        // Collapsible headers expose the combined name/count as a Button.
        let heading = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "activity.section.", "QA Review"
        )).firstMatch
        for _ in 0..<12 {
            if heading.exists && heading.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(heading.exists, "Saved custom status must appear in the workflow list")
        XCTAssertTrue(heading.isHittable)
        capture(app, "workflow-custom-status-created")
        chooseDisplayOption("Recent", in: app)
    }

    @MainActor
    func testArchivedSectionCollapseAndReexpand() {
        let app = launchActivity()
        chooseDisplayOption("Status", in: app)
        let archived = app.buttons["activity.section.archived"]
        let release = app.buttons["activity.session.session-screenshot-release"]
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        waitForSectionValue("Expanded", header: archived)
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        capture(app, "workflow-list-before-collapse")

        archived.tap()
        waitForSectionValue("Collapsed", header: archived)
        // This fixture's existing sessions are all in Archived. Verify removal
        // from the accessibility tree, rather than merely scrolling out of view.
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.session."))
        let cardsHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in cards.count == 0 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cardsHidden], timeout: 5), .completed)
        capture(app, "workflow-list-archived-collapsed")

        archived.tap()
        waitForSectionValue("Expanded", header: archived)
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        XCTAssertTrue(release.isHittable)
        capture(app, "workflow-list-archived-reexpanded")
    }

    @MainActor
    func testDropOnCollapsedHeaderAutoexpandsSection() {
        let app = launchActivity()
        chooseDisplayOption("Status", in: app)
        let destination = app.buttons["activity.section.in-progress"]
        let source = app.buttons["activity.session.session-screenshot-release"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        waitForSectionValue("Expanded", header: destination)
        destination.tap()
        waitForSectionValue("Collapsed", header: destination)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(destination.isHittable)
        capture(app, "workflow-list-before-header-drop")

        // Use the OS drag gesture, not a header tap. Autoexpansion is the
        // observable acknowledgement that the typed drop callback accepted it.
        source.press(forDuration: 1.0, thenDragTo: destination)
        waitForSectionValue("Expanded", header: destination)
        capture(app, "workflow-list-after-header-drop")
        // No session-migration assertion: this fixture has no metadata backend.
    }

    @MainActor
    func testSessionCardExpandsAndCompactsAfterRepeatedStatusDrags() {
        let app = launchActivity(mutationFixture: true)
        chooseDisplayOption("Status", in: app)
        let inProgress = app.buttons["activity.section.in-progress"]
        let archived = app.buttons["activity.section.archived"]
        let source = app.buttons["activity.session.session-screenshot-release"]
        let assistant = element("activity.session.session-screenshot-release.latest-assistant", in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        XCTAssertTrue(inProgress.waitForExistence(timeout: 5))
        waitForSectionValue("Expanded", header: archived)
        waitForSectionValue("Expanded", header: inProgress)
        XCTAssertFalse(assistant.exists)
        XCTAssertGreaterThan(source.frame.minY, archived.frame.maxY)
        let compactHeight = source.frame.height
        XCTAssertGreaterThan(compactHeight, 0)
        capture(app, "workflow-mutation-initial-compact")

        for iteration in 1...2 {
            XCTAssertTrue(source.isHittable)
            XCTAssertTrue(inProgress.isHittable)
            dragCard(source, to: inProgress)
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard source.exists, archived.exists else { return false }
                return source.frame.maxY <= archived.frame.minY
                    && source.frame.height > compactHeight + 30
            }, object: nil)
            let expansionResult = XCTWaiter.wait(for: [expanded], timeout: 10)
            capture(app, "workflow-mutation-expanded-\(iteration)")
            XCTAssertEqual(expansionResult, .completed,
                           "Same session must move above Archived and grow from \(compactHeight)pt to expanded height; got \(source.frame) (round \(iteration))")
            XCTAssertTrue(assistant.exists || source.label.contains("The newest sentence"),
                          "Expanded card must contain its seeded assistant preview, not just a taller header")

            XCTAssertTrue(source.isHittable)
            XCTAssertTrue(archived.isHittable)
            dragCard(source, to: archived)
            let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard source.exists, archived.exists, !assistant.exists else { return false }
                return source.frame.minY >= archived.frame.maxY
                    && abs(source.frame.height - compactHeight) <= 5
            }, object: nil)
            let compactionResult = XCTWaiter.wait(for: [compact], timeout: 10)
            capture(app, "workflow-mutation-recompacted-\(iteration)")
            XCTAssertEqual(compactionResult, .completed,
                           "Same session must return below Archived without preview and recover its compact height (round \(iteration))")
        }
    }

    @MainActor
    func testEditAndDeleteCustomStatusMovesSessionToArchived() {
        let app = launchActivity(mutationFixture: true)
        let custom = createReviewStatus(in: app)
        let statusID = String(custom.identifier.dropFirst("activity.section.".count))
        let source = app.buttons["activity.session.session-screenshot-release"]
        let archived = app.buttons["activity.section.archived"]
        reveal(source, in: app)
        let compactHeight = source.frame.height
        source.press(forDuration: 1.0)
        let statusOption = app.buttons["activity.status.\(statusID)"]
        if !statusOption.exists {
            let statusMenu = app.buttons["Status"]
            XCTAssertTrue(statusMenu.waitForExistence(timeout: 5))
            statusMenu.tap()
        }
        XCTAssertTrue(statusOption.waitForExistence(timeout: 5))
        statusOption.tap()
        let grouped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard source.exists, custom.exists, archived.exists else { return false }
            return source.frame.minY >= custom.frame.maxY && source.frame.maxY <= archived.frame.minY
                && source.frame.height > compactHeight + 30
        }, object: nil)
        let groupingResult = XCTWaiter.wait(for: [grouped], timeout: 10)
        capture(app, "workflow-custom-status-assigned")
        XCTAssertEqual(groupingResult, .completed)

        reveal(custom, in: app)
        custom.press(forDuration: 1.0)
        let edit = app.buttons["activity.editStatus.\(statusID)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let name = app.textFields["activity.statusName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "QA Review")
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "QA Review".count))
        name.typeText("Ready for Review")
        capture(app, "workflow-edit-custom-status")
        tapWhenHittable(app.buttons["activity.saveStatus"])
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        let renamed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Ready for Review"), object: custom
        )
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 5), .completed,
                       "Renaming must preserve the custom status identifier")

        reveal(custom, in: app)
        custom.press(forDuration: 1.0)
        let delete = app.buttons["activity.deleteStatus.\(statusID)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let replacement = element("activity.replacementStatus", in: app)
        tapWhenHittable(replacement)
        let archivedOption = app.buttons["Archived"]
        XCTAssertTrue(archivedOption.waitForExistence(timeout: 5))
        archivedOption.tap()
        capture(app, "workflow-delete-populated-status")
        tapWhenHittable(app.buttons["activity.confirmDeleteStatus"])
        XCTAssertTrue(custom.waitForNonExistence(timeout: 10))
        reveal(source, in: app)
        let assistant = element("activity.session.session-screenshot-release.latest-assistant", in: app)
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard source.exists, archived.exists else { return false }
            return source.frame.minY >= archived.frame.maxY
                && abs(source.frame.height - compactHeight) <= 5 && !assistant.exists
        }, object: nil)
        let compactionResult = XCTWaiter.wait(for: [compact], timeout: 10)
        capture(app, "workflow-deleted-status-session-archived")
        XCTAssertEqual(compactionResult, .completed)
    }

    @MainActor
    func testDeleteEmptyCustomStatus() {
        let app = launchActivity(mutationFixture: true)
        let custom = createReviewStatus(in: app)
        let statusID = String(custom.identifier.dropFirst("activity.section.".count))
        reveal(custom, in: app)
        custom.press(forDuration: 1.0)
        let delete = app.buttons["activity.deleteStatus.\(statusID)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["activity.confirmDeleteStatus"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture(app, "workflow-delete-empty-status")
        tapWhenHittable(confirm)
        XCTAssertTrue(custom.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["activity.section.in-progress"].exists)
        XCTAssertTrue(app.buttons["activity.section.archived"].exists)
        XCTAssertTrue(app.buttons["activity.session.session-screenshot-release"].exists)
        capture(app, "workflow-empty-status-deleted")
    }

    @MainActor
    private func createReviewStatus(in app: XCUIApplication) -> XCUIElement {
        chooseDisplayOption("New Status", in: app)
        let name = app.textFields["activity.statusName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("QA Review")
        tapWhenHittable(app.buttons["activity.saveStatus"])
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        chooseDisplayOption("Status", in: app)
        let custom = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "activity.section.", "QA Review"
        )).firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        // Resolve to the stable UUID now: the name-based query must not change
        // identity when the editor renames this same section.
        return app.buttons[custom.identifier]
    }

    @MainActor
    private func tapWhenHittable(_ target: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: target
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        target.tap()
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["activity.statusList"]
        for _ in 0..<4 {
            if target.exists && target.isHittable { return }
            scroll.swipeUp()
        }
        for _ in 0..<8 {
            if target.exists && target.isHittable { return }
            scroll.swipeDown()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Expected visible workflow control: \(target.identifier)")
    }

    @MainActor
    private func dragCard(_ card: XCUIElement, to header: XCUIElement) {
        // Start on the card's identity area in either layout. Holding at the
        // expanded card's text-center for a full second opens its context menu.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
            .press(forDuration: 0.5, thenDragTo: header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }

    @MainActor
    private func waitForSectionValue(_ value: String, header: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: header
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected \(header.identifier) to be \(value)")
    }

    @MainActor
    private func launchActivity(mutationFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "activity"
        if mutationFixture {
            app.launchEnvironment["OPENCLIENT_WORKFLOW_MUTATION_FIXTURE"] = "1"
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["screenshot.scene.activity"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func chooseDisplayOption(_ title: String, in app: XCUIApplication) {
        let display = app.buttons["activity.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Missing display option: \(title)")
        option.tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = app.screenshot()
        // Keep a directly inspectable copy even if Xcode stalls while finalizing
        // a failed test's result bundle.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkflowVisualTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        let screenshot = XCTAttachment(screenshot: image)
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
