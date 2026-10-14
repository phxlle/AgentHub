import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Session workspace state persistence")
struct SessionWorkspaceStatePersistenceTests {

  @Test("Workspace state round-trips and is provider scoped")
  func workspaceStateRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryWorkspaceStateDatabasePath())
    let state = SessionWorkspaceState(
      selectedRepositoryPaths: ["/tmp/project-a", "/tmp/project-b"],
      selectedFolderPaths: ["/tmp"],
      monitoredSessionIds: ["session-1", "session-2"],
      archivedSessionIds: ["session-archived"],
      ownedWorktreePaths: ["/tmp/project-a/worktrees/feature"],
      expansionState: [
        "repo:/tmp/project-a": true,
        "wt:/tmp/project-a/worktrees/feature": false,
      ]
    )

    try await store.saveWorkspaceState(state, for: .claude)

    #expect(store.getWorkspaceStateSync(for: .claude) == state)
    #expect(store.getWorkspaceStateSync(for: .codex) == SessionWorkspaceState())
  }

  @Test("Owned worktree migration preserves existing workspace state")
  func ownedWorktreeMigrationPreservesExistingWorkspaceState() async throws {
    let path = temporaryWorkspaceStateDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)
    let selectedRepositoryPathsData = try JSONEncoder().encode(["/tmp/project"])
    let monitoredSessionIdsData = try JSONEncoder().encode(["session-1"])
    let expansionStateData = try JSONEncoder().encode(["repo:/tmp/project": true])

    try await dbQueue.write { db in
      try seedMigrationBaseline(
        before: SessionMetadataStore.MigrationID.addOwnedWorktreePaths,
        in: db
      )

      try db.create(table: "session_workspace_state") { t in
        t.column("provider", .text).primaryKey()
        t.column("selectedRepositoryPathsData", .blob).notNull()
        t.column("monitoredSessionIdsData", .blob).notNull()
        t.column("expansionStateData", .blob).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.execute(
        sql: """
          INSERT INTO session_workspace_state
          (provider, selectedRepositoryPathsData, monitoredSessionIdsData, expansionStateData, updatedAt)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          SessionProviderKind.claude.rawValue,
          selectedRepositoryPathsData,
          monitoredSessionIdsData,
          expansionStateData,
          Date(timeIntervalSince1970: 1_000),
        ]
      )
    }

    let store = try SessionMetadataStore(path: path)
    #expect(
      store.getWorkspaceStateSync(for: .claude)
        == SessionWorkspaceState(
          selectedRepositoryPaths: ["/tmp/project"],
          monitoredSessionIds: ["session-1"],
          ownedWorktreePaths: [],
          expansionState: ["repo:/tmp/project": true]
        )
    )
  }

  @Test("Fork database that applied folder/review migrations first still gets upstream v14-v18")
  func forkLineageDatabaseGetsUpstreamMigrations() async throws {
    let path = temporaryWorkspaceStateDatabasePath()
    let state = SessionWorkspaceState(
      selectedRepositoryPaths: ["/tmp/project"],
      selectedFolderPaths: ["/tmp"],
      monitoredSessionIds: ["session-1"]
    )
    try await SessionMetadataStore(path: path).saveWorkspaceState(state, for: .claude)

    // Rewind to the pre-rebase fork lineage: fork migrations applied, upstream's
    // v14-v18 (registered before them) never ran.
    let upstreamOnly: [(id: String, table: String?)] = [
      (SessionMetadataStore.MigrationID.createSessionMeasurements, "session_measurements"),
      (SessionMetadataStore.MigrationID.addMeasurementProjectPath, nil),
      (SessionMetadataStore.MigrationID.createContextProfiles, "context_profiles"),
      (SessionMetadataStore.MigrationID.createSessionLaunchContext, "session_launch_context"),
      (SessionMetadataStore.MigrationID.createStudioArtifacts, "studio_artifacts"),
    ]
    let dbQueue = try DatabaseQueue(path: path)
    try await dbQueue.write { db in
      for migration in upstreamOnly {
        if let table = migration.table { try db.drop(table: table) }
        try db.execute(
          sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [migration.id])
      }
    }
    try dbQueue.close()

    let store = try SessionMetadataStore(path: path)
    #expect(store.getWorkspaceStateSync(for: .claude) == state)
    let tables = try await DatabaseQueue(path: path).read { db in
      try ["session_measurements", "context_profiles", "session_launch_context", "studio_artifacts"]
        .filter { try db.tableExists($0) }
    }
    #expect(tables.count == 4)
  }

  @Test("Clear all removes workspace state")
  func clearAllRemovesWorkspaceState() async throws {
    let store = try SessionMetadataStore(path: temporaryWorkspaceStateDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"],
        expansionState: ["repo:/tmp/project": true]
      ),
      for: .claude
    )

    try await store.clearAll()

    #expect(store.getWorkspaceStateSync(for: .claude) == SessionWorkspaceState())
  }
}

private func temporaryWorkspaceStateDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_workspace_state_\(UUID().uuidString).sqlite")
    .path
}
