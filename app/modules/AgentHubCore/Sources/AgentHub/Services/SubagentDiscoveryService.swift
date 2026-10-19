//
//  SubagentDiscoveryService.swift
//  AgentHub
//
//  Finds the subagents a session started, read-only from the providers' own files:
//  - Claude: `<project dir>/<session id>/subagents/agent-*.jsonl` + `.meta.json`
//    (agentType, description); done when the transcript ends with `end_turn`.
//  - Codex: rollouts whose session_meta has `source.subagent.thread_spawn` with
//    `parent_thread_id` = the session; named by `agent_path`; done at `task_complete`.
//    Codex "guardian" approval reviews are not subagents the user started: skipped.
//

import Foundation

public struct SessionSubagent: Identifiable, Equatable, Sendable {
  public enum Status: Equatable, Sendable { case running, done }

  public let id: String
  public let name: String
  /// Agent type (Claude: e.g. "general-purpose", "Explore") when known.
  public let kind: String?
  public let status: Status
  public let startedAt: Date?
  public let lastActivityAt: Date?
  public let transcriptPath: String
}

public protocol SubagentDiscoveryServiceProtocol: Sendable {
  func subagents(for session: CLISession, provider: SessionProviderKind) async -> [SessionSubagent]
}

public actor SubagentDiscoveryService: SubagentDiscoveryServiceProtocol {
  private let codexDataPath: String
  private let fileManager = FileManager.default
  /// Codex rollout first lines never change; cache their parent id per file.
  private var codexParentByFile: [String: CodexSpawnMeta?] = [:]

  struct CodexSpawnMeta: Equatable {
    let parentID: String
    let name: String
    let startedAt: Date?
  }

  public init(codexDataPath: String) {
    self.codexDataPath = codexDataPath
  }

  public func subagents(for session: CLISession, provider: SessionProviderKind) async -> [SessionSubagent] {
    let found: [SessionSubagent]
    switch provider {
    case .claude: found = claudeSubagents(for: session)
    case .codex: found = codexSubagents(for: session)
    }
    return found.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
  }

  // MARK: - Claude

  private func claudeSubagents(for session: CLISession) -> [SessionSubagent] {
    guard let sessionFile = session.sessionFilePath else { return [] }
    let directory = (sessionFile as NSString).deletingPathExtension + "/subagents"
    guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
    return files.filter { $0.hasSuffix(".jsonl") }.map { file in
      let path = (directory as NSString).appendingPathComponent(file)
      let base = (file as NSString).deletingPathExtension
      let meta = Self.claudeMeta(at: (directory as NSString).appendingPathComponent(base + ".meta.json"))
      let attributes = try? fileManager.attributesOfItem(atPath: path)
      let lastLine = Self.lastLine(ofFileAt: path)
      return SessionSubagent(
        id: base,
        name: meta?.description ?? base,
        kind: meta?.agentType,
        status: lastLine.map(Self.claudeIsDone) == true ? .done : .running,
        startedAt: attributes?[.creationDate] as? Date,
        lastActivityAt: attributes?[.modificationDate] as? Date,
        transcriptPath: path
      )
    }
  }

  static func claudeMeta(at path: String) -> (agentType: String?, description: String?)? {
    guard let data = FileManager.default.contents(atPath: path),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return (object["agentType"] as? String, object["description"] as? String)
  }

  /// A Claude subagent is done when its last entry is an assistant turn that ended.
  static func claudeIsDone(lastLine: String) -> Bool {
    guard let data = lastLine.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["type"] as? String == "assistant",
      let message = object["message"] as? [String: Any]
    else { return false }
    return message["stop_reason"] as? String == "end_turn"
  }

  // MARK: - Codex

  private func codexSubagents(for session: CLISession) -> [SessionSubagent] {
    var result: [SessionSubagent] = []
    // The session snapshot can lag a live session; its transcript's mtime does not.
    let fileModified = session.sessionFilePath.flatMap {
      (try? fileManager.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
    }
    let lastActivity = max(session.lastActivityAt, fileModified ?? .distantPast)
    for path in codexCandidateFiles(since: session.sessionFilePath, until: lastActivity) {
      if codexParentByFile[path] == nil {
        codexParentByFile[path] = Self.firstLine(ofFileAt: path).flatMap(Self.codexSpawnMeta)
      }
      guard let meta = codexParentByFile[path] ?? nil, meta.parentID == session.id else { continue }
      let attributes = try? fileManager.attributesOfItem(atPath: path)
      let lastLine = Self.lastLine(ofFileAt: path)
      result.append(
        SessionSubagent(
          id: path,
          name: meta.name,
          kind: nil,
          status: lastLine.map(Self.codexIsDone) == true ? .done : .running,
          startedAt: meta.startedAt,
          lastActivityAt: attributes?[.modificationDate] as? Date,
          transcriptPath: path
        ))
    }
    return result
  }

  /// Rollouts from the parent's first to its last active day: subagents only start
  /// while the parent runs, so long-lived sessions don't scan weeks of files.
  private func codexCandidateFiles(since parentFile: String?, until lastActivity: Date) -> [String] {
    let root = (codexDataPath as NSString).appendingPathComponent("sessions")
    let calendar = Calendar(identifier: .gregorian)
    var day = Self.dayFromRolloutPath(parentFile) ?? calendar.startOfDay(for: lastActivity)
    var files: [String] = []
    let lastDay = calendar.startOfDay(for: min(lastActivity, .now))
    while day <= lastDay {
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      let directory = String(
        format: "%@/%04d/%02d/%02d", root, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
      if let names = try? fileManager.contentsOfDirectory(atPath: directory) {
        files += names.filter { $0.hasSuffix(".jsonl") }.map { "\(directory)/\($0)" }
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return files
  }

  static func dayFromRolloutPath(_ path: String?) -> Date? {
    guard let path else { return nil }
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 4,
      let year = Int(parts[parts.count - 4]), let month = Int(parts[parts.count - 3]),
      let day = Int(parts[parts.count - 2])
    else { return nil }
    return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
  }

  static func codexSpawnMeta(firstLine: String) -> CodexSpawnMeta? {
    guard let data = firstLine.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = object["payload"] as? [String: Any],
      let source = payload["source"] as? [String: Any],
      let subagent = source["subagent"] as? [String: Any],
      let spawn = subagent["thread_spawn"] as? [String: Any],
      let parentID = spawn["parent_thread_id"] as? String ?? payload["parent_thread_id"] as? String
    else { return nil }
    let path = spawn["agent_path"] as? String ?? ""
    let name = path.split(separator: "/").last.map(String.init) ?? "subagent"
    let started = (payload["timestamp"] as? String).flatMap(Self.parseDate)
    return CodexSpawnMeta(parentID: parentID, name: name.replacingOccurrences(of: "_", with: " "), startedAt: started)
  }

  static func codexIsDone(lastLine: String) -> Bool {
    guard let data = lastLine.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = object["payload"] as? [String: Any]
    else { return false }
    return payload["type"] as? String == "task_complete"
  }

  // MARK: - File helpers

  private static func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }

  static func firstLine(ofFileAt path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    // Session meta lines can be large (instructions); read until the first newline.
    var buffer = Data()
    while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      if let newline = chunk.firstIndex(of: 0x0A) {
        buffer.append(chunk[chunk.startIndex..<newline])
        break
      }
      buffer.append(chunk)
      if buffer.count > 4 * 1024 * 1024 { break }
    }
    return String(data: buffer, encoding: .utf8)
  }

  /// Last non-empty line, read from the end so large transcripts stay cheap.
  static func lastLine(ofFileAt path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
    var readSize: UInt64 = 64 * 1024
    while true {
      let start = size > readSize ? size - readSize : 0
      try? handle.seek(toOffset: start)
      guard let data = try? handle.readToEnd() else { return nil }
      // Lossy: the window can start mid-character; only the last line matters.
      let text = String(decoding: data, as: UTF8.self)
      let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
      if let last = lines.last, start == 0 || lines.count > 1 {
        return String(last)
      }
      if start == 0 { return nil }
      readSize *= 4
    }
  }
}
