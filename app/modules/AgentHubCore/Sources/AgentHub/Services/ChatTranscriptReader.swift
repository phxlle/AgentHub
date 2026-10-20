//
//  ChatTranscriptReader.swift
//  AgentHub
//
//  Turns a Claude or Codex session transcript (JSONL) into chat items for the
//  Chat view: your messages, the agent's replies, and compact tool steps.
//  Read-only and incremental: only bytes appended since the last read are parsed.
//

import Foundation

public struct ChatTranscriptItem: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case user(String)
    case assistant(String)
    /// A tool step, e.g. name "Bash", summary "git status".
    case tool(name: String, summary: String)
  }

  public let id: String
  public let kind: Kind
  public let timestamp: Date?
}

public protocol ChatTranscriptReading: Sendable {
  /// Items of the transcript at `path`, re-reading only what was appended.
  func items(at path: String, provider: SessionProviderKind) async -> [ChatTranscriptItem]
}

public actor ChatTranscriptReader: ChatTranscriptReading {
  private struct State {
    var offset: UInt64 = 0
    var items: [ChatTranscriptItem] = []
  }

  private var states: [String: State] = [:]
  /// Keeps long sessions light: the view shows the most recent part.
  private let maxItems: Int

  public init(maxItems: Int = 600) {
    self.maxItems = maxItems
  }

  public func items(at path: String, provider: SessionProviderKind) async -> [ChatTranscriptItem] {
    var state = states[path] ?? State()
    guard let handle = FileHandle(forReadingAtPath: path) else { return state.items }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    if size < state.offset { state = State() }  // file replaced
    try? handle.seek(toOffset: state.offset)
    guard let data = try? handle.readToEnd(), !data.isEmpty else { return state.items }

    // Only complete lines; a partial last line is read next time.
    guard let lastNewline = data.lastIndex(of: 0x0A) else { return state.items }
    let complete = data[data.startIndex...lastNewline]
    state.offset += UInt64(complete.count)

    var lineNumber = state.items.count
    for line in complete.split(separator: 0x0A) {
      lineNumber += 1
      let parsed =
        provider == .claude
        ? Self.claudeItems(line: Data(line), idPrefix: "\(path)#\(state.offset)-\(lineNumber)")
        : Self.codexItems(line: Data(line), idPrefix: "\(path)#\(state.offset)-\(lineNumber)")
      state.items.append(contentsOf: parsed)
    }
    if state.items.count > maxItems {
      state.items.removeFirst(state.items.count - maxItems)
    }
    states[path] = state
    return state.items
  }

  // MARK: - Claude

  static func claudeItems(line: Data, idPrefix: String) -> [ChatTranscriptItem] {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = object["type"] as? String,
      let message = object["message"] as? [String: Any]
    else { return [] }
    let timestamp = (object["timestamp"] as? String).flatMap(parseDate)
    var items: [ChatTranscriptItem] = []
    func add(_ kind: ChatTranscriptItem.Kind) {
      items.append(ChatTranscriptItem(id: "\(idPrefix)-\(items.count)", kind: kind, timestamp: timestamp))
    }

    switch type {
    case "user":
      if object["isMeta"] as? Bool == true { return [] }
      if let text = message["content"] as? String {
        if let cleaned = cleanedUserText(text) { add(.user(cleaned)) }
      } else if let parts = message["content"] as? [[String: Any]] {
        for part in parts where part["type"] as? String == "text" {
          if let text = part["text"] as? String, let cleaned = cleanedUserText(text) {
            add(.user(cleaned))
          }
        }
      }
    case "assistant":
      for part in message["content"] as? [[String: Any]] ?? [] {
        switch part["type"] as? String {
        case "text":
          if let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
          {
            add(.assistant(text))
          }
        case "tool_use":
          let name = part["name"] as? String ?? "Tool"
          add(.tool(name: name, summary: toolSummary(name: name, input: part["input"] as? [String: Any])))
        default:
          break  // thinking stays hidden
        }
      }
    default:
      break
    }
    return items
  }

  /// Your typed text, minus slash-command and hook wrappers Claude records.
  static func cleanedUserText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let hiddenPrefixes = [
      "<command-name>", "<command-message>", "<local-command", "<system-reminder>",
      "Caveat: The messages below", "[Request interrupted",
    ]
    if hiddenPrefixes.contains(where: trimmed.hasPrefix) { return nil }
    return trimmed
  }

  static func toolSummary(name: String, input: [String: Any]?) -> String {
    guard let input else { return "" }
    for key in ["command", "description", "file_path", "pattern", "url", "query", "prompt"] {
      if let value = input[key] as? String, !value.isEmpty {
        return firstLine(value)
      }
    }
    return ""
  }

  // MARK: - Codex

  static func codexItems(line: Data, idPrefix: String) -> [ChatTranscriptItem] {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "response_item",
      let payload = object["payload"] as? [String: Any]
    else { return [] }
    let timestamp = (object["timestamp"] as? String).flatMap(parseDate)
    var items: [ChatTranscriptItem] = []
    func add(_ kind: ChatTranscriptItem.Kind) {
      items.append(ChatTranscriptItem(id: "\(idPrefix)-\(items.count)", kind: kind, timestamp: timestamp))
    }

    switch payload["type"] as? String {
    case "message":
      let role = payload["role"] as? String
      let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
      if role == "user" {
        let visible = texts.filter { !isCodexInjectedContext($0) }
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        if !visible.isEmpty { add(.user(visible.joined(separator: "\n\n"))) }
      } else if role == "assistant" {
        let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { add(.assistant(text)) }
      }
    case "function_call", "custom_tool_call":
      let name = payload["name"] as? String ?? "tool"
      let raw = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
      add(.tool(name: name, summary: codexToolSummary(raw)))
    default:
      break  // reasoning (encrypted), tool outputs
    }
    return items
  }

  /// Blocks Codex adds to the first user turn (AGENTS.md, environment, skills).
  static func isCodexInjectedContext(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes = [
      "# AGENTS.md instructions", "<environment_context>", "<user_instructions>", "<INSTRUCTIONS>",
      "<skills_instructions>", "<permissions instructions>", "<turn_aborted>", "<user_shell_command>",
    ]
    return prefixes.contains(where: trimmed.hasPrefix)
  }

  /// The command of an exec call when present (`cmd:"git status"`), else the first line.
  static func codexToolSummary(_ raw: String) -> String {
    if let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      if let command = object["cmd"] as? String ?? object["command"] as? String { return firstLine(command) }
      if let parts = object["command"] as? [String] { return firstLine(parts.joined(separator: " ")) }
    }
    if let range = raw.range(of: #"cmd:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
      let match = String(raw[range])
      if let open = match.firstIndex(of: "\"") {
        let inner = match[match.index(after: open)...].dropLast()
        return firstLine(String(inner).replacingOccurrences(of: "\\\"", with: "\""))
      }
    }
    return firstLine(raw)
  }

  // MARK: - Helpers

  static func firstLine(_ text: String) -> String {
    let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return line.count > 160 ? String(line.prefix(159)) + "…" : line
  }

  private static func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}
