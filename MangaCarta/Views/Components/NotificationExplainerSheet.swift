import SwiftUI

struct NotificationExplainerSheet: View {
    let onContinue: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Ink.seal)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Stay close to your library")
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center)
                Text("New chapters of saved titles can arrive as notifications. "
                     + "Turn them on to know when your library has something new to read.")
                    .font(.body)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button("Turn On Notifications", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.seal)
                    .accessibilityIdentifier("notificationExplainer.continue")
                Button("Not Now", action: onNotNow)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Ink.secondary)
                    .accessibilityIdentifier("notificationExplainer.notNow")
            }
        }
        .padding(30)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notificationExplainer")
    }
}
