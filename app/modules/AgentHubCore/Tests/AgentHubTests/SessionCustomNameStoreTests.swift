import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session custom name store")
struct SessionCustomNameStoreTests {
  @Test("A custom session name survives reopening the database")
  func customNameSurvivesReopen() async throws {
    let path = temporarySessionCustomNameDatabasePath()
    let store = try SessionMetadataStore(path: path)

    try await store.setCustomName("Release review", for: "session-1")

    let reopened = try SessionMetadataStore(path: path)
    #expect(try await reopened.getCustomName(for: "session-1") == "Release review")
  }

  @Test("Clearing a custom session name preserves other metadata")
  func clearNamePreservesPinnedState() async throws {
    let store = try SessionMetadataStore(path: temporarySessionCustomNameDatabasePath())
    try await store.setPinned(true, for: "session-1")
    try await store.setCustomName("Temporary name", for: "session-1")

    try await store.setCustomName(nil, for: "session-1")

    let metadata = try await store.getMetadata(for: ["session-1"])["session-1"]
    #expect(metadata?.customName == nil)
    #expect(metadata?.isPinned == true)
  }
}

private func temporarySessionCustomNameDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHub-session-name-tests-\(UUID().uuidString).sqlite")
    .path
}
