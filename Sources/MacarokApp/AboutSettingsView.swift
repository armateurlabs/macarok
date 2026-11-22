import AppKit
import SwiftUI

/// Settings › About: what Macarok is, its version, and who publishes it.
struct AboutSettingsView: View {
    static let repositoryURL = URL(string: "https://github.com/armateurlabs/macarok")!
    static let publisherURL = URL(string: "https://armateurlabs.fr")!
    static let contactURL = URL(string: "mailto:contact@armateurlabs.fr")!

    var bundle: Bundle = .main
    var updates: AppUpdater?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    identity.frame(width: 190)
                    pitch
                }
                Divider().padding(.top, 14).padding(.bottom, 10)
                Text("Your library and settings stay on this Mac; server credentials are kept in the Keychain. Last.fm and other services are contacted only when you enable them. Macarok has no usage analytics.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 20, leading: 20, bottom: 14, trailing: 20))
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))

            VStack(spacing: 4) {
                (Text("Published by ").foregroundStyle(.secondary) + Text("Armateur Labs").fontWeight(.semibold))
                Link("armateurlabs.fr", destination: Self.publisherURL)
                Link("contact@armateurlabs.fr", destination: Self.contactURL)
            }
            .font(.system(size: 12)).padding(.top, 16)

            HStack(spacing: 8) {
                Button("Check for Updates…") { updates?.checkForUpdates() }.disabled(updates?.canCheckForUpdates != true)
                Button("Licenses", action: openLicenses).disabled(licensesURL == nil)
                    .help(licensesURL == nil ? "License notices are included in the application bundle." : "Open the licenses of Macarok and its dependencies")
                Button("GitHub") { NSWorkspace.shared.open(Self.repositoryURL) }
            }.padding(.top, 12)
            Text(updateStatus).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var identity: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.bundlePath)).resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Macarok").font(.system(size: 24, weight: .bold))
            Text(versionText).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Audio engine: libVLC 4").font(.system(size: 11)).foregroundStyle(.secondary)
            Link(destination: Self.repositoryURL) {
                Text("github.com/armateurlabs/macarok").lineLimit(1).fixedSize()
            }.font(.system(size: 11)).padding(.top, 4)
        }.frame(maxWidth: .infinity).padding(.top, 8)
    }

    private var pitch: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A native macOS music player inspired by Amarok 1.4.").font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            feature("music.note.list", "Your whole library.",
                    "Local folders, OpenSubsonic servers, podcasts, Internet radio and the Internet Archive.")
            feature("text.quote", "Rich listening context.", "Artist, album, lyrics and Wikipedia beside what is playing.")
            feature("list.bullet.rectangle", "An active playlist.", "Grouped by album, with seamless transitions and similar-track mixes.")
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The full release version, including a prerelease suffix, which release builds record in the
    /// information string; otherwise the numeric short version.
    var versionText: String {
        let info = (bundle.object(forInfoDictionaryKey: "CFBundleGetInfoString") as? String)
            .flatMap { $0.hasPrefix("Macarok ") ? String($0.dropFirst("Macarok ".count)) : nil }
        let version = info ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "Version \(version) (\(build))"
        case let (version?, nil): return "Version \(version)"
        default: return "Development build"
        }
    }

    private var updateStatus: String {
        guard let updates, updates.isAvailable else { return "Updates are available in the installed application." }
        let schedule = updates.automaticallyChecksForUpdates ? "Macarok checks for updates once a day" : "Automatic update checks are off"
        return "\(schedule) · \(UpdateStatusText.lastCheck(updates.lastUpdateCheckDate))"
    }

    /// The notices copied into the application bundle by the build script.
    private var licensesURL: URL? {
        bundle.url(forResource: "ThirdPartyNotices", withExtension: "md")
    }

    private func openLicenses() {
        guard let licensesURL else { return }
        NSWorkspace.shared.open(licensesURL)
    }
}

enum UpdateStatusText {
    static func lastCheck(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not checked yet" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Last checked today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Last checked yesterday at \(time)"
        }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
