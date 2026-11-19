import Foundation
import SQLite3

public struct WorktreeSessionCounts: Codable, Equatable, Sendable {
  public let claude: Int
  public let codex: Int
  public let antigravity: Int

  public init(claude: Int = 0, codex: Int = 0, antigravity: Int = 0) {
    self.claude = claude
    self.codex = codex
    self.antigravity = antigravity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    claude = try container.decodeIfPresent(Int.self, forKey: .claude) ?? 0
    codex = try container.decodeIfPresent(Int.self, forKey: .codex) ?? 0
    antigravity = try container.decodeIfPresent(Int.self, forKey: .antigravity) ?? 0
  }

  public var total: Int {
    claude + codex + antigravity
  }
}

public struct WorktreeSessionCounter: Sendable {
  private let claudeDataPath: String
  private let codexDataPath: String
  private let antigravityDataPath: String

  public init(
    claudeDataPath: String = "~/.claude",
    codexDataPath: String = "~/.codex",
    antigravityDataPath: String = "~/.gemini/antigravity-cli"
  ) {
    self.claudeDataPath = (claudeDataPath as NSString).expandingTildeInPath
    self.codexDataPath = (codexDataPath as NSString).expandingTildeInPath
    self.antigravityDataPath = (antigravityDataPath as NSString).expandingTildeInPath
  }

  public func countSessions(for worktrees: [WorktreeInfo]) -> [String: WorktreeSessionCounts] {
    let worktreePaths = worktrees.map { Self.normalizedPath($0.path) }
    guard !worktreePaths.isEmpty else { return [:] }

    var claudeSessionsByWorktree: [String: Set<String>] = [:]
    for session in claudeSessions() {
      guard let worktreePath = Self.bestMatchingWorktree(
        for: session.projectPath,
        in: worktreePaths
      ) else {
        continue
      }
      claudeSessionsByWorktree[worktreePath, default: []].insert(session.id)
    }

    var codexSessionsByWorktree: [String: Set<String>] = [:]
    for session in codexSessions() {
      guard let worktreePath = Self.bestMatchingWorktree(
        for: session.projectPath,
        in: worktreePaths
      ) else {
        continue
      }
      codexSessionsByWorktree[worktreePath, default: []].insert(session.id)
    }

    var antigravitySessionsByWorktree: [String: Set<String>] = [:]
    for session in antigravitySessions() {
      guard let worktreePath = Self.bestMatchingWorktree(
        for: session.projectPath,
        in: worktreePaths
      ) else {
        continue
      }
      antigravitySessionsByWorktree[worktreePath, default: []].insert(session.id)
    }

    var counts: [String: WorktreeSessionCounts] = [:]
    for path in worktreePaths {
      counts[path] = WorktreeSessionCounts(
        claude: claudeSessionsByWorktree[path]?.count ?? 0,
        codex: codexSessionsByWorktree[path]?.count ?? 0,
        antigravity: antigravitySessionsByWorktree[path]?.count ?? 0
      )
    }
    return counts
  }

  private func claudeSessions() -> [(id: String, projectPath: String)] {
    let historyPath = (claudeDataPath as NSString).appendingPathComponent("history.jsonl")
    guard let contents = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
      return []
    }

    var sessions: [(id: String, projectPath: String)] = []
    contents.enumerateLines { line, _ in
      guard let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = json["sessionId"] as? String,
            let projectPath = json["project"] as? String else {
        return
      }
      sessions.append((id: sessionId, projectPath: projectPath))
    }
    return sessions
  }

  private func codexSessions() -> [(id: String, projectPath: String)] {
    let sessionsRoot = URL(fileURLWithPath: codexDataPath)
      .appendingPathComponent("sessions", isDirectory: true)

    guard let enumerator = FileManager.default.enumerator(
      at: sessionsRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var sessions: [(id: String, projectPath: String)] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "jsonl",
            let session = codexSessionMeta(from: url.path) else {
        continue
      }
      sessions.append(session)
    }
    return sessions
  }

  private func codexSessionMeta(from path: String) -> (id: String, projectPath: String)? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    guard let firstLine = Self.readFirstLine(from: handle),
          let data = firstLine.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          type == "session_meta",
          let payload = json["payload"] as? [String: Any],
          let sessionId = payload["id"] as? String,
          let cwd = payload["cwd"] as? String else {
      return nil
    }

    return (id: sessionId, projectPath: cwd)
  }

  /// Antigravity conversations with their workspace, from conversation_summaries.db.
  private func antigravitySessions() -> [(id: String, projectPath: String)] {
    let dbPath = (antigravityDataPath as NSString).appendingPathComponent("conversation_summaries.db")
    guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    let sql = "SELECT conversation_id, workspace_uris FROM conversation_summaries"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
    defer { sqlite3_finalize(statement) }

    var sessions: [(id: String, projectPath: String)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = sqlite3_column_text(statement, 0),
            let urisText = sqlite3_column_text(statement, 1) else { continue }
      let id = String(cString: idText)
      let uris = String(cString: urisText)
      guard let data = uris.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [String],
            let first = list.first,
            let url = URL(string: first), url.isFileURL else { continue }
      sessions.append((id: id, projectPath: url.path))
    }
    return sessions
  }

  private static func bestMatchingWorktree(for projectPath: String, in worktreePaths: [String]) -> String? {
    let normalizedProjectPath = normalizedPath(projectPath)
    return worktreePaths
      .filter { path in
        normalizedProjectPath == path || normalizedProjectPath.hasPrefix(path + "/")
      }
      .max { $0.count < $1.count }
  }

  private static func normalizedPath(_ path: String) -> String {
    var normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
      .path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  private static func readFirstLine(from handle: FileHandle) -> String? {
    let chunkSize = 16_384
    let maxBytes = 262_144
    var data = Data()

    while data.count < maxBytes {
      let remaining = min(chunkSize, maxBytes - data.count)
      guard remaining > 0 else { break }
      guard let chunk = try? handle.read(upToCount: remaining),
            !chunk.isEmpty else {
        break
      }

      if let newlineIndex = chunk.firstIndex(of: 0x0A) {
        data.append(chunk.prefix(upTo: newlineIndex))
        return String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      }

      data.append(chunk)
      if chunk.count < remaining {
        break
      }
    }

    guard !data.isEmpty, data.count < maxBytes else { return nil }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
  }
}
