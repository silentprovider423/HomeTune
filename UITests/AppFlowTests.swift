import XCTest

/// Klopft die P1-Abläufe ab (Mediathek → Album → Wiedergabe → Mini-Player → Jetzt läuft → Warteliste/Liedtext,
/// Kontextmenü „Als Nächstes“, Suche, Playlist anlegen) – angemeldet mit dem Demo-Konto.
/// Mit SHOT_DIR=<Ordner> werden Bildschirmfotos für die README gespeichert.
final class AppFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["HOMETUNE_SERVER"], let user = env["HOMETUNE_DEMO_USER"], let pw = env["HOMETUNE_DEMO_PASSWORD"] else {
            throw XCTSkip("Kein Testserver in der Umgebung")
        }
        app = XCUIApplication()
        app.launchEnvironment = ["HOMETUNE_SERVER": server, "HOMETUNE_USER": user, "HOMETUNE_PASSWORD": pw]
        if english { app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] }
        app.launch()
    }

    /// UI_LANG=en: Oberfläche auf Englisch (für die README-Screenshots)
    var english: Bool { ProcessInfo.processInfo.environment["UI_LANG"] == "en" }
    func t(_ de: String, _ en: String) -> String { english ? en : de }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func tapTab(_ name: String) {
        let b = app.tabBars.buttons[name]
        if b.waitForExistence(timeout: 5) { b.tap() } else { app.buttons[name].firstMatch.tap() }
    }

    func testMainFlow() throws {
        tapTab(t("Mediathek", "Library"))
        let albums = app.buttons["section.albums"].firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 15))
        // „Zuletzt hinzugefügt“ laden lassen
        _ = app.staticTexts[t("Zuletzt hinzugefügt", "Recently Added")].waitForExistence(timeout: 15)
        sleep(2)
        shot("1-library")

        albums.tap()
        let album = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Harbor Lights")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        sleep(1)
        shot("2-albums")
        album.tap()

        let play = app.buttons["play.button"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        sleep(1)
        shot("3-album")
        play.tap()

        // Mini-Player zeigt den Titel, Wiedergabe läuft
        let mini = app.otherElements["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        let pause = app.buttons["mini.playPause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(25)
        while pause.label != "Pause" && Date() < deadline { sleep(1) }
        XCTAssertEqual(pause.label, "Pause", "Wiedergabe läuft")

        // Kontextmenü: Als Nächstes wiedergeben
        let track = app.cells.containing(.any, identifier: "track.3").firstMatch
        if track.waitForExistence(timeout: 3) {
            track.press(forDuration: 1.2)
            let next = app.buttons[t("Als Nächstes wiedergeben", "Play Next")].firstMatch
            if next.waitForExistence(timeout: 3) { next.tap() }
        }

        // Jetzt läuft
        mini.tap()
        let badge = app.descendants(matching: .any)["badge432"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "432-Hz-Kennzeichen sichtbar")
        sleep(3)
        shot("4-now-playing")

        app.buttons["nowPlaying.queue"].firstMatch.tap()
        XCTAssertTrue(app.buttons["queue.shuffle"].firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        shot("5-queue")
        app.buttons["queue.repeat"].firstMatch.tap()

        app.buttons["nowPlaying.lyrics"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["lyrics"].firstMatch.waitForExistence(timeout: 8))
        // Demo-Titel „Velvet“ hat einen zeitsynchronen Liedtext (.lrc auf dem Testserver)
        if app.staticTexts["Soft as velvet, slow as rain"].firstMatch.waitForExistence(timeout: 8) {
            sleep(2)
            shot("8-lyrics")
        }

        app.buttons["nowPlaying.next"].firstMatch.tap()
        app.buttons["nowPlaying.lyrics"].firstMatch.tap()
        app.buttons["nowPlaying.playPause"].firstMatch.tap()
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5), "Nach unten wischen schließt „Jetzt läuft“")
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
    }

    func testSearchAndHome() throws {
        tapTab(t("Startseite", "Home"))
        XCTAssertTrue(app.buttons["home.shuffleAll"].firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        shot("7-home")

        tapTab(t("Suchen", "Search"))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Northern")
        XCTAssertTrue(app.staticTexts["Northern Lights"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        shot("6-search")
    }

    func testCreateAndDeletePlaylist() throws {
        tapTab(t("Mediathek", "Library"))
        let section = app.buttons["section.playlists"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 15))
        section.tap()
        app.buttons["playlist.new"].firstMatch.tap()
        let name = app.textFields["playlist.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let title = "UI Test \(Int.random(in: 1000...9999))"
        name.typeText(title)
        app.buttons["playlist.addMusic"].firstMatch.tap()
        let rows = app.buttons.matching(identifier: "addMusic.row")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 8))
        rows.element(boundBy: 0).tap()
        rows.element(boundBy: 1).tap()
        app.buttons["addMusic.done"].firstMatch.tap()
        app.buttons["playlist.done"].firstMatch.tap()

        let created = app.staticTexts[title].firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        created.press(forDuration: 1.2)
        let del = app.buttons[t("Playlist löschen", "Delete Playlist")].firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 5))
        del.tap()
        let confirm = app.buttons[t("Playlist löschen", "Delete Playlist")].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(created.waitForNonExistence(timeout: 10))
    }
}
