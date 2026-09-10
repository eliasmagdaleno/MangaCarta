//
//  ExtensionBrowserChallengeView.swift
//  MangaCarta
//
//  Presents the exact per-Source WKWebView that encountered an interactive
//  verification challenge. The browser broker, not this view, owns policy.
//

import SwiftUI
import WebKit

struct ExtensionBrowserChallengeView: View {
    let challenge: ExtensionBrowserChallenge
    @ObservedObject private var manager = ExtensionBrowserManager.shared

    var body: some View {
        NavigationStack {
            ExtensionChallengeWebViewHost(webView: challenge.webView)
                .navigationTitle("Verification Required")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 2) {
                        Text(challenge.sourceName)
                            .font(.caption.weight(.semibold))
                        Text(challenge.origin)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            manager.cancelActiveChallenge()
                        }
                    }
                }
        }
    }
}

private struct ExtensionChallengeWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
