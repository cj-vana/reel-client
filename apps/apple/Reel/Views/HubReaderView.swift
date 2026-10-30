import SwiftUI
import PDFKit
import QuickLook
import UniformTypeIdentifiers

struct HubReaderView: View {
    let file: HubFile
    @Environment(Session.self) private var session
    @Environment(MediaHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var reader = HubReaderModel()
    @State private var exporter = HubFileExporter()
    @State private var reload = UUID()
    init(file: HubFile, reader: HubReaderModel = HubReaderModel()) {
        self.file = file; _reader = State(initialValue: reader)
    }

    private var ownsFile: Bool { HubReaderAccess.owns(file, hub: hub, session: session) }
    private var request: HubReaderRequest { HubReaderAccess.request(file, hub: hub) }
    private var canExport: Bool { if case .ready = reader.state { return ownsFile }; return false }

    var body: some View {
        NavigationStack {
            Group {
                if !ownsFile { failure(.unavailable) }
                else {
                    switch reader.state {
                    case .loading:
                        VStack(spacing: 16) {
                            ProgressView("Opening saved book…").accessibilityIdentifier("hubReaderLoading")
                            Text("Your saved copy and reading position stay on this device.").font(.footnote).foregroundStyle(Color.reelMuted)
                        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failed(let error): failure(error)
                    case .ready(let snapshot):
                        if snapshot.locked {
                            recovery(title: "Password-protected PDF", message: "This PDF needs a password in a compatible reader. You can export the encrypted original to open it there. Reel hasn’t changed your file or reading position.", locked: true)
                        } else if let pdf = snapshot.pdf {
                            HubPDFReader(document: pdf, bookmarkKey: request.bookmarkKey, canSave: { ownsFile })
                                .id(snapshot.url).accessibilityIdentifier("hubPDFReader")
                        } else if QLPreviewController.canPreview(snapshot.url as NSURL) {
                            HubQuickLook(url: snapshot.url).id(snapshot.url).accessibilityIdentifier("hubDocumentReader")
                        } else {
                            ScrollView {
                                ContentUnavailableView {
                                    Label("Open in your reader", systemImage: "book")
                                } description: {
                                    Text("This file format needs a compatible reader. Export the saved original to open it there.")
                                } actions: { exportButton }
                            }.accessibilityIdentifier("hubExternalReader")
                        }
                    }
                }
            }
            .background(Color.reelBackground)
            .navigationTitle(ownsFile ? file.item.Name : "Saved book").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { reader.cancel(); exporter.cancel(); dismiss() }.accessibilityIdentifier("hubCloseReader")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { exporter.cancel(); reload = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload saved copy").accessibilityIdentifier("hubReloadReader").disabled(!canExport || exporter.preparing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { exporter.export(file, hub: hub, session: session) } label: {
                        if exporter.preparing { ProgressView().accessibilityLabel("Preparing export") }
                        else { Image(systemName: "square.and.arrow.up") }
                    }.accessibilityLabel("Export original file").accessibilityIdentifier("hubReaderExport")
                        .disabled(!canExport || exporter.preparing)
                }
            }
        }
        .modifier(HubExportPresentation(exporter: exporter))
        .task(id: "\(session.revision)|\(file.id)|\(file.filename)|\(reload)") {
            let revision = session.revision
            await reader.load(request, stillOwned: { session.revision == revision && ownsFile })
        }
        .onChange(of: session.revision) { _, _ in reader.cancel(); exporter.cancel(); dismiss() }
        .onChange(of: hub.files.map { "\($0.id)|\($0.accountID)|\($0.filename)" }) { _, _ in
            if !ownsFile { reader.cancel(); exporter.cancel(); dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, ownsFile { exporter.revalidateOwnership(); reload = UUID() }
        }
        .onDisappear { reader.cancel(); exporter.cancel() }
    }

    private var exportButton: some View {
        Button { exporter.export(file, hub: hub, session: session) } label: { Label("Export original file", systemImage: "square.and.arrow.up") }
            .buttonStyle(QuietButton()).disabled(!canExport || exporter.preparing).accessibilityIdentifier("hubReaderExportOriginal")
    }
    private func failure(_ error: HubReaderFailure) -> some View {
        recovery(title: error.title, message: error.message, locked: false)
    }
    private func recovery(title: String, message: String, locked: Bool) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: locked ? "lock.doc" : "doc.badge.ellipsis").font(.system(size: 44)).foregroundStyle(Color.reelBlue).accessibilityHidden(true)
                Text(title).font(.title2.bold()).multilineTextAlignment(.center).accessibilityIdentifier("hubReaderFailureTitle")
                Text(message).foregroundStyle(Color.reelMuted).multilineTextAlignment(.center).accessibilityIdentifier("hubReaderFailureMessage")
                Button { exporter.cancel(); reload = UUID() } label: { Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton()).disabled(!ownsFile).accessibilityIdentifier("hubRetryReader")
                if locked { exportButton }
                Text("Retry checks this saved copy. It doesn’t delete or download anything.").font(.footnote).foregroundStyle(Color.reelMuted).multilineTextAlignment(.center)
            }.padding(28).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }.accessibilityIdentifier(locked ? "hubLockedPDF" : "hubReaderFailure")
    }
}

