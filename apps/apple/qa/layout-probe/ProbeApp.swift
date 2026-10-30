import Foundation
import SwiftUI

@main
struct LayoutProbeApp: App {
    init() {
        #if targetEnvironment(simulator)
        precondition(Bundle.main.bundleIdentifier == "app.reelclient.probe", "Refuse a product bundle identifier.")
        #else
        preconditionFailure("The layout probe is simulator-only.")
        #endif
    }

    var body: some Scene {
        WindowGroup { Color.black }
    }
}
