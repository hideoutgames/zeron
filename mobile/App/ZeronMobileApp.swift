import Foundation
import SkipFuse
import SwiftUI

let logger: Logger = Logger(subsystem: "dev.zeron.mobile", category: "ZeronMobile")

/// The shared top-level view, loaded from the platform-specific app delegates.
/* SKIP @bridge */public struct ZeronMobileRootView : View {
    @State var app = AppModel()

    /* SKIP @bridge */public init() {
    }

    public var body: some View {
        ContentView()
            .environment(app)
    }
}

/* SKIP @bridge */public final class ZeronMobileAppDelegate : Sendable {
    /* SKIP @bridge */public static let shared = ZeronMobileAppDelegate()

    private init() {
    }

    /* SKIP @bridge */public func onInit() {}
    /* SKIP @bridge */public func onLaunch() {}
    /* SKIP @bridge */public func onResume() {}
    /* SKIP @bridge */public func onPause() {}
    /* SKIP @bridge */public func onStop() {}
    /* SKIP @bridge */public func onDestroy() {}
    /* SKIP @bridge */public func onLowMemory() {}
}
