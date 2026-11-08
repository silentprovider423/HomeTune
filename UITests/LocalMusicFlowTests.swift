import XCTest

/// „Musik auf diesem iPhone“ ohne Server: Anmeldung überspringen, Ordner einlesen, Album öffnen und abspielen
/// (Player ohne Hz-Hinweis), Dateien-Dialog öffnen, HomeTune-Ordner und Playlists auf diesem iPhone. Die Testdateien (erfundene Titel, Sinus/Stille) kommen
/// aus Tests/Fixtures und werden über den Debug-Hook HOMETUNE_LOCAL_IMPORT per Bookmark eingelesen – der
/// Dateien-Dialog selbst läuft außerhalb der App und wird nur geöffnet und wieder geschlossen.
/// Mit SHOT_DIR=<Ordner> entsteht das README-Bildschirmfoto „9-on-this-iphone“.
final class LocalMusicFlowTests: XCTestCase {
    var app: XCUIApplication!

    var english: Bool { ProcessInfo.processInfo.environment["UI_LANG"] == "en" }
    func t(_ de: String, _ en: String) -> String { english ? en : de }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func fixture(_ name: String) throws -> String {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)).appending(path: name).path
    }

    /// Start ohne Konto, mit leerer lokaler Mediathek; optional Ordner einlesen.
    private func launch(importing folders: [String]) {
        app = XCUIApplication()
        app.launchEnvironment = ["HOMETUNE_SIGNED_OUT": "1", "HOMETUNE_LOCAL_RESET": "1",
                                 "HOMETUNE_LOCAL_IMPORT": folders.joined(separator: "|")]
        if english { app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] }
        app.launch()
    }

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

    /// Anmeldung überspringen, damit die Mediathek nur Musik auf diesem iPhone zeigt.
    private func continueWithoutServer() {
        let skip = app.buttons["login.localOnly"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 15), "Weg „Ohne Server fortfahren“ auf dem Anmeldebildschirm")
        skip.tap()
        tapTab(t("Mediathek", "Library"))
    }

    func testPlayLocalAlbumWithoutServer() throws {
        launch(importing: [try fixture("LocalMusic")])
        continueWithoutServer()
        // Ohne Server kein „Geladen“, aber Playlists auf diesem iPhone und „Auf diesem iPhone“
        XCTAssertFalse(app.buttons["section.downloaded"].exists)
        XCTAssertTrue(app.buttons["section.playlists"].waitForExistence(timeout: 5))
        let section = app.buttons["section.onThisIPhone"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        section.tap()

        let albums = app.buttons["local.albums"].firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Morning Set"].firstMatch.waitForExistence(timeout: 15), "Ordner eingelesen")
        albums.tap()
        let album = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Night Drive")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        album.tap()
        XCTAssertTrue(app.staticTexts["Tunnel Lights"].firstMatch.waitForExistence(timeout: 10))
        let play = app.buttons["play.button"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()

        let pause = app.buttons["mini.playPause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while pause.label != "Pause" && Date() < deadline { sleep(1) }
        XCTAssertEqual(pause.label, "Pause", "lokale Datei läuft")

        app.otherElements["miniPlayer"].firstMatch.tap()
        XCTAssertTrue(app.buttons["nowPlaying.queue"].firstMatch.waitForExistence(timeout: 10), "„Jetzt läuft“ offen")
        let hz = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", " Hz"))
        XCTAssertEqual(hz.count, 0, "kein Hz-Hinweis im Player")
        // Testtitel sind nur 2 s lang – je nach Tempo läuft schon der zweite
        let title = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Neon Rain", "Tunnel Lights"])).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["nowPlaying.playPause"].firstMatch.tap()
        app.swipeDown(velocity: .fast)

        // Suche findet lokale Titel
        tapTab(t("Suchen", "Search"))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Paper")
        XCTAssertTrue(app.staticTexts["Paper Boats"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Eigene Playlist ohne Server: anlegen, Titel hinzufügen, erscheint gekennzeichnet in „Playlists“, löschen.
    /// Dazu der feste Eintrag „HomeTune-Ordner“ mit Erklärung.
    func testLocalPlaylistAndAppFolder() throws {
        launch(importing: [try fixture("LocalMusic")])
        continueWithoutServer()
        let local = app.buttons["section.onThisIPhone"].firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        local.tap()
        XCTAssertTrue(app.staticTexts[t("HomeTune-Ordner", "HomeTune Folder")].firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<4 where !app.descendants(matching: .any)["local.appFolderHint"].firstMatch.exists { app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any)["local.appFolderHint"].firstMatch.exists, "Erklärung zum HomeTune-Ordner")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["section.playlists"].firstMatch.tap()
        app.buttons["playlist.new"].firstMatch.tap()
        let name = app.textFields["playlist.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let title = "Lokal \(Int.random(in: 1000...9999))"
        name.typeText(title)
        app.buttons["playlist.addMusic"].firstMatch.tap()
        let rows = app.buttons.matching(identifier: "addMusic.row")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 8), "lokale Titel zur Auswahl")
        rows.element(boundBy: 0).tap()
        rows.element(boundBy: 1).tap()
        app.buttons["addMusic.done"].firstMatch.tap()
        app.buttons["playlist.done"].firstMatch.tap()

        let created = app.staticTexts[title].firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playlist.local"].firstMatch.exists, "als „Auf diesem iPhone“ gekennzeichnet")
        created.press(forDuration: 1.2)
        let del = app.buttons[t("Playlist löschen", "Delete Playlist")].firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 5))
        del.tap()
        let confirm = app.buttons[t("Playlist löschen", "Delete Playlist")].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(created.waitForNonExistence(timeout: 10))
    }

    func testAddMusicOpensFilesDialog() throws {
        launch(importing: [])
        continueWithoutServer()
        // Leerer Zustand bietet Ordner und Dateien an
        let addFolder = app.buttons["local.empty.addFolder"].firstMatch
        XCTAssertTrue(addFolder.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["local.empty.addFiles"].firstMatch.exists)
        app.buttons["local.empty.addFiles"].firstMatch.tap()
        // Dateien-Dialog (läuft außerhalb der App) erscheint und lässt sich schließen
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "Dateien-Dialog geöffnet")
        closePicker()
        let closed = Date().addingTimeInterval(15)
        while !addFolder.isHittable && Date() < closed { sleep(1) }   // Dialog schließt noch
        XCTAssertTrue(addFolder.isHittable)
        // Auch über das Menü „…“ der Mediathek
        app.buttons["library.more"].firstMatch.tap()
        XCTAssertTrue(app.buttons["local.addFolder"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["local.addFolder"].firstMatch.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "Ordner-Auswahl geöffnet")
        closePicker()
    }

    /// Navigationsleiste des Dateien-Dialogs (Texte folgen der Systemsprache, nicht der App)
    private var picker: XCUIElement { app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].firstMatch }

    /// „Abbrechen“ ist in Unterordnern eingeklappt – dann per Wischen schließen.
    private func closePicker() {
        sleep(1)
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Abbrechen", "Cancel"])).firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() } else { app.swipeDown(velocity: .fast) }
    }

    /// Echter Dateien-Dialog, soweit im Simulator automatisierbar: Durchsuchen → Auf meinem iPhone →
    /// „HomeTune Demo“ → Datei markieren. Das abschließende „Öffnen“ kommt im iOS-26-Simulator nicht bei der
    /// App an (der Dialog läuft in einem eigenen Prozess) – das Einlesen selbst prüfen die anderen Tests über
    /// HOMETUNE_LOCAL_IMPORT. Vorher `SIM=<UDID> tools/sim-files.sh`, dann mit TEST_RUNNER_PICKER=1 starten.
    func testFilesDialogShowsMusicOnThisIPhone() throws {
        guard ProcessInfo.processInfo.environment["PICKER"] == "1" else { throw XCTSkip("erst tools/sim-files.sh, dann PICKER=1") }
        launch(importing: [])
        continueWithoutServer()
        let addFiles = app.buttons["local.empty.addFiles"].firstMatch
        XCTAssertTrue(addFiles.waitForExistence(timeout: 10))
        addFiles.tap()
        // Der Dialog folgt der Systemsprache des Simulators (hier Deutsch)
        let browse = app.buttons["Durchsuchen"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "Dateien-Dialog geöffnet")
        browse.tap()
        let onPhone = app.staticTexts["Auf meinem iPhone"].firstMatch
        if !onPhone.waitForExistence(timeout: 5) { browse.tap() }   // zweites Tippen springt zur Übersicht
        XCTAssertTrue(onPhone.waitForExistence(timeout: 10), "Ort „Auf meinem iPhone“")
        onPhone.tap()
        let folder = app.staticTexts["HomeTune Demo"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "vorher tools/sim-files.sh ausführen")
        folder.tap()
        let sub = app.cells["Night Drive"].firstMatch
        XCTAssertTrue(sub.waitForExistence(timeout: 10))
        sub.tap()
        let file = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", "01 - Neon Rain")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Audiodateien sind auswählbar")
        file.tap()
        let open = app.buttons["Öffnen"].firstMatch
        let enabled = Date().addingTimeInterval(10)
        while !(open.exists && open.isEnabled) && Date() < enabled { sleep(1) }
        XCTAssertTrue(open.isEnabled, "Mehrfachauswahl: Datei markiert, „Öffnen“ aktiv")
        // Markierung aufheben und Dialog schließen
        file.tap()
        let cancel = app.buttons["Abbrechen"].firstMatch
        if cancel.waitForExistence(timeout: 5) && cancel.isHittable { cancel.tap() } else { app.swipeDown(velocity: .fast) }
        let closed = Date().addingTimeInterval(15)
        while !addFiles.isHittable && Date() < closed { sleep(1) }
        XCTAssertTrue(addFiles.isHittable, "Dialog geschlossen")
    }

    /// Bildschirmfoto für die README (nur mit SHOT_DIR).
    func testScreenshotOnThisIPhone() throws {
        guard ProcessInfo.processInfo.environment["SHOT_DIR"] != nil else { throw XCTSkip("nur für Bildschirmfotos") }
        launch(importing: [try fixture("LocalMusic"), try fixture("DemoAlbums")])
        continueWithoutServer()
        let section = app.buttons["section.onThisIPhone"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        section.tap()
        XCTAssertTrue(app.staticTexts["Field Recordings"].firstMatch.waitForExistence(timeout: 20))
        sleep(3)
        shot("9-on-this-iphone")
    }
}