struct HubExportPresentation: ViewModifier {
    @Bindable var exporter: HubFileExporter
    @Environment(Session.self) private var session
    @Environment(MediaHub.self) private var hub
    func body(content: Content) -> some View {
        content
            .sheet(item: $exporter.item, onDismiss: { exporter.cancel() }) { HubExportSheet(item: $0) }
            .alert("Couldn’t export the saved file", isPresented: Binding(get: { exporter.failure != nil }, set: { if !$0 { exporter.failure = nil } })) {
                Button("OK") { exporter.failure = nil }
            } message: { Text(exporter.failure?.message ?? "") }
            .onChange(of: session.revision) { _, _ in exporter.cancel() }
            .onChange(of: hub.files.map { "\($0.id)|\($0.accountID)|\($0.filename)" }) { _, _ in exporter.revalidateOwnership() }
            .onDisappear { exporter.cancel() }
    }
}

private struct HubExportSheet: UIViewControllerRepresentable {
    let item: HubReaderExport
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let provider = NSItemProvider()
        let extensionName = URL(fileURLWithPath: item.filename).pathExtension
        let type = UTType(filenameExtension: extensionName) ?? .data
        provider.suggestedName = item.title.replacingOccurrences(of: "/", with: "-") + "." + extensionName
        let snapshot = item.snapshot
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(snapshot.url, false, nil); return nil
        }
        let controller = UIActivityViewController(activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: [provider]))
        controller.completionWithItemsHandler = { _, _, _, _ in snapshot.removeTemporaryFile() }
        controller.modalPresentationStyle = .pageSheet
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct HubPDFReader: UIViewRepresentable {
    let document: PDFDocument
    let bookmarkKey: String
    var canSave: @MainActor () -> Bool = { true }
    func makeCoordinator() -> Coordinator { Coordinator(key: bookmarkKey, canSave: canSave) }
    func makeUIView(context: Context) -> PDFView {
        let view = HubRestoringPDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous
        context.coordinator.install(document, in: view, key: bookmarkKey)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.canSave = canSave
        if let view = view as? HubRestoringPDFView,
           view.document !== document || context.coordinator.key != bookmarkKey {
            context.coordinator.install(document, in: view, key: bookmarkKey)
        }
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stop()
        if let view = view as? HubRestoringPDFView { view.didRestore = nil; view.savedPage = nil }
        view.document = nil
    }
    @MainActor final class Coordinator {
        private(set) var key: String
        private var observation = UUID()
        var canSave: @MainActor () -> Bool
        var observer: NSObjectProtocol?
        init(key: String, canSave: @escaping @MainActor () -> Bool) { self.key = key; self.canSave = canSave }
        func install(_ document: PDFDocument, in view: HubRestoringPDFView, key: String) {
            stop()
            self.key = key
            view.didRestore = nil; view.savedPage = nil
            view.document = document
            view.savedPage = UserDefaults.standard.integer(forKey: key)
            view.didRestore = { [weak self] view in self?.observe(view) }
            view.setNeedsLayout()
        }
        func observe(_ view: PDFView) {
            stop()
            guard let document = view.document else { return }
            let token = observation
            let expectedDocument = ObjectIdentifier(document)
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.observation == token, self.canSave(), let view, let document = view.document,
                          ObjectIdentifier(document) == expectedDocument, let page = view.currentPage else { return }
                    let index = document.index(for: page)
                    guard (0..<document.pageCount).contains(index) else { return }
                    UserDefaults.standard.set(index, forKey: self.key)
                }
            }
        }
        func stop() {
            observation = UUID()
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        }
    }
}

final class HubRestoringPDFView: PDFView {
    var savedPage: Int?
    var didRestore: ((PDFView) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, savedPage != nil { setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, bounds.width > 0, bounds.height > 0,
              let savedPage, let document, document.pageCount > 0 else { return }
        self.savedPage = nil
        if let page = document.page(at: min(max(0, savedPage), document.pageCount - 1)) { go(to: page) }
        didRestore?(self)
        didRestore = nil
    }
}

struct HubQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
            controller.refreshCurrentPreviewItem()
        }
    }
    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) { controller.dataSource = nil }
    @MainActor final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
