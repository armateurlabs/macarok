import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class CertificatePresentationTests: XCTestCase {
    func testCurrentDialogCanApproveItsPendingConnection() async throws {
        let model = AppModel(registerSystemControls: false)
        model.presentAddSource(from: .settings)
        XCTAssertNotNil(model.beginSourceConnection(sourceID: "pending"))
        let approval = Task { await model.approveCertificate(challenge(sourceID: "pending")) }
        defer { approval.cancel() }
        try await waitForPromptCount(1, model: model)
        model.answerCertificate(true)
        let accepted = await approval.value
        XCTAssertTrue(accepted)
        XCTAssertTrue(model.certificatePrompts.isEmpty)
    }

    func testClosingDialogRejectsPendingAndLateApprovalsButPreservesSavedSourcePrompt() async throws {
        let model = AppModel(registerSystemControls: false)
        model.sources = [SourceRecord(id: "saved", kind: .openSubsonic, name: "Saved", location: "https://saved.invalid")]
        model.presentAddSource(from: .settings)
        model.beginSourceConnection(sourceID: "pending")
        let pending = Task { await model.approveCertificate(challenge(sourceID: "pending")) }
        let saved = Task { await model.approveCertificate(challenge(sourceID: "saved")) }
        defer { pending.cancel(); saved.cancel() }
        try await waitForPromptCount(2, model: model)
        model.addSourcePresenter = nil
        let pendingAccepted = await pending.value
        XCTAssertFalse(pendingAccepted)
        XCTAssertEqual(model.certificatePrompts.map(\.challenge.sourceID), ["saved"])
        let lateAccepted = await model.approveCertificate(challenge(sourceID: "pending"))
        XCTAssertFalse(lateAccepted)
        XCTAssertEqual(model.certificatePrompts.count, 1)
        model.answerCertificate(true)
        let savedAccepted = await saved.value
        XCTAssertTrue(savedAccepted, "A saved source keeps its ordinary certificate prompt when a connection dialog closes.")
    }

    func testReopeningSamePresenterDoesNotReviveAPreviousConnection() async throws {
        let model = AppModel(registerSystemControls: false)
        model.presentAddSource(from: .settings)
        let oldGeneration = model.beginSourceConnection(sourceID: "old")
        model.addSourcePresenter = nil
        model.presentAddSource(from: .settings)
        let currentGeneration = model.beginSourceConnection(sourceID: "new")
        XCTAssertNotEqual(oldGeneration, currentGeneration)
        let oldAccepted = await model.approveCertificate(challenge(sourceID: "old"))
        XCTAssertFalse(oldAccepted)
        XCTAssertTrue(model.certificatePrompts.isEmpty)
        let approval = Task { await model.approveCertificate(challenge(sourceID: "new")) }
        defer { approval.cancel() }
        try await waitForPromptCount(1, model: model)
        model.answerCertificate(false)
        let accepted = await approval.value
        XCTAssertFalse(accepted)
    }

    func testChangingPresenterRejectsPreviousDialogAndUnknownConnections() async throws {
        let model = AppModel(registerSystemControls: false)
        model.presentAddSource(from: .settings)
        model.beginSourceConnection(sourceID: "old")
        let approval = Task { await model.approveCertificate(challenge(sourceID: "old")) }
        defer { approval.cancel() }
        try await waitForPromptCount(1, model: model)
        model.presentAddSource(from: .mainWindow)
        let accepted = await approval.value
        XCTAssertFalse(accepted)
        let unknownAccepted = await model.approveCertificate(challenge(sourceID: "unregistered"))
        XCTAssertFalse(unknownAccepted)
        XCTAssertTrue(model.certificatePrompts.isEmpty)
    }

    func testCancelledApprovalDoesNotLeaveAnUnansweredPrompt() async throws {
        let model = AppModel(registerSystemControls: false)
        model.sources = [SourceRecord(id: "saved", kind: .openSubsonic, name: "Saved", location: "https://saved.invalid")]
        let approval = Task { await model.approveCertificate(challenge(sourceID: "saved")) }
        defer { approval.cancel() }
        try await waitForPromptCount(1, model: model)
        approval.cancel()
        let accepted = await approval.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(model.certificatePrompts.isEmpty)
    }

    private func challenge(sourceID: String) -> ServerCertificateChallenge {
        ServerCertificateChallenge(sourceID: sourceID, host: "music.invalid", port: 443,
                                   subject: "Fixture certificate", fingerprint: "fixture", certificateDER: Data([1]),
                                   previouslyTrustedFingerprint: nil, reason: "Self-signed fixture")
    }

    private func waitForPromptCount(_ count: Int, model: AppModel) async throws {
        for _ in 0..<100 {
            if model.certificatePrompts.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The expected certificate prompt was not presented.")
        throw URLError(.timedOut)
    }
}
