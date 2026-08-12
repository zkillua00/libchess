import LibChessKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
        }
        .alert(
            "LibChess",
            isPresented: Binding(
                get: { store.message != nil },
                set: { if !$0 { store.message = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.message = nil
            }
        } message: {
            Text(store.message ?? "")
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

    private var sidebar: some View {
        List {
            Section("Play providers") {
                if store.providers.isEmpty {
                    Label("Loading providers…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.providers) { provider in
                        Label(provider.displayName, systemImage: "network")
                    }
                }
            }

            Section("Status") {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
            }
        }
        .navigationTitle("LibChess")
    }

    @ViewBuilder
    private var detail: some View {
        switch store.connectionState {
        case .connected:
            ConnectedView()
        case .authorizing:
            AuthorizingView()
        case .connecting:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Finishing Lichess sign-in…")
                    .font(.headline)
                Text("LibChess is exchanging the one-time code and validating your account.")
                    .foregroundStyle(.secondary)
            }
        case .disconnected:
            ConnectView()
        }
    }

    private var statusTitle: String {
        switch store.connectionState {
        case .connected: "Connected"
        case .authorizing: "Waiting for sign-in"
        case .connecting: "Connecting"
        case .disconnected: "Not connected"
        }
    }

    private var statusSymbol: String {
        switch store.connectionState {
        case .connected: "checkmark.circle.fill"
        case .authorizing: "safari"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .connected: .green
        case .authorizing: .blue
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }
}

private struct ConnectView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkerboard.rectangle")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Sign in to Lichess")
                        .font(.largeTitle.bold())
                    Text("LibChess opens Lichess in your browser and asks only for permission to play games on your behalf.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Sign in with Lichess") {
                        store.beginLichessOAuth()
                    }
                    .buttonStyle(.borderedProminent)

                    if store.savedCredentialAvailable {
                        Button("Use Saved Credential") {
                            store.connectUsingSavedCredential()
                        }
                    }

                    Spacer()
                }

                Label(
                    "Authentication stays in your browser. The resulting credential is stored in macOS Keychain after Lichess validates it.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            Spacer()
        }
        .padding(32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AuthorizingView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "safari")
                .font(.system(size: 58))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Finish signing in through Lichess")
                    .font(.largeTitle.bold())
                Text("Approve the board:play permission in your browser. LibChess will continue automatically when Lichess returns you here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                if let authorizationURL = store.authorizationURL {
                    Button("Reopen Browser") {
                        openURL(authorizationURL)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Cancel", role: .cancel) {
                    store.cancelOAuth()
                }
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ConnectedView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text(store.account?.displayName ?? "Connected")
                    .font(.largeTitle.bold())
                Text("Lichess account verified through LibChess")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Refresh Account") {
                    store.refreshAccount()
                }
                Button("Disconnect") {
                    store.disconnect()
                }
                Button("Disconnect and Remove from This Mac", role: .destructive) {
                    store.disconnect(forgetCredential: true)
                }
            }

            GroupBox("Next vertical slice") {
                Text("Incoming event streaming, active games, and the native board will attach here without changing the frontend/backend boundary.")
                    .frame(maxWidth: 520, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .frame(maxWidth: 560)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
