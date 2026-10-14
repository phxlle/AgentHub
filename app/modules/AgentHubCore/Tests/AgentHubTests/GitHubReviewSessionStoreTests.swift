import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("GitHub review session store")
struct GitHubReviewSessionStoreTests {
  @Test("Review session associations survive reopening the database")
  func associationsSurviveReopen() async throws {
    let path = temporaryGitHubReviewSessionDatabasePath()
    let store = try SessionMetadataStore(path: path)
    let association = GitHubReviewSessionAssociation(
      pullRequestID: "PR_kwDO_review",
      pullRequestURL: "https://github.com/gl-ventures/example/pull/42",
      provider: .codex,
      pendingID: UUID(),
      sessionID: "codex-session-42",
      projectPath: "/tmp/example"
    )

    try await store.saveGitHubReviewSessionAssociation(association)

    let reopened = try SessionMetadataStore(path: path)
    let restored = try await reopened.githubReviewSessionAssociations()
    #expect(restored.count == 1)
    #expect(restored[0].pullRequestID == association.pullRequestID)
    #expect(restored[0].providerKind == .codex)
    #expect(restored[0].sessionID == "codex-session-42")
  }

  @Test("A provider has one current review session per pull request")
  func replacingAssociationKeepsOneCurrentSession() async throws {
    let store = try SessionMetadataStore(path: temporaryGitHubReviewSessionDatabasePath())
    let first = GitHubReviewSessionAssociation(
      pullRequestID: "pull-request",
      pullRequestURL: "https://github.com/gl-ventures/example/pull/42",
      provider: .claude,
      pendingID: nil,
      sessionID: "first",
      projectPath: "/tmp/example"
    )
    var replacement = first
    replacement.sessionID = "replacement"

    try await store.saveGitHubReviewSessionAssociation(first)
    try await store.saveGitHubReviewSessionAssociation(replacement)

    let restored = try await store.githubReviewSessionAssociations()
    #expect(restored.count == 1)
    #expect(restored[0].sessionID == "replacement")
    #expect(abs(restored[0].createdAt.timeIntervalSince(first.createdAt)) < 0.01)
  }

  @Test("v15 migration preserves existing session metadata")
  func migrationPreservesExistingMetadata() async throws {
    let path = temporaryGitHubReviewSessionDatabasePath()
    let sessionID = "existing-session"
    let seeded = try SessionMetadataStore(path: path)
    try await seeded.setCustomName("Existing name", for: sessionID)
    try rewindPastGitHubReviewSessionMigration(at: path)

    let migrated = try SessionMetadataStore(path: path)

    #expect(try await migrated.getCustomName(for: sessionID) == "Existing name")
    #expect(try await migrated.githubReviewSessionAssociations().isEmpty)

    let association = GitHubReviewSessionAssociation(
      pullRequestID: "pull-request",
      pullRequestURL: "https://github.com/gl-ventures/example/pull/42",
      provider: .claude,
      pendingID: nil,
      sessionID: sessionID,
      projectPath: "/tmp/example"
    )
    try await migrated.saveGitHubReviewSessionAssociation(association)
    #expect(try await migrated.githubReviewSessionAssociations().count == 1)
  }
}

private func rewindPastGitHubReviewSessionMigration(at path: String) throws {
  let queue = try DatabaseQueue(path: path)
  try queue.write { db in
    try db.execute(sql: "DROP TABLE IF EXISTS github_review_sessions")
    try db.execute(
      sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
      arguments: [SessionMetadataStore.MigrationID.createGitHubReviewSessions]
    )
  }
}

private func temporaryGitHubReviewSessionDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_github_review_sessions_\(UUID().uuidString).sqlite")
    .path
}
