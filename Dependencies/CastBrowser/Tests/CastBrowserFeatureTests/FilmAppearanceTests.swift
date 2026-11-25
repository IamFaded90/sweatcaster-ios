import XCTest
@testable import CastBrowserFeature

final class FilmAppearanceTests: XCTestCase {
    func testSavedLightSpellingsRemainLightWithADarkApp() {
        for saved in ["Lys", "Lyst"] {
            let theme = FilmAppearance(storedValue: saved)
            XCTAssertEqual(theme, .light)
            XCTAssertFalse(theme.usesDarkAppearance(appIsDark: true))
        }
    }

    func testFollowAppChangesWithTheAppWithoutOverridingSavedChoices() {
        let automatic = FilmAppearance(storedValue: "System")
        XCTAssertTrue(automatic.usesDarkAppearance(appIsDark: true))
        XCTAssertFalse(automatic.usesDarkAppearance(appIsDark: false))
        XCTAssertTrue(FilmAppearance(storedValue: "Mørk").usesDarkAppearance(appIsDark: false))
        XCTAssertFalse(FilmAppearance(storedValue: "Lyst").usesDarkAppearance(appIsDark: true))
    }

    func testMissingOrUnrecognisedValuesFollowTheApp() {
        for saved in ["", "removed-theme"] {
            XCTAssertEqual(FilmAppearance(storedValue: saved), .followApp)
        }
    }
}
