// SwiftUIHost.swift — ObjC-callable helper to create SwiftUI hosting controllers
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

/// Custom hosting controller that respects fullScreen state for status bar hiding
class iPSX2HostingController<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool {
        AppState.shared.hideStatusBar
    }
    override var prefersHomeIndicatorAutoHidden: Bool {
        AppState.shared.hideStatusBar
    }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        .fade
    }
    /// [iPSX2 #12] While playing, a swipe from a screen edge first shows the grabber instead of
    /// leaving the game, so touch controls near the edges don't trigger Home / Control Center.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        AppState.shared.hideStatusBar ? .all : []
    }
}

/// [iPSX2 #12] Asks UIKit to re-read the status bar / home indicator / edge-gesture preferences.
/// ios_main.mm makes SDL's root view controller forward these to iPSX2HostingController.
@MainActor
enum SystemChrome {
    static func refresh() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                guard let root = window.rootViewController else { continue }
                root.setNeedsStatusBarAppearanceUpdate()
                root.setNeedsUpdateOfHomeIndicatorAutoHidden()
                root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
        }
    }
}

@objc public class SwiftUIHost: NSObject {
    @MainActor
    @objc public static func createMenuController() -> UIViewController {
        let hostingController = iPSX2HostingController(rootView: RootView())
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        return hostingController
    }
}
