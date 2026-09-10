//
//  ContentView.swift
//  MangaCarta
//
//  Created by Elias Magdaleno on 5/31/24.
//

import SwiftUI

enum AppTab: Equatable, Hashable, Identifiable {
    case home
    case bookmarks
    case history
    case search
    case settings

    var id: Self { self }
}

private struct SelectAppTabKey: EnvironmentKey {
    static let defaultValue: (AppTab) -> Void = { _ in }
}

extension EnvironmentValues {
    var selectAppTab: (AppTab) -> Void {
        get { self[SelectAppTabKey.self] }
        set { self[SelectAppTabKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @StateObject private var webViewService = WebViewService.shared
    @StateObject private var extensionBrowserManager = ExtensionBrowserManager.shared

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem {
                            Label("Home", systemImage: "house")
                        }
                        .tag(AppTab.home)
                    BookmarksView()
                        .tabItem {
                            Label("Library", systemImage: "books.vertical")
                        }
                        .tag(AppTab.bookmarks)
                    HistoryView()
                        .tabItem {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .tag(AppTab.history)
                    SearchView()
                        .tabItem {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .tag(AppTab.search)
                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                        .tag(AppTab.settings)
                }
                .tabViewStyle(.sidebarAdaptable)
            } else {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem {
                            Label("Home", systemImage: "house")
                        }
                        .tag(AppTab.home)
                    BookmarksView()
                        .tabItem {
                            Label("Library", systemImage: "books.vertical")
                        }
                        .tag(AppTab.bookmarks)
                    HistoryView()
                        .tabItem {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .tag(AppTab.history)
                    SearchView()
                        .tabItem {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .tag(AppTab.search)
                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                        .tag(AppTab.settings)
                }
                .tabViewStyle(.automatic)
            }
        }
        .environment(\.selectAppTab) { selectedTab = $0 }
        .sheet(isPresented: $webViewService.isChallengeActive,
               onDismiss: { webViewService.cancelChallenge() },
               content: { CloudflareChallengeView() })
        .sheet(isPresented: extensionChallengePresented,
               onDismiss: { extensionBrowserManager.cancelActiveChallenge() },
               content: {
                   if let challenge = extensionBrowserManager.activeChallenge {
                       ExtensionBrowserChallengeView(challenge: challenge)
                   }
               })
    }

    private var extensionChallengePresented: Binding<Bool> {
        Binding(
            get: { extensionBrowserManager.activeChallenge != nil },
            set: { presented in
                if !presented { extensionBrowserManager.cancelActiveChallenge() }
            }
        )
    }
}

#Preview {
    ContentView()
}
