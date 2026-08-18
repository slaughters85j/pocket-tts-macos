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
/// The view always exists so its `.task` can run the throttled check — it renders nothing until the store reports a newer version. Gating the whole view on `updateAvailable` would mean the check never runs, because the view that performs it would not be in the hierarchy.
///
/// The pill is FILLED, not outlined. The neighbouring Voice Manager badge is a stroked capsule because it is a persistent affordance; this one is a transient alert and has to read as one at a glance.
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
