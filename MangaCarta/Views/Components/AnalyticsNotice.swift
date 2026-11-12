import SwiftUI

struct AnalyticsNotice: View {
    @EnvironmentObject private var consent: AnalyticsConsentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(consent.asksForConsent ? "Help improve recommendations?" : "Help improve recommendations")
                .font(.headline)
                .foregroundStyle(Ink.primary)
                .accessibilityAddTraits(.isHeader)
            Text(consent.asksForConsent
                 ? "MangaCarta can share which titles you save and finish — by their MyAnimeList and AniList numbers, "
                   + "never their names — plus which features you use. Adult titles and your own files are never included. "
                   + "It isn't linked to your name or your accounts. You can change this any time in Settings."
                 : "If you tap OK, MangaCarta shares which titles you save and finish — by their MyAnimeList and AniList numbers, "
                   + "never their names — plus which features you use. Adult titles and your own files are never included. "
                   + "It isn't linked to your name or your accounts. You can turn this off any time in Settings.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
            HStack(spacing: 10) {
                noticeButton(consent.asksForConsent ? "Share" : "OK", id: "analyticsNotice.accept") {
                    consent.accept()
                }
                noticeButton(consent.asksForConsent ? "Not now" : "Turn off", id: "analyticsNotice.decline") {
                    consent.decline()
                }
            }
        }
        .padding(Gutter.page)
        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
        .accessibilityIdentifier("analyticsNotice")
    }

    private func noticeButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.hairline, lineWidth: 1))
            .accessibilityIdentifier(id)
    }
}
