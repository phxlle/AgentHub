//
//  AntigravitySessionFileScanner.swift
//  AgentHubSessionGraph
//
//  Helpers for scanning Antigravity CLI (`agy`) conversations.
//
//  Antigravity keeps one conversation per directory under
//  `<data>/brain/<conversationId>/`, and writes a line-per-step JSONL
//  transcript to `.system_generated/logs/transcript.jsonl` while the agent
//  runs. The transcript has no workspace path; that comes from the
//  `conversation_summaries.db` SQLite file next to `brain/`.
//

import Foundation
import GRDB

public struct AntigravitySessionMeta: Sendable {
  public let sessionId: String
  public let projectPath: String
  public let branch: String?
  public let startedAt: Date?
  public let sessionFilePath: String

  public init(
    sessionId: String,
    projectPath: String,
    branch: String?,
    startedAt: Date?,
    sessionFilePath: String
  ) {
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.branch = branch
    self.startedAt = startedAt
    self.sessionFilePath = sessionFilePath
  }
}

public enum AntigravitySessionFileScanner {
  public static let defaultDataPath = "~/.gemini/antigravity-cli"
  static let transcriptRelativePath = ".system_generated/logs/transcript.jsonl"

  public static func expandedDataPath(_ dataPath: String) -> String {
    (dataPath as NSString).expandingTildeInPath
  }

  /// Transcript path for a conversation, whether or not it exists yet.
  public static func transcriptPath(dataPath: String, conversationId: String) -> String {
    "\(expandedDataPath(dataPath))/brain/\(conversationId)/\(transcriptRelativePath)"
  }

  /// Conversation id for a transcript path (the `brain/<id>` directory name).
  public static func conversationId(fromTranscriptPath path: String) -> String? {
    let components = path.split(separator: "/").map(String.init)
    guard let brainIndex = components.lastIndex(of: "brain"),
      brainIndex + 1 < components.count
    else { return nil }
    return components[brainIndex + 1]
  }

  public static func listSessionFiles(antigravityDataPath: String) -> [String] {
    let brainRoot = expandedDataPath(antigravityDataPath) + "/brain"
    guard let conversationDirs = try? FileManager.default.contentsOfDirectory(atPath: brainRoot) else {
      return []
    }
    var results: [String] = []
    for conversationId in conversationDirs where !conversationId.hasPrefix(".") {
      let path = "\(brainRoot)/\(conversationId)/\(transcriptRelativePath)"
      if FileManager.default.fileExists(atPath: path) {
        results.append(path)
      }
    }
    return results
  }

  /// Reads the conversation's workspace from the summaries database and its
  /// start time from the first transcript line. Returns nil until the summary
  /// row exists (it appears within about a second of the conversation start).
  public static func readSessionMeta(from path: String, antigravityDataPath: String) -> AntigravitySessionMeta? {
    guard let conversationId = conversationId(fromTranscriptPath: path) else { return nil }
    let summaries = AntigravityConversationSummaryIndex.shared.summaries(dataPath: antigravityDataPath)
    guard let summary = summaries[conversationId], let projectPath = summary.workspacePath else {
      return nil
    }
    return AntigravitySessionMeta(
      sessionId: conversationId,
      projectPath: projectPath,
      branch: nil,
      startedAt: readFirstStepDate(from: path) ?? summary.lastUserInputAt,
      sessionFilePath: path
    )
  }

  private static func readFirstStepDate(from path: String) -> Date? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { return nil }
    let firstLine = chunk.prefix { $0 != 0x0A }
    guard let json = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any] else {
      return nil
    }
    return CodexTimestampParser.parse(json["created_at"] as? String)
  }
}

// MARK: - Conversation summaries (SQLite)

public struct AntigravityConversationSummary: Sendable {
  public let conversationId: String
  public let title: String
  public let preview: String
  public let stepCount: Int
  public let workspacePath: String?
  /// Raw `CASCADE_RUN_STATUS_*` value.
  public let runStatus: String
  public let lastModifiedAt: Date?
  public let lastUserInputAt: Date?
}

/// Read-only view of `conversation_summaries.db`, cached per database
/// modification time so repeated scans do not reopen SQLite.
public final class AntigravityConversationSummaryIndex: @unchecked Sendable {
  public static let shared = AntigravityConversationSummaryIndex()

  private let lock = NSLock()
  private var cache: [String: (modifiedAt: Date, rows: [String: AntigravityConversationSummary])] = [:]

  public func summaries(dataPath: String) -> [String: AntigravityConversationSummary] {
    let root = AntigravitySessionFileScanner.expandedDataPath(dataPath)
    let dbPath = root + "/conversation_summaries.db"
    // The WAL file carries the newest rows; its mtime is the real "last change".
    let modifiedAt = [dbPath, dbPath + "-wal"]
      .compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
      .max()
    guard let modifiedAt else { return [:] }

    lock.lock()
    if let cached = cache[dbPath], cached.modifiedAt == modifiedAt {
      lock.unlock()
      return cached.rows
    }
    lock.unlock()

    let rows = Self.load(dbPath: dbPath)
    lock.lock()
    cache[dbPath] = (modifiedAt, rows)
    lock.unlock()
    return rows
  }

  private static func load(dbPath: String) -> [String: AntigravityConversationSummary] {
    var configuration = Configuration()
    configuration.readonly = true
    guard let queue = try? DatabaseQueue(path: dbPath, configuration: configuration) else { return [:] }
    let rows: [Row] = (try? queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT conversation_id, title, preview, step_count, workspace_uris, status,
                 last_modified_time, last_user_input_time
          FROM conversation_summaries
          """
      )
    }) ?? []

    var result: [String: AntigravityConversationSummary] = [:]
    for row in rows {
      guard let conversationId: String = row["conversation_id"] else { continue }
      let workspaceURIs: String = row["workspace_uris"] ?? "[]"
      result[conversationId] = AntigravityConversationSummary(
        conversationId: conversationId,
        title: row["title"] ?? "",
        preview: row["preview"] ?? "",
        stepCount: row["step_count"] ?? 0,
        workspacePath: firstWorkspacePath(fromJSONArray: workspaceURIs),
        runStatus: row["status"] ?? "",
        lastModifiedAt: parseSQLiteDate(row["last_modified_time"]),
        lastUserInputAt: parseSQLiteDate(row["last_user_input_time"])
      )
    }
    return result
  }

  private static func firstWorkspacePath(fromJSONArray json: String) -> String? {
    guard let data = json.data(using: .utf8),
      let uris = try? JSONSerialization.jsonObject(with: data) as? [String],
      let first = uris.first
    else { return nil }
    if let url = URL(string: first), url.isFileURL {
      return url.path
    }
    return first.hasPrefix("/") ? first : nil
  }

  /// Antigravity stores `2026-11-19 08:02:06.863885+00:00`; a zero date means unset.
  private static func parseSQLiteDate(_ value: String?) -> Date? {
    guard let value, !value.hasPrefix("0001-") else { return nil }
    var normalized = value.replacingOccurrences(of: " ", with: "T")
    // Trim fractional seconds to 3 digits so ISO8601DateFormatter accepts them.
    if let dot = normalized.firstIndex(of: "."),
      let zoneStart = normalized[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
    {
      let fraction = normalized[normalized.index(after: dot)..<zoneStart]
      normalized.replaceSubrange(dot..<zoneStart, with: "." + fraction.prefix(3))
    }
    return CodexTimestampParser.parse(normalized)
  }
}
