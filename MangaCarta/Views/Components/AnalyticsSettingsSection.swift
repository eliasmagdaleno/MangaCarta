import SwiftUI

struct AnalyticsSettingsSection: View {
    @EnvironmentObject private var consent: AnalyticsConsentStore
    @EnvironmentObject private var analytics: AnalyticsRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InkSectionHeader("Privacy", eyebrow: "Data")
            VStack(spacing: 0) {
                Toggle("Share usage to improve recommendations", isOn: collectingBinding)
                    .font(.subheadline)
                    .tint(Ink.seal)
                    .padding(.horizontal, Gutter.page)
                    .frame(minHeight: 50)
                    .accessibilityIdentifier("analyticsToggle")
                Text("Saved and finished titles, by MyAnimeList and AniList number, and which features you use. "
                     + "Never names, searches, your files, or adult titles.")
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Gutter.page)
                    .padding(.bottom, 14)
                NavigationLink("What is sent") { AnalyticsSentView() }
                    .padding(.horizontal, Gutter.page)
                    .frame(minHeight: 50, alignment: .leading)
                    .accessibilityIdentifier("analyticsWhatIsSent")
                Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                Button("Reset analytics ID", action: analytics.resetAnalyticsID)
                    .foregroundStyle(Ink.primary)
                    .padding(.horizontal, Gutter.page)
                    .frame(minHeight: 50, alignment: .leading)
                    .accessibilityIdentifier("analyticsReset")
                Divider().overlay(Ink.hairline).padding(.leading, Gutter.page)
                Button("Delete my analytics data", role: .destructive) {
                    showingDelete = true
                }
                .padding(.horizontal, Gutter.page)
                .frame(minHeight: 50, alignment: .leading)
                .accessibilityIdentifier("analyticsDelete")
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline, lineWidth: 1))
            .padding(.horizontal, Gutter.page)
        }
        .confirmationDialog("Delete analytics data?", isPresented: $showingDelete) {
            Button("Delete", role: .destructive, action: analytics.deleteMyData)
        } message: {
            Text("This removes everything sent from this device.")
        }
    }

    @State private var showingDelete = false

    private var collectingBinding: Binding<Bool> {
        Binding(get: { consent.isCollecting }, set: consent.setCollecting)
    }
}

private struct AnalyticsSentView: View {
    @EnvironmentObject private var analytics: AnalyticsRecorder

    var body: some View {
        List {
            if analytics.events.isEmpty {
                Text("Nothing is waiting to be sent.")
                    .foregroundStyle(Ink.secondary)
            } else {
                ForEach(Array(analytics.events.reversed().enumerated()), id: \.offset) { _, envelope in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(envelope.event.plainDescription)
                        Text(envelope.day)
                            .font(.caption)
                            .foregroundStyle(Ink.secondary)
                    }
                    .accessibilityIdentifier("analyticsEventRow")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Analytics ID")
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
                Text(analytics.installID?.uuidString ?? "None yet")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Analytics ID")
                    .accessibilityIdentifier("analyticsInstallID")
            }
        }
        .navigationTitle("What is sent")
    }
}
