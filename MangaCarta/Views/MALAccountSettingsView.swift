//
//  MALAccountSettingsView.swift
//  MangaCarta
//
//  The MyAnimeList section of Settings. Every branch it renders is decided in
//  `MALAccountPresentation`, which has its own tests — this file is layout, Ink styling, and
//  the three user actions.
//
//  Sign-in is optional and nothing here is on the reading path. No reader screen ever shows
//  a sync banner; this section is the only place the account is visible.
//

import SwiftUI

struct MALAccountSettingsView: View {
    @EnvironmentObject private var account: MALAccountStore
    @State private var signOutFailed = false

    private var presentation: MALAccountPresentation {
        MALAccountPresentation.make(state: account.state,
                                    summary: account.syncSummary,
                                    toggles: account.syncToggles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InkSectionHeader("MyAnimeList", eyebrow: "Account")

            if let message = presentation.inlineError {
                inlineError(message)
            }

            card {
                switch presentation.section {
                case .signedOut:
                    signedOut
                case .authorizing:
                    authorizing
                case let .signedIn(profile, syncEnabled, automaticallyAddsTitles,
                                   summary, isRefreshing):
                    signedIn(profile: profile,
                             syncEnabled: syncEnabled,
                             automaticallyAddsTitles: automaticallyAddsTitles,
                             summary: summary,
                             isRefreshing: isRefreshing)
                case let .reauthorizationRequired(profile, summary):
                    reauthorization(profile: profile, summary: summary)
                }
            }
        }
        .task { account.refreshSyncSummary() }
        .alert("Sign in as a different account?", isPresented: switchAlertBinding) {
            Button("Delete queued updates", role: .destructive) {
                try? account.confirmAccountSwitchDeletion()
            }
            Button("Keep them", role: .cancel) { account.dismissAccountSwitch() }
        } message: {
            // The count, never the titles: this is somebody else's reading.
            Text(switchMessage)
        }
        .alert("Could not sign out", isPresented: $signOutFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your MyAnimeList credential could not be removed from this device. "
                 + "Please try again.")
        }
    }

    // MARK: States

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to send your reading progress to MyAnimeList. "
                 + "Only chapters you finish in the reader are sent, and your library stays "
                 + "on this device either way.")
                .font(.footnote)
                .foregroundStyle(Ink.tertiary)
            action("Sign in") { Task { await account.signIn() } }
        }
        .padding(.horizontal, Gutter.page)
        .padding(.vertical, 15)
    }

    private var authorizing: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Signing in…")
                .font(.subheadline)
                .foregroundStyle(Ink.primary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signing in to MyAnimeList")
        .padding(.horizontal, Gutter.page)
        .padding(.vertical, 15)
    }

    @ViewBuilder
    private func signedIn(profile: MALUserIdentity,
                          syncEnabled: Bool,
                          automaticallyAddsTitles: Bool,
                          summary: MALSyncSummary,
                          isRefreshing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            identityRow(profile, isBusy: isRefreshing)
            divider
            Toggle("Sync reading progress", isOn: Binding(
                get: { syncEnabled },
                set: { account.setSyncEnabled($0) }))
                .font(.subheadline)
                .tint(Ink.seal)
                .padding(.horizontal, Gutter.page)
                .padding(.vertical, 12)
            divider
            Toggle("Automatically add new titles", isOn: Binding(
                get: { automaticallyAddsTitles },
                set: { account.setAutomaticallyAddsTitles($0) }))
                .font(.subheadline)
                .tint(Ink.seal)
                .padding(.horizontal, Gutter.page)
                .padding(.vertical, 12)

            if !syncEnabled {
                note("Sync is off. Finished chapters stay on this device, and anything "
                     + "already queued waits until you turn it back on.")
            }

            queueLines(summary)

            divider
            HStack(spacing: 18) {
                // Disabled mid-refresh: a second authorization while one is in flight is
                // the one action here that could strand a half-adopted account.
                action("Retry now") { account.retryNow() }
                    .disabled(isRefreshing || summary.isEmpty)
                Spacer()
                Button("Sign out on this device", role: .destructive) {
                    Task {
                        do { try await account.signOut() } catch { signOutFailed = true }
                    }
                }
                .font(.subheadline)
                .disabled(isRefreshing)
            }
            .padding(.horizontal, Gutter.page)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func reauthorization(profile: MALUserIdentity?, summary: MALSyncSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let profile { identityRow(profile, isBusy: false); divider }
            note("MyAnimeList needs you to sign in again. Nothing has been lost — your "
                 + "reading is on this device, and anything queued will send once you are "
                 + "signed back in.")
            queueLines(summary)
            divider
            HStack(spacing: 18) {
                action("Sign in again") { Task { await account.signIn() } }
                Spacer()
                Button("Sign out on this device", role: .destructive) {
                    Task {
                        do { try await account.signOut() } catch { signOutFailed = true }
                    }
                }
                .font(.subheadline)
            }
            .padding(.horizontal, Gutter.page)
            .padding(.vertical, 14)
        }
    }

    // MARK: Pieces

    private func identityRow(_ profile: MALUserIdentity, isBusy: Bool) -> some View {
        HStack(spacing: 12) {
            avatar(profile)
            Text(profile.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ink.primary)
            Spacer()
            if isBusy {
                ProgressView()
                    .accessibilityLabel("Refreshing your MyAnimeList session")
            }
        }
        .padding(.horizontal, Gutter.page)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signed in as \(profile.name)")
    }

    @ViewBuilder
    private func avatar(_ profile: MALUserIdentity) -> some View {
        if let url = profile.pictureURL {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(Ink.hairline)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func queueLines(_ summary: MALSyncSummary) -> some View {
        if !summary.lines.isEmpty {
            divider
            VStack(alignment: .leading, spacing: 4) {
                ForEach(summary.lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Gutter.page)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync queue")
            .accessibilityValue(summary.lines.joined(separator: ", "))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Ink.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Gutter.page)
            .padding(.vertical, 12)
    }

    private func inlineError(_ message: String) -> some View {
        // Inline and nonmodal by design, and never a server body — `message` comes from the
        // account store's own fixed strings.
        Text(message)
            .font(.footnote)
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline, lineWidth: 1))
            .padding(.horizontal, Gutter.page)
            .accessibilityAddTraits(.isStaticText)
    }

    private func action(_ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Ink.seal)
    }

    private var divider: some View {
        Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
            .padding(.horizontal, Gutter.page)
    }

    // MARK: Account switch

    private var switchAlertBinding: Binding<Bool> {
        Binding(get: { account.pendingAccountSwitch != nil },
                set: { if !$0 { account.dismissAccountSwitch() } })
    }

    private var switchMessage: String {
        let pending = account.pendingAccountSwitch?.pendingCount ?? 0
        let updates = pending == 1 ? "1 update" : "\(pending) updates"
        return "Another MyAnimeList account still has \(updates) queued on this device. "
            + "They will never be sent to this account. Delete them, or keep them in case "
            + "that account signs in again."
    }
}
