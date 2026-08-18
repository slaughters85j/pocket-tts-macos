//
//  UpdateAvailableBadge.swift
//  mimika-ai-voice-studio
//
//  Header pill that appears only when the App Store is ahead of the running build. Clicking it opens the product page; right-clicking dismisses it until the next release.
//

import SwiftUI

// MARK: - UpdateAvailableBadge

/// "Update Available" pill for the window header.
///
/// Always in the hierarchy so its `.task` can run the throttled check; it just renders nothing until the store is ahead. Gating the view on `updateAvailable` would mean the check never runs.
///
/// Filled, not stroked like the neighbouring Voice Manager badge — that one is a persistent affordance, this is a transient alert.
struct UpdateAvailableBadge: View {
    @State private var checker = AppUpdateChecker.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if checker.updateAvailable {
                pill
            }
        }
        .task {
            await checker.checkForUpdate()
        }
    }

    private var pill: some View {
        Button {
            openURL(checker.appStoreDeepLink)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                Text("Update Available")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .help("Version \(checker.storeVersion) is available on the App Store")
        .contextMenu {
            Button("Dismiss Until Next Version") {
                checker.dismissCurrentUpdate()
            }
        }
        .accessibilityIdentifier("header.updateAvailableBadge")
    }
}
