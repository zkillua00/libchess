import LibChessKit
import SwiftUI

struct BackendLauncherView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL
    @State private var focusedBackendID: String?

    var body: some View {
        HStack(spacing: 0) {
            launcherActions
                .frame(width: 456)

            Divider()

            launcherContext
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 760, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reconcileFocus)
        .onChange(of: store.providers.map(\.id)) { _, _ in
            reconcileFocus()
        }
        .onChange(of: store.selectedBackend?.id) { _, backendID in
            focusedBackendID = backendID
        }
        .onChange(of: store.authorizationURL) { _, authorizationURL in
            if let authorizationURL {
                openURL(authorizationURL)
            }
        }
        .onOpenURL { callbackURL in
            _ = store.handleOpenURL(callbackURL)
        }
    }

    private var launcherActions: some View {
        ZStack {
            RadialGradient(
                colors: [Color.accentColor.opacity(0.12), .clear],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 0,
                endRadius: 180
            )

            VStack(spacing: 0) {
                Spacer(minLength: 44)

                LauncherBrand()

                Spacer(minLength: 34)

                VStack(spacing: 10) {
                    if store.providers.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Discovering chess backends…")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    } else {
                        ForEach(store.providers) { backend in
                            LauncherBackendButton(
                                backend: backend,
                                isFocused: focusedBackendID == backend.id
                            ) {
                                choose(backend)
                            }
                        }
                    }
                }
                .frame(maxWidth: 350)

                Spacer(minLength: 48)
            }
            .padding(.horizontal, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var launcherContext: some View {
        if let backend = focusedBackend {
            BackendLauncherContext(backend: backend)
                .environmentObject(store)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                Text("Choose a Provider\nor Local Engine")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var focusedBackend: ProviderDescriptor? {
        guard let focusedBackendID else {
            return nil
        }
        return store.providers.first(where: { $0.id == focusedBackendID })
    }

    private func choose(_ backend: ProviderDescriptor) {
        focusedBackendID = backend.id
        guard backend.available else {
            return
        }
        store.selectBackend(backend)
    }

    private func reconcileFocus() {
        if let focusedBackendID,
           store.providers.contains(where: { $0.id == focusedBackendID })
        {
            return
        }
        focusedBackendID = store.selectedBackend?.id
    }
}

private struct LauncherBrand: View {
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.58)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                Image(systemName: "checkerboard.rectangle")
                    .font(.system(size: 43, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
            .frame(width: 102, height: 102)
            .shadow(color: Color.accentColor.opacity(0.28), radius: 22, y: 8)
            .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("LibChess")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Version \(appVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }
}

private struct LauncherBackendButton: View {
    let backend: ProviderDescriptor
    let isFocused: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: backend.icon.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 21)

                Text(backend.actionTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !backend.available {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(backend.unavailableReason ?? "Unavailable")
                }
            }
            .foregroundStyle(backend.available ? Color.primary : Color.secondary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityHint(
            backend.available
                ? backend.subtitle
                : backend.unavailableReason ?? "This backend is unavailable."
        )
    }

    private var backgroundColor: Color {
        if isHovered {
            return Color.primary.opacity(0.12)
        }
        if isFocused {
            return Color.primary.opacity(0.09)
        }
        return Color.primary.opacity(0.055)
    }
}

private struct BackendLauncherContext: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    let backend: ProviderDescriptor

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 34)

            Image(systemName: backend.icon.systemImage)
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(backend.available ? Color.accentColor : Color.secondary)
                .frame(width: 58, height: 58)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))

            VStack(spacing: 5) {
                Text(backend.displayName)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(backend.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            Text(backend.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            connectionControls

            if let message = store.message {
                LauncherMessage(message: message) {
                    store.message = nil
                }
            }

            Spacer(minLength: 30)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var connectionControls: some View {
        if !backend.available {
            Label(
                backend.unavailableReason ?? "This backend is unavailable.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
        } else if store.selectedBackend?.id != backend.id {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Selecting \(backend.displayName)")
        } else {
            switch store.connectionState {
            case .connected:
                progress("Opening workspace…")
            case .connecting:
                progress("Preparing your account…")
            case .authorizing:
                authorizingControls
            case .disconnected:
                if backend.connection.usesOAuthPKCE {
                    authenticationControls
                } else {
                    progress("Starting local engine…")
                }
            }
        }
    }

    private var authenticationControls: some View {
        VStack(spacing: 10) {
            Button("Sign In with \(backend.displayName)") {
                store.beginOAuth()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity)

            if store.savedCredentialAvailable {
                Button {
                    store.connectUsingSavedCredential()
                } label: {
                    if store.isLoadingSavedCredential {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Continue with Saved Account")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(store.isLoadingSavedCredential)
            }

            Label("Credentials are kept in macOS Keychain.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var authorizingControls: some View {
        VStack(spacing: 10) {
            Text("Finish signing in in your browser.")
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)

            if let authorizationURL = store.authorizationURL {
                Button("Reopen Browser") {
                    openURL(authorizationURL)
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Cancel", role: .cancel) {
                store.cancelOAuth()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

private struct LauncherMessage: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }
}

private extension BackendIcon {
    var systemImage: String {
        switch self {
        case .network: "network"
        case .processor: "cpu"
        default: "square.stack.3d.up"
        }
    }
}
