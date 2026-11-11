//
//  ChallengeSheets.swift
//  MangaCarta
//
//  Where the two interactive-challenge sheets are presented: `WebViewService`'s and the
//  extension browser's (`ExtensionBrowserManager`).
//
//  SwiftUI cannot present a sheet from a view that is already presenting one. The root
//  (`ContentView`) used to be the only presenter, so a Source search started from inside a
//  sheet of our own — the MAL-hub preview's `Read on…` — raised a challenge nobody could
//  see: the sheet silently failed to appear and the search waited out the 120-second
//  challenge timeout behind a spinner. A sheet that can start a Source search applies
//  `.challengeSheets(nested: true)`; while one is on screen the root stands down, so
//  exactly one place presents a challenge and its `onDismiss` runs exactly once.
//

import SwiftUI

@MainActor
final class ChallengeSheetRouting: ObservableObject {
    static let shared = ChallengeSheetRouting()

    /// How many nested hosts are on screen. The root presents only when this is zero.
    @Published fileprivate(set) var nestedHosts = 0
}

extension View {
    /// Presents the challenge sheets here. `nested` is for a host inside a sheet; the
    /// root passes `false` and yields to any nested host on screen.
    func challengeSheets(nested: Bool) -> some View {
        modifier(ChallengeSheets(nested: nested))
    }
}

private struct ChallengeSheets: ViewModifier {
    let nested: Bool
    @ObservedObject private var webViewService = WebViewService.shared
    @ObservedObject private var browser = ExtensionBrowserManager.shared
    @ObservedObject private var routing = ChallengeSheetRouting.shared

    private var presents: Bool { nested || routing.nestedHosts == 0 }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: webChallengePresented,
                   onDismiss: { webViewService.cancelChallenge() },
                   content: { CloudflareChallengeView() })
            .sheet(isPresented: extensionChallengePresented,
                   onDismiss: { browser.cancelActiveChallenge() },
                   content: {
                       if let challenge = browser.activeChallenge {
                           ExtensionBrowserChallengeView(challenge: challenge)
                       }
                   })
            .onAppear { if nested { routing.nestedHosts += 1 } }
            .onDisappear { if nested { routing.nestedHosts -= 1 } }
    }

    // A swipe-dismiss writes `false` before `onDismiss` runs, exactly as the plain
    // `$webViewService.isChallengeActive` binding did; `WebViewService` relies on that order.
    private var webChallengePresented: Binding<Bool> {
        Binding(
            get: { presents && webViewService.isChallengeActive },
            set: { presented in
                if !presented { webViewService.isChallengeActive = false }
            }
        )
    }

    private var extensionChallengePresented: Binding<Bool> {
        Binding(
            get: { presents && browser.activeChallenge != nil },
            set: { presented in
                if !presented { browser.cancelActiveChallenge() }
            }
        )
    }
}
