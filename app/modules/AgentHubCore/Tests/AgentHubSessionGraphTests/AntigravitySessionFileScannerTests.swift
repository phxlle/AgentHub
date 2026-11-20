import Foundation
import GRDB
import Testing

@testable import AgentHubSessionGraph

@Suite("AntigravitySessionFileScanner")
struct AntigravitySessionFileScannerTests {

  @Test("Lists transcripts under brain/ and resolves the workspace from conversation_summaries.db")
  func listsAndReadsMeta() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let conversationId = "11ba75cf-e514-446b-8ef1-e8888f3bc1ca"
    let transcript = try writeTranscript(root: root, conversationId: conversationId)
    try writeSummaries(root: root, rows: [
      (conversationId, "[\"file:///tmp/agy%20project\"]", "CASCADE_RUN_STATUS_IDLE"),
      ("no-transcript", "[\"file:///tmp/other\"]", "CASCADE_RUN_STATUS_IDLE"),
    ])

    let files = AntigravitySessionFileScanner.listSessionFiles(antigravityDataPath: root.path)
    #expect(files == [transcript.path])

    let meta = try #require(
      AntigravitySessionFileScanner.readSessionMeta(from: transcript.path, antigravityDataPath: root.path))
    #expect(meta.sessionId == conversationId)
    #expect(meta.projectPath == "/tmp/agy project")
    #expect(meta.sessionFilePath == transcript.path)
    #expect(meta.startedAt == iso8601Date("2026-11-19T08:04:43Z"))

    #expect(AntigravitySessionFileScanner.conversationId(fromTranscriptPath: transcript.path) == conversationId)
    #expect(
      AntigravitySessionFileScanner.transcriptPath(dataPath: root.path, conversationId: conversationId)
        == transcript.path)
  }

  @Test("Transcript without a summary row has no meta yet")
  func transcriptWithoutSummaryRow() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = try writeTranscript(root: root, conversationId: "fresh")
    try writeSummaries(root: root, rows: [])

    #expect(AntigravitySessionFileScanner.readSessionMeta(from: transcript.path, antigravityDataPath: root.path) == nil)
  }

  // MARK: - Fixtures

  private func writeTranscript(root: URL, conversationId: String) throws -> URL {
    let logs = root.appending(path: "brain/\(conversationId)/.system_generated/logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let transcript = logs.appending(path: "transcript.jsonl")
    try """
      {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-19T08:04:43Z","content":"<USER_REQUEST>\\nls\\n</USER_REQUEST>"}
      {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-19T08:04:44Z","model":"gemini-3.8-flash-high","input_tokens":1,"cache_read_tokens":0,"output_tokens":1,"content":"done"}
      """.write(to: transcript, atomically: true, encoding: .utf8)
    return transcript
  }

  private func writeSummaries(root: URL, rows: [(String, String, String)]) throws {
    let queue = try DatabaseQueue(path: root.appending(path: "conversation_summaries.db").path)
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TABLE conversation_summaries (
            conversation_id text, title text NOT NULL DEFAULT "", preview text NOT NULL DEFAULT "",
            step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL,
            workspace_uris text NOT NULL, status text NOT NULL DEFAULT "",
            last_user_input_time datetime NOT NULL, PRIMARY KEY (conversation_id))
          """)
      for (id, uris, status) in rows {
        try db.execute(
          sql: """
            INSERT INTO conversation_summaries
              (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, last_user_input_time)
            VALUES (?, 'Title', 'ls', 2, '2026-11-19 08:05:08.949866+00:00', ?, ?, '2026-11-19 08:04:43.488637+00:00')
            """,
          arguments: [id, uris, status])
      }
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "antigravity-scanner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func iso8601Date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
