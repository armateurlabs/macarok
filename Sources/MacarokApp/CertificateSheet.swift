import AppKit
import SwiftUI

struct CertificateSheet: View {
    let prompt: CertificatePrompt
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: prompt.challenge.previouslyTrustedFingerprint == nil ? "checkmark.shield" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(prompt.challenge.previouslyTrustedFingerprint == nil ? "Trust This Server Certificate?" : "The Server Certificate Has Changed")
                        .font(.title3.weight(.semibold))
                    Text(prompt.challenge.reason).foregroundStyle(.secondary).font(.callout)
                }
            }
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 12) {
                    GridRow { Text("Server").foregroundStyle(.secondary); Text("\(prompt.challenge.host):\(prompt.challenge.port)").textSelection(.enabled) }
                    GridRow { Text("Subject").foregroundStyle(.secondary); Text(prompt.challenge.subject).textSelection(.enabled) }
                    GridRow(alignment: .top) {
                        Text("SHA-256").foregroundStyle(.secondary)
                        Text(prompt.challenge.fingerprint).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let previous = prompt.challenge.previouslyTrustedFingerprint {
                        GridRow(alignment: .top) {
                            Text("Previously trusted").foregroundStyle(.secondary)
                            Text(previous).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("This decision applies only to this source and server. Macarok will ask again if its certificate changes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Fingerprint") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.challenge.fingerprint, forType: .string)
                }.buttonStyle(.borderless)
                Spacer()
                Button("Cancel") { answer(false) }.keyboardShortcut(.cancelAction)
                Button("Trust and Connect") { answer(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("trustServerCertificate")
            }
        }.padding(24).frame(width: 570).interactiveDismissDisabled()
    }
}
