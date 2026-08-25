//
//  AppInformationSection.swift
//  mimika-ai-voice-studio
//
//  "App Information" card at the foot of App Settings: version, a forced update check, and a link to the App Store listing.
//

import SwiftUI

// MARK: - AppInformationSection

/// Version, update check and rate link. Owns only its own transient check state.
struct AppInformationSection: View {
    @State private var checker = AppUpdateChecker.shared
    @State private var isChecking = false
    @State private var checkMessage = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("App Information")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            infoRow(icon: "number.circle", label: "Version") {
                Text(Bundle.main.appVersion)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("appSettings.version")
            }

            infoRow(icon: "arrow.triangle.2.circlepath.circle", label: "Software Update") {
                HStack(spacing: Theme.space3) {
                    if !checkMessage.isEmpty {
                        Text(checkMessage)
                            .font(Theme.fontXS)
                            .foregroundStyle(checker.updateAvailable ? Theme.accent : Theme.textSecondary)
                    }
                    accentButton(
                        title: "Check for Updates",
                        systemImage: "arrow.triangle.2.circlepath",
                        action: checkForUpdate
                    )
                    .disabled(isChecking)
                    .accessibilityIdentifier("appSettings.checkForUpdates")
                }
            }

            infoRow(icon: "star.circle", label: "Rate mimika AI Voice Studio") {
                accentButton(title: "View on App Store", systemImage: "star") {
                    openURL(ReviewPromptGate.productPageURL)
                }
                .accessibilityIdentifier("appSettings.rateApp")
            }
        }
    }

    // MARK: - Row scaffolding

    /// One icon + label + trailing-control row, so the three rows stay aligned.
    @ViewBuilder
    private func infoRow<Trailing: View>(
        icon: String,
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: Theme.space3) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)

            Text(label)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            trailing()
        }
    }

    /// Small filled accent button, matching the Done button's treatment at a smaller size.
    private func accentButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.accent))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// User-initiated check. Passes `force: true` to bypass the 6-hour throttle, because a user who clicks this expects an answer now.
    private func checkForUpdate() {
        isChecking = true
        checkMessage = "Checking…"
        Task {
            await checker.checkForUpdate(force: true)
            isChecking = false
            if checker.updateAvailable {
                checkMessage = "Version \(checker.storeVersion) available"
            } else if checker.storeVersion.isEmpty {
                checkMessage = "Could not reach the App Store"
            } else {
                checkMessage = "Up to date"
            }
        }
    }
}
