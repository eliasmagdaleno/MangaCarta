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
    @State private var selectedTab: AppTab = Self.initialTab
    @EnvironmentObject private var localImporter: LocalImportViewModel
    @EnvironmentObject private var workNavigator: WorkNavigator

    private static var initialTab: AppTab {
#if DEBUG
        return LibraryMigrateUITestFixture.isRequested ? .bookmarks : .home
#else
        return .home
#endif
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem {
                            Label("Home", systemImage: "house")
                        }
                        .tag(AppTab.home)
                    BookmarksView(opensNotifiedWorks: true)
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
                    BookmarksView(opensNotifiedWorks: true)
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
        // A tapped new-chapter notification opens its Work from the Library tab (#343).
        // `onReceive` also sees a request made before this view existed (a cold launch).
        .onReceive(workNavigator.$requestedWork) { workId in
            if workId != nil { selectedTab = .bookmarks }
        }
        .overlay(alignment: .top) {
            LocalImportBanner(model: localImporter, onCancel: localImporter.cancel)
                .padding(.top, 8)
        }
        .onOpenURL { url in
            localImporter.importOpenedURL(url)
        }
        // The root presents challenges unless a sheet of ours that searches Sources is up;
        // that sheet presents them itself (`ChallengeSheets`).
        .challengeSheets(nested: false)
    }
}

#Preview {
    ContentView()
        .environmentObject(WorkNavigator())
}
