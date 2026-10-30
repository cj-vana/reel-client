import XCTest
@testable import Reel

@MainActor final class BrowseOptionsReaderTests: XCTestCase {
    private actor Source {
        var pages: [ItemPage]
        var calls: [(String, [String: String])] = []
        init(_ pages: [ItemPage]) { self.pages = pages }
        func page(_ path: String, query: [String: String]) throws -> ItemPage {
            calls.append((path, query))
            guard !pages.isEmpty else { throw BrowseOptionsError.incomplete }
            return pages.removeFirst()
        }
    }
    private func items(_ count: Int, start: Int = 0) -> [MediaItem] { (start..<(start + count)).map { MediaItem(Id: "genre-\($0)", Name: "Genre \($0)") } }

    func testUserViewsUsesOnlyItsRealUnpaginatedContract() async throws {
        let source = Source([ItemPage(Items: items(3), TotalRecordCount: 3)])
        let result = try await BrowseOptionsReader.libraries { try await source.page($0, query: $1) }
        let calls = await source.calls
        XCTAssertEqual(result.count, 3); XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "UserViews"); XCTAssertTrue(calls[0].1.isEmpty)
    }

    func testTruncatedUserViewsCannotBeUsedToEraseSavedIdentifiers() async throws {
        let source = Source([ItemPage(Items: items(1), TotalRecordCount: 2)])
        do { _ = try await BrowseOptionsReader.libraries { try await source.page($0, query: $1) }; XCTFail("Incomplete options were admitted") }
        catch BrowseOptionsError.incomplete { }
    }

    func testGenresReadsBeyondTwoHundredWithCompleteRawCursor() async throws {
        let source = Source([ItemPage(Items: items(200), TotalRecordCount: 402),
                             ItemPage(Items: items(200, start: 200), TotalRecordCount: 402),
                             ItemPage(Items: items(2, start: 400), TotalRecordCount: 402)])
        let result = try await BrowseOptionsReader.genres(query: ["includeItemTypes": "Episode", "parentId": "library"]) { try await source.page($0, query: $1) }
        let calls = await source.calls
        XCTAssertEqual(calls.map { $0.1["startIndex"] }, ["0", "200", "400"])
        XCTAssertTrue(calls.allSatisfy { $0.0 == "Genres" && $0.1["includeItemTypes"] == "Episode" && $0.1["parentId"] == "library" })
        XCTAssertEqual(result.count, 402); XCTAssertEqual(result.last?.id, "genre-401")
    }

    func testOverlappingGenrePagesCannotProveAnUnseenIdentifierWasRemoved() async throws {
        let source = Source([ItemPage(Items: items(200), TotalRecordCount: 201),
                             ItemPage(Items: items(1, start: 199), TotalRecordCount: 201)])
        do { _ = try await BrowseOptionsReader.genres(query: [:]) { try await source.page($0, query: $1) }; XCTFail("Overlapping options were admitted as a coherent complete set") }
        catch BrowseOptionsError.incomplete { }
    }

    func testUnknownTotalTerminatesOnlyOnAShortRawPage() async throws {
        let source = Source([ItemPage(Items: items(200)), ItemPage(Items: items(1, start: 200))])
        let result = try await BrowseOptionsReader.genres(query: [:]) { try await source.page($0, query: $1) }
        let calls = await source.calls
        XCTAssertEqual(result.count, 201); XCTAssertEqual(calls.count, 2)
    }

    func testEarlyEmptyAndChangingTotalsRefusePartialValidation() async throws {
        for pages in [[ItemPage(Items: items(1), TotalRecordCount: 3), ItemPage(Items: [], TotalRecordCount: 3)],
                      [ItemPage(Items: items(1), TotalRecordCount: 3), ItemPage(Items: items(1, start: 1), TotalRecordCount: 4)]] {
            let source = Source(pages)
            do { _ = try await BrowseOptionsReader.genres(query: [:]) { try await source.page($0, query: $1) }; XCTFail("Partial/changing options were admitted") }
            catch BrowseOptionsError.incomplete { }
        }
    }

    func testMalformedEmptyIdentifierCannotValidateSavedChoices() async throws {
        let source = Source([ItemPage(Items: [MediaItem(Id: "", Name: "Invalid")], TotalRecordCount: 1)])
        do { _ = try await BrowseOptionsReader.genres(query: [:]) { try await source.page($0, query: $1) }; XCTFail("Invalid options were admitted") }
        catch BrowseOptionsError.malformed { }
    }

    func testBoundedCapacityRefusesRatherThanSilentlyTruncating() async throws {
        let source = Source((0..<100).map { ItemPage(Items: items(200, start: $0 * 200)) })
        do { _ = try await BrowseOptionsReader.genres(query: [:]) { try await source.page($0, query: $1) }; XCTFail("An unbounded option set was admitted as complete") }
        catch BrowseOptionsError.capacity { }
        let calls = await source.calls
        XCTAssertEqual(calls.count, 100)
    }
}
