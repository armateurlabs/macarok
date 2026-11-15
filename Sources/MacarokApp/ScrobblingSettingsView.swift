import MacarokCore
import SwiftUI

struct ScrobblingSettingsView: View {
    @Bindable var controller: ScrobblingController
    let sources: [SourceRecord]

    var body: some View {
        Form {
            Section("Personal Last.fm API Credentials") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("API key").frame(width: 92, alignment: .leading)
                    TextField("API key", text: $controller.apiKeyInput)
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("lastFMAPIKey")
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Shared secret").frame(width: 92, alignment: .leading)
                    SecureField("Shared secret", text: $controller.apiSecretInput)
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("lastFMSharedSecret")
                }
                HStack {
                    Link("Create an API account…", destination: URL(string: "https://www.last.fm/api/account/create")!)
                    Spacer()
                    Button("Save API Keys") { Task { await controller.saveAPIKeys() } }.disabled(controller.isWorking || controller.isLoading)
                }
                Text("Macarok uses your own API credentials. They and your authorized session are stored in macOS Keychain. Your Last.fm password stays in your browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Account") {
                if let username = controller.username {
                    HStack { LabeledContent("Connected account", value: username); Spacer(); Button("Disconnect") { Task { await controller.disconnect() } }.disabled(controller.isWorking) }
                }
                HStack {
                    Button(controller.username == nil ? "Connect Last.fm…" : "Reconnect Last.fm…") { Task { await controller.connect() } }
                        .disabled(!controller.isConfigured || controller.isWorking)
                    if controller.needsAuthorizationCompletion {
                        Button("Complete Connection") { Task { await controller.completeAuthorization() } }
                            .buttonStyle(.borderedProminent).disabled(controller.isWorking)
                    }
                    if controller.isWorking || controller.isLoading { ProgressView().controlSize(.small) }
                }
                Toggle("Scrobble music to Last.fm", isOn: Binding(get: { controller.isEnabled }, set: { value in Task { await controller.setEnabled(value) } }))
                    .disabled(controller.username == nil || controller.needsReauthentication || controller.isWorking)
                Toggle("Share Now Playing", isOn: Binding(get: { controller.sharesNowPlaying }, set: { value in Task { await controller.setSharesNowPlaying(value) } }))
                    .disabled(controller.username == nil || controller.isWorking)
                Text("Tracks longer than 30 seconds are submitted after half their duration or four minutes of listening. Pauses, buffering, and skipped time do not count.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Music Sources") {
                ForEach(sources.filter { [.local, .openSubsonic].contains($0.kind) }) { source in
                    Toggle(source.name, isOn: Binding(get: { !controller.excludedSourceIDs.contains(source.id) }, set: { value in Task { await controller.setSource(source.id, excluded: !value) } }))
                        .disabled(controller.isWorking)
                }
                Text("Podcasts and radio are excluded. Disable a source here if your server already submits its plays to Last.fm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Submission Queue") {
                HStack {
                    Text("\(controller.pendingCount) pending · \(controller.ignoredCount) ignored · \(controller.failedCount) failed")
                    Spacer()
                    if controller.isSubmitting { ProgressView().controlSize(.small) }
                    Button("Retry Pending", action: controller.retryPending).disabled(!controller.isEnabled || controller.pendingCount == 0)
                }
                Text("Pending plays survive restarts and are sent oldest first. Previously recorded listening history is not uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = controller.notice { Section { Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
            if let error = controller.errorMessage { Section { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) } }
            Section { Link("Last.fm", destination: URL(string: "https://www.last.fm")!) }
        }.formStyle(.grouped).task { await controller.start() }
    }
}
