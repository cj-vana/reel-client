import XCTest
import SwiftUI
import UIKit
@testable import ReelWidthProbe

@MainActor private final class ProbeMeasurements {
    var geometry = CGSize.zero
    var keyboardFrame = CGRect.zero
    var keyboardVisible = false
    var observer: NSObjectProtocol?

    func startKeyboardObservation(screenBounds: CGRect) {
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated {
                guard let self, let frame else { return }
                self.keyboardFrame = frame
                self.keyboardVisible = self.keyboardFrame.height > 1 && self.keyboardFrame.minY < screenBounds.maxY - 1
            }
        }
    }
    func stop() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
}

@MainActor private struct ProbeRoot: View {
    let session: Session
    let measurements: ProbeMeasurements
    var body: some View {
        GeometryReader { geometry in
            ConnectView().environment(session)
                .onAppear { measurements.geometry = geometry.size }
                .onChange(of: geometry.size) { _, current in measurements.geometry = current }
        }
    }
}

@MainActor private final class ProbeContainer: UIViewController {
    let hosting: UIHostingController<ProbeRoot>
    var contentWidth: CGFloat
    let contentHeight: CGFloat
    init(session: Session, measurements: ProbeMeasurements, width: CGFloat, height: CGFloat) {
        contentWidth = width; contentHeight = height
        hosting = UIHostingController(rootView: ProbeRoot(session: session, measurements: measurements))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("No coder construction") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(hosting); view.addSubview(hosting.view); hosting.didMove(toParent: self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hosting.view.frame = CGRect(x: 0, y: 80, width: contentWidth, height: contentHeight)
    }
    func resize(width: CGFloat) {
        contentWidth = width
        view.setNeedsLayout(); view.layoutIfNeeded(); hosting.view.setNeedsLayout(); hosting.view.layoutIfNeeded()
    }
}

@MainActor final class WidthFocusTests: XCTestCase {
    private func fields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
    private func username(in view: UIView) -> UITextField? {
        fields(in: view).first { $0.accessibilityIdentifier == "username" || $0.textContentType == .username }
    }
    private func settle(_ predicate: () -> Bool, timeout: TimeInterval = 5) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < end
        return predicate()
    }
    private func evidence(_ label: String, field: UITextField, container: ProbeContainer, window: UIWindow, measurements: ProbeMeasurements, originalID: ObjectIdentifier) {
        let rect = field.convert(field.bounds, to: window)
        let frame = measurements.keyboardFrame
        let values: [String: Any] = ["phase": label, "same_instance": ObjectIdentifier(field) == originalID,
            "first_responder": field.isFirstResponder, "content_width": container.hosting.view.bounds.width,
            "content_height": container.hosting.view.bounds.height, "geometry_width": measurements.geometry.width,
            "geometry_height": measurements.geometry.height, "field_window_rect": NSCoder.string(for: rect),
            "keyboard_screen_rect": NSCoder.string(for: frame), "keyboard_visible": measurements.keyboardVisible]
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
        print("WIDTH_PROBE " + String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\n", with: " "))
    }
    private func exercise(_ widths: [CGFloat]) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This synthetic hosted UIKit probe is simulator-only.")
        #else
        continueAfterFailure = true
        _ = try XCTUnwrap(Bundle.main.bundleIdentifier == "app.reelclient.probe" ? true : nil, "Refuse any existing product bundle.")
        _ = try XCTUnwrap(!ProcessInfo.processInfo.arguments.contains("-reel-qa-reset") ? true : nil, "Refuse any account-reset argument before constructing Session.")
        _ = try XCTUnwrap(ProcessInfo.processInfo.environment["REEL_QA_SERVER"] == nil ? true : nil, "Empty server must not be replaced by a fixture or live server.")
        let session = Session()
        _ = try XCTUnwrap(session.notice == nil && session.account == nil && session.accounts.isEmpty ? true : nil, "The distinct probe vault must be empty; never clear an existing account.")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // ConnectView's side-by-side layout needs a regular-width window, and the
        // widths must fall on both sides of its fit test so each resize swaps the
        // layout. The size class decides, not the idiom: an open foldable iPhone
        // is regular width while it reports the phone idiom.
        _ = try XCTUnwrap(scene.traitCollection.horizontalSizeClass == .regular ? true : nil, "Use a simulator whose window is regular width for this width probe.")
        XCTAssertEqual(Set(widths.map { AdaptiveLayout.connectSideBySide(.regular, accessibility: false, width: $0) }), [true, false],
                       "The probe widths must cross ConnectView's side-by-side threshold.")
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        XCTAssertGreaterThanOrEqual(window.bounds.width, 800)
        let height = min(CGFloat(640), window.bounds.height - 160)
        XCTAssertGreaterThanOrEqual(height, 400)
        let measurements = ProbeMeasurements(); measurements.startKeyboardObservation(screenBounds: scene.screen.bounds)
        let controller = ProbeContainer(session: session, measurements: measurements, width: widths[0], height: height)
        window.rootViewController = controller; window.windowLevel = .normal + 1
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer {
            window.endEditing(true); measurements.stop(); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let appeared = try await settle { self.username(in: controller.hosting.view) != nil }
        XCTAssertTrue(appeared)
        let initial = try XCTUnwrap(username(in: controller.hosting.view))
        XCTAssertTrue(initial.becomeFirstResponder())
        let focused = try await settle { initial.isFirstResponder && measurements.keyboardVisible }
        XCTAssertTrue(focused, "A real UITextField and visible native software keyboard are required.")
        try await Task.sleep(for: .milliseconds(500))
        let baselineHeight = measurements.geometry.height
        XCTAssertEqual(measurements.geometry.width, widths[0], accuracy: 0.5)
        let originalID = ObjectIdentifier(initial)
        evidence("initial-\(Int(widths[0]))", field: initial, container: controller, window: window, measurements: measurements, originalID: originalID)
        for width in widths.dropFirst() {
            controller.resize(width: width)
            let resized = try await settle { abs(measurements.geometry.width - width) < 0.5 }
            XCTAssertTrue(resized, "ConnectView must actually receive the requested width.")
            try await Task.sleep(for: .milliseconds(600))
            let current = try XCTUnwrap(username(in: controller.hosting.view))
            evidence("resize-\(Int(width))", field: current, container: controller, window: window, measurements: measurements, originalID: originalID)
            XCTAssertTrue(current === initial, "Width-only layout must preserve the exact UIKit username field instance.")
            XCTAssertTrue(current.isFirstResponder, "Width-only layout must preserve first responder without calling becomeFirstResponder again.")
            XCTAssertEqual(controller.hosting.view.bounds.height, height, accuracy: 0.5)
            XCTAssertEqual(measurements.geometry.height, baselineHeight, accuracy: 0.5, "This must be a width-only transition, including keyboard safe-area geometry.")
            XCTAssertTrue(measurements.keyboardVisible, "Native keyboard must remain visible.")
            let rect = current.convert(current.bounds, to: window)
            let host = controller.hosting.view.convert(controller.hosting.view.bounds, to: window)
            let keyboard = window.convert(measurements.keyboardFrame, from: nil)
            XCTAssertGreaterThan(rect.width, 0); XCTAssertGreaterThan(rect.height, 0)
            XCTAssertGreaterThanOrEqual(rect.minX, host.minX - 0.5)
            XCTAssertLessThanOrEqual(rect.maxX, host.maxX + 0.5)
            XCTAssertGreaterThanOrEqual(rect.minY, host.minY - 0.5)
            XCTAssertLessThanOrEqual(rect.maxY, host.maxY + 0.5)
            XCTAssertLessThanOrEqual(rect.maxY, keyboard.minY + 0.5, "Focused field must remain above the native keyboard.")
        }
        #endif
    }
    func testWidthOnly800To600To800PreservesFieldAndResponder() async throws { try await exercise([800, 600, 800]) }
    func testWidthOnly600To800To600PreservesFieldAndResponder() async throws { try await exercise([600, 800, 600]) }
}
