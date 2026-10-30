import XCTest
import SwiftUI
import PDFKit
import QuickLook
import Observation
@testable import Reel

@MainActor final class PDFReaderPersistenceTests: XCTestCase {
    private func document() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500))
        try renderer.writePDF(to: url) { context in
            for text in ["First page", "Second page", "Last page"] {
                context.beginPage()
                (text as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        return url
    }

    private func pdf(in view: UIView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.lazy.compactMap { self.pdf(in: $0) }.first
    }

    private func open(_ url: URL, canSave: @escaping @MainActor () -> Bool = { true }) async throws -> (UIWindow, PDFView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        window.rootViewController = UIHostingController(rootView: HubPDFReader(document: try XCTUnwrap(PDFDocument(url: url)), bookmarkKey: "hub-page|" + url.lastPathComponent, canSave: canSave))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        for _ in 0..<50 {
            if let view = window.rootViewController?.view, let reader = pdf(in: view),
               let restoring = reader as? HubRestoringPDFView, restoring.savedPage == nil { return (window, reader) }
            try await Task.sleep(for: .milliseconds(20)); window.layoutIfNeeded()
        }
        XCTFail("The PDF reader never restored after window layout.")
        throw CocoaError(.coderInvalidValue)
    }

    func testSavedPageRestoresAfterWindowLayoutAndSurvivesReaderRecreation() async throws {
        let url = try document(); let key = "hub-page|" + url.lastPathComponent
        defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(1, forKey: key)
        var (window, reader) = try await open(url)
        XCTAssertEqual(reader.document?.index(for: try XCTUnwrap(reader.currentPage)), 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 1, "Initial page-zero notifications must not overwrite the saved bookmark.")
        reader.go(to: try XCTUnwrap(reader.document?.page(at: 2)))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 2, "The notification must capture its page before later navigation.")
        window.isHidden = true; window.rootViewController = nil
        (window, reader) = try await open(url)
        XCTAssertEqual(reader.document?.index(for: try XCTUnwrap(reader.currentPage)), 2)
        window.isHidden = true; window.rootViewController = nil
    }

    func testOutOfRangeBookmarksClampAndStayScopedToTheirSavedFile() async throws {
        let first = try document(); let second = try document()
        let firstKey = "hub-page|" + first.lastPathComponent; let secondKey = "hub-page|" + second.lastPathComponent
        defer {
            for url in [first, second] { try? FileManager.default.removeItem(at: url) }
            for key in [firstKey, secondKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(900, forKey: firstKey); UserDefaults.standard.set(-12, forKey: secondKey)
        let (firstWindow, firstReader) = try await open(first)
        XCTAssertEqual(firstReader.document?.index(for: try XCTUnwrap(firstReader.currentPage)), 2)
        firstWindow.isHidden = true; firstWindow.rootViewController = nil
        let firstBookmark = UserDefaults.standard.integer(forKey: firstKey)
        let (secondWindow, secondReader) = try await open(second)
        XCTAssertEqual(secondReader.document?.index(for: try XCTUnwrap(secondReader.currentPage)), 0)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: firstKey), firstBookmark, "Opening a different saved file must not rewrite this bookmark.")
        secondWindow.isHidden = true; secondWindow.rootViewController = nil
    }
    func testPageNotificationsCannotWriteAfterTheOwningAccountChanges() async throws {
        let url = try document(); let key = "hub-page|" + url.lastPathComponent
        defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(1, forKey: key)
        var owns = true
        let (window, reader) = try await open(url, canSave: { owns })
        XCTAssertEqual(reader.document?.index(for: try XCTUnwrap(reader.currentPage)), 1)
        owns = false
        reader.go(to: try XCTUnwrap(reader.document?.page(at: 2)))
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: reader)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 1, "A stale PDF view cannot write the former account’s reading position.")
        window.isHidden = true; window.rootViewController = nil
    }

    func testRetainedQuickLookControllerReplacesItsPreviewWithNewSnapshotURL() async throws {
        let first = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let second = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("First owned text snapshot".utf8).write(to: first)
        try Data("Different owned text snapshot".utf8).write(to: second)
        defer { for url in [first, second] { try? FileManager.default.removeItem(at: url) } }
        let state = RetainedQuickLookState(url: first)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        window.rootViewController = UIHostingController(rootView: RetainedQuickLookHost(state: state))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func find(_ controller: UIViewController) -> QLPreviewController? {
            if let controller = controller as? QLPreviewController { return controller }
            return controller.children.lazy.compactMap { find($0) }.first
        }
        var retained: QLPreviewController?
        for _ in 0..<100 {
            window.layoutIfNeeded()
            if let root = window.rootViewController, let controller = find(root), controller.currentPreviewItem?.previewItemURL == first {
                retained = controller; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let controller = try XCTUnwrap(retained)
        XCTAssertEqual(controller.dataSource?.previewController(controller, previewItemAt: 0).previewItemURL, first)
        state.url = second
        for _ in 0..<100 {
            window.layoutIfNeeded()
            if controller.currentPreviewItem?.previewItemURL == second { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(find(try XCTUnwrap(window.rootViewController)) === controller, "The test must exercise an actually retained preview controller.")
        XCTAssertEqual(controller.dataSource?.previewController(controller, previewItemAt: 0).previewItemURL, second)
        XCTAssertEqual(controller.currentPreviewItem?.previewItemURL, second, "Reload must replace the current immutable preview item, not keep the old URL.")
    }
    func testRetainedPDFViewReplacesHealthyDocumentRestoresPageAndMovesObserverOwnership() async throws {
        let url = try document(); let firstKey = "hub-page|" + url.lastPathComponent
        let secondKey = "hub-page|" + UUID().uuidString + ".pdf"
        defer {
            try? FileManager.default.removeItem(at: url)
            for key in [firstKey, secondKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        let first = try XCTUnwrap(PDFDocument(url: url))
        let replacementBytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { context in
            for page in 1...2 {
                context.beginPage()
                ("Replacement reader · Page \(page)" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        let replacement = try XCTUnwrap(PDFDocument(data: replacementBytes))
        UserDefaults.standard.set(2, forKey: firstKey)
        UserDefaults.standard.set(0, forKey: secondKey)
        let state = RetainedPDFState(document: first, key: firstKey)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        window.rootViewController = UIHostingController(rootView: RetainedPDFHost(state: state))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        var reader: PDFView?
        for _ in 0..<50 {
            if let view = window.rootViewController?.view, let candidate = pdf(in: view),
               let restoring = candidate as? HubRestoringPDFView, restoring.savedPage == nil { reader = candidate; break }
            try await Task.sleep(for: .milliseconds(20)); window.layoutIfNeeded()
        }
        let originalView = try XCTUnwrap(reader)
        XCTAssertTrue(originalView.document === first)
        state.document = replacement
        for _ in 0..<50 {
            window.layoutIfNeeded()
            if originalView.document === replacement, (originalView as? HubRestoringPDFView)?.savedPage == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(pdf(in: try XCTUnwrap(window.rootViewController?.view)) === originalView, "The representable must update an actually retained PDFView.")
        XCTAssertTrue(originalView.document === replacement, "A valid-to-valid reload must replace the old document without relying on a loading render.")
        XCTAssertEqual(originalView.document?.pageCount, 2)
        XCTAssertTrue(originalView.document?.string?.contains("Replacement reader") == true)
        XCTAssertEqual(replacement.index(for: try XCTUnwrap(originalView.currentPage)), 1)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: firstKey), 2, "Initial layout must not clobber the original bookmark while clamping the displayed page.")
        state.key = secondKey
        for _ in 0..<50 {
            window.layoutIfNeeded()
            if let page = originalView.currentPage, replacement.index(for: page) == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        originalView.go(to: try XCTUnwrap(replacement.page(at: 1)))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: secondKey), 1)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: firstKey), 2, "Page notifications must use the new coordinator/bookmark ownership.")
    }

}

@MainActor @Observable private final class RetainedPDFState {
    var document: PDFDocument
    var key: String
    init(document: PDFDocument, key: String) { self.document = document; self.key = key }
}

private struct RetainedPDFHost: View {
    let state: RetainedPDFState
    var body: some View { HubPDFReader(document: state.document, bookmarkKey: state.key) }
}

@MainActor @Observable private final class RetainedQuickLookState {
    var url: URL
    init(url: URL) { self.url = url }
}

private struct RetainedQuickLookHost: View {
    let state: RetainedQuickLookState
    var body: some View { NavigationStack { HubQuickLook(url: state.url) } }
}
