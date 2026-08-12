import LibChessKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibChessStore

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
        case .connecting:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to Lichess…")
                    .font(.headline)
                Text("LibChess is validating the credential directly with Lichess.")
                    .foregroundStyle(.secondary)
            }
        case .disconnected:
            ConnectView()
        }
    }

    private var statusTitle: String {
        switch store.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Not connected"
        }
    }

    private var statusSymbol: String {
        switch store.connectionState {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }
}

private struct ConnectView: View {
    @EnvironmentObject private var store: LibChessStore
    @State private var token = ""

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkerboard.rectangle")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Connect Lichess")
                        .font(.largeTitle.bold())
                    Text("This first vertical slice validates your account through the Rust provider layer. The public app will replace this developer token step with OAuth PKCE.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SecureField("Personal access token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        store.connectToLichess(accessToken: token)
                    }

                HStack {
                    Button("Connect") {
                        store.connectToLichess(accessToken: token)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if store.savedCredentialAvailable {
                        Button("Use Saved Credential") {
                            store.connectUsingSavedCredential()
                        }
                    }

                    Spacer()

                    Link(
                        "Manage Lichess tokens",
                        destination: URL(string: "https://lichess.org/account/oauth/token")!
                    )
                }

                Label(
                    "The token is sent only to Lichess and is stored in macOS Keychain after validation.",
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
                Button("Disconnect and Forget", role: .destructive) {
                    store.disconnect(forgetCredential: true)
                }
            }

            GroupBox("Next vertical slice") {
                Text("OAuth PKCE, incoming event streaming, active games, and the native board will attach here without changing the frontend/backend boundary.")
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

