//
//  ChatTranscriptReader.swift
//  AgentHub
//
//  Turns a Claude, Codex or Antigravity session transcript (JSONL) into chat items for the
//  Chat view: your messages, the agent's replies, and compact tool steps.
//  Read-only and incremental: only bytes appended since the last read are parsed.
//

import Foundation

/// A fact the transcript records in line with the messages.
public enum ChatTranscriptNotice: Equatable, Sendable {
  /// Claude wrote a `compact_boundary` record: the context was compacted.
  case contextCompacted(preTokens: Int?, durationMs: Int?)

  public var isCompaction: Bool {
    if case .contextCompacted = self { return true }
    return false
  }
}

/// One runtime record in the transcript, applied to `ChatTranscriptRuntime`.
public enum ChatTranscriptRuntimeEvent: Equatable, Sendable {
  /// `queue-operation` / `enqueue`: Claude Code queued input behind the running
  /// turn. Internal entries (task notifications) are machine events, not yours.
  case enqueue(text: String, at: Date?, isInternal: Bool)
  /// `queue-operation` / `dequeue`: the oldest queued entry was submitted.
  case dequeue
  /// `queue-operation` / `remove`: that entry left the queue without being submitted.
  case remove(text: String)
  /// A tool result said "Command running in background with ID: …".
  case backgroundTaskStarted(id: String, at: Date?)
  /// A task notification arrived for that id.
  case backgroundTaskFinished(id: String)
}

/// Runtime facts kept for the whole file, independent of the display window
/// that caps `items`. Bounded: at most `cap` queued entries and background tasks.
public struct ChatTranscriptRuntime: Equatable, Sendable {
  public struct QueuedMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let enqueuedAt: Date?
    /// Task notifications and other machine input Claude queues for itself.
    public let isInternal: Bool
  }

  public struct BackgroundTask: Equatable, Sendable, Identifiable {
    public let id: String
    public let startedAt: Date?
  }

  public static let cap = 50

  /// Everything still queued, in order, internal entries included so a
  /// dequeue pops the right one.
  public private(set) var queue: [QueuedMessage] = []
  /// Started in the transcript with no completion notification seen (yet).
  public private(set) var unfinishedBackgroundTasks: [BackgroundTask] = []
  private var sequence = 0

  public init() {}

  /// Queued input the user typed, the part worth showing.
  public var visibleQueue: [QueuedMessage] { queue.filter { !$0.isInternal } }

  public mutating func apply(_ event: ChatTranscriptRuntimeEvent) {
    switch event {
    case .enqueue(let text, let at, let isInternal):
      sequence += 1
      queue.append(QueuedMessage(id: "q\(sequence)", text: text, enqueuedAt: at, isInternal: isInternal))
      if queue.count > Self.cap { queue.removeFirst(queue.count - Self.cap) }
    case .dequeue:
      if !queue.isEmpty { queue.removeFirst() }
    case .remove(let text):
      if let index = queue.firstIndex(where: { $0.text == text }) { queue.remove(at: index) }
    case .backgroundTaskStarted(let id, let at):
      guard !unfinishedBackgroundTasks.contains(where: { $0.id == id }) else { return }
      unfinishedBackgroundTasks.append(BackgroundTask(id: id, startedAt: at))
      if unfinishedBackgroundTasks.count > Self.cap {
        unfinishedBackgroundTasks.removeFirst(unfinishedBackgroundTasks.count - Self.cap)
      }
    case .backgroundTaskFinished(let id):
      // A finish without a start is ignored, never invented.
      unfinishedBackgroundTasks.removeAll { $0.id == id }
    }
  }
}

public struct ChatTranscriptItem: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case user(String)
    case assistant(String)
    /// A tool step, e.g. name "Bash", summary "git status".
    case tool(name: String, summary: String)
    case notice(ChatTranscriptNotice)
  }

  public let id: String
  public let kind: Kind
  public let timestamp: Date?
}

/// What a transcript load found on disk.
public enum ChatTranscriptLoad: Equatable, Sendable {
  /// The file does not exist or cannot be opened yet.
  case missing
  /// The file exists; `items` may be empty while the session has not written a message.
  case loaded([ChatTranscriptItem], runtime: ChatTranscriptRuntime = ChatTranscriptRuntime())

  public var items: [ChatTranscriptItem] {
    if case .loaded(let items, _) = self { return items }
    return []
  }

  public var runtime: ChatTranscriptRuntime {
    if case .loaded(_, let runtime) = self { return runtime }
    return ChatTranscriptRuntime()
  }
}

public protocol ChatTranscriptReading: Sendable {
  /// Items of the transcript at `path`, re-reading only what was appended.
  func items(at path: String, provider: SessionProviderKind) async -> [ChatTranscriptItem]
  /// Like `items`, but tells a missing file apart from an empty one.
  func load(at path: String, provider: SessionProviderKind) async -> ChatTranscriptLoad
}

extension ChatTranscriptReading {
  public func load(at path: String, provider: SessionProviderKind) async -> ChatTranscriptLoad {
    guard FileManager.default.isReadableFile(atPath: path) else { return .missing }
    return .loaded(await items(at: path, provider: provider))
  }
}

public actor ChatTranscriptReader: ChatTranscriptReading {
  private struct State {
    var offset: UInt64 = 0
    var items: [ChatTranscriptItem] = []
    /// Queue and background-task facts for the whole file; not pruned with `items`.
    var runtime = ChatTranscriptRuntime()
    /// Identity of the file the offset belongs to; a new inode means a replaced file.
    var fileID: UInt64?
    /// The last bytes before `offset`; an in-place rewrite changes them.
    var tail = Data()
    var lastUsed = Date()
  }

  private var states: [String: State] = [:]
  /// Keeps long sessions light: the view shows the most recent part.
  private let maxItems: Int
  /// ponytail: small LRU; raise if many columns/windows show different transcripts at once.
  private let maxTrackedFiles: Int
  private static let tailLength = 256
  private static let cancellationCheckInterval = 200

  public init(maxItems: Int = 600, maxTrackedFiles: Int = 24) {
    self.maxItems = maxItems
    self.maxTrackedFiles = maxTrackedFiles
  }

  public func items(at path: String, provider: SessionProviderKind) async -> [ChatTranscriptItem] {
    await load(at: path, provider: provider).items
  }

  public func load(at path: String, provider: SessionProviderKind) async -> ChatTranscriptLoad {
    var state = states[path] ?? State()
    state.lastUsed = Date()
    guard let handle = FileHandle(forReadingAtPath: path) else {
      states.removeValue(forKey: path)
      return .missing
    }
    defer { try? handle.close() }

    let fileID = Self.fileID(of: handle)
    let size = (try? handle.seekToEnd()) ?? 0
    if state.fileID != fileID || size < state.offset
      || !Self.tailMatches(state, handle: handle)
    {
      state = State(fileID: fileID, lastUsed: Date())  // replaced, truncated, or rewritten
    }
    try? handle.seek(toOffset: state.offset)
    guard let data = try? handle.readToEnd(), !data.isEmpty,
      let lastNewline = data.lastIndex(of: 0x0A)  // only complete lines; a partial last line waits
    else {
      remember(state, for: path)
      return .loaded(state.items, runtime: state.runtime)
    }
    let complete = data[data.startIndex...lastNewline]
    let newOffset = state.offset + UInt64(complete.count)

    var lineNumber = state.items.count
    var parsedItems = state.items
    var runtime = state.runtime
    for (index, line) in complete.split(separator: 0x0A).enumerated() {
      // A cancelled caller (the chat moved to another session) stops here; the
      // saved state stays as it was, so the next load starts clean.
      if index % Self.cancellationCheckInterval == 0, Task.isCancelled {
        return .loaded(state.items, runtime: state.runtime)
      }
      lineNumber += 1
      let idPrefix = "\(path)#\(newOffset)-\(lineNumber)"
      switch provider {
      case .claude:
        let entry = Self.claudeEntry(line: Data(line), idPrefix: idPrefix)
        parsedItems.append(contentsOf: entry.items)
        for event in entry.events { runtime.apply(event) }
      case .codex:
        parsedItems.append(contentsOf: Self.codexItems(line: Data(line), idPrefix: idPrefix))
      case .antigravity:
        parsedItems.append(contentsOf: Self.antigravityItems(line: Data(line), idPrefix: idPrefix))
      }
    }
    if parsedItems.count > maxItems {
      parsedItems.removeFirst(parsedItems.count - maxItems)
    }
    state.offset = newOffset
    state.items = parsedItems
    state.runtime = runtime
    state.tail = complete.suffix(Self.tailLength)
    remember(state, for: path)
    return .loaded(state.items, runtime: state.runtime)
  }

  private func remember(_ state: State, for path: String) {
    states[path] = state
    guard states.count > maxTrackedFiles,
      let oldest = states.min(by: { $0.value.lastUsed < $1.value.lastUsed })
    else { return }
    states.removeValue(forKey: oldest.key)
  }

  private static func fileID(of handle: FileHandle) -> UInt64? {
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
    return UInt64(info.st_ino)
  }

  /// False when the bytes just before the saved offset changed: the file was
  /// rewritten in place (same inode) and the cached items no longer match it.
  // shortcut: edits before an unchanged tail are invisible; use full validation if transcripts stop being append-only.
  private static func tailMatches(_ state: State, handle: FileHandle) -> Bool {
    guard state.offset > 0, !state.tail.isEmpty else { return true }
    let start = state.offset - UInt64(state.tail.count)
    guard (try? handle.seek(toOffset: start)) != nil,
      let bytes = try? handle.read(upToCount: state.tail.count)
    else { return false }
    return bytes == state.tail
  }

  // MARK: - Claude

  struct ClaudeEntry {
    var items: [ChatTranscriptItem] = []
    var events: [ChatTranscriptRuntimeEvent] = []
  }

  static func claudeItems(line: Data, idPrefix: String) -> [ChatTranscriptItem] {
    claudeEntry(line: line, idPrefix: idPrefix).items
  }

  static func claudeEntry(line: Data, idPrefix: String) -> ClaudeEntry {
    var entry = ClaudeEntry()
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = object["type"] as? String
    else { return entry }
    let timestamp = (object["timestamp"] as? String).flatMap(parseDate)
    func add(_ kind: ChatTranscriptItem.Kind) {
      entry.items.append(
        ChatTranscriptItem(id: "\(idPrefix)-\(entry.items.count)", kind: kind, timestamp: timestamp))
    }

    switch type {
    case "system":
      // A compaction leaves one system record behind; that is the only evidence
      // the transcript has of it (nothing is written while it runs).
      if object["subtype"] as? String == "compact_boundary" {
        let metadata = object["compactMetadata"] as? [String: Any]
        add(.notice(.contextCompacted(
          preTokens: metadata?["preTokens"] as? Int, durationMs: metadata?["durationMs"] as? Int)))
      }
      return entry
    case "queue-operation":
      // Input typed while a turn runs: enqueue (with content), dequeue (oldest
      // submitted, no content), remove (with content, never submitted).
      switch object["operation"] as? String {
      case "enqueue":
        if let text = object["content"] as? String {
          entry.events.append(.enqueue(text: text, at: timestamp, isInternal: isMachineInput(text)))
        }
      case "dequeue":
        entry.events.append(.dequeue)
      case "remove":
        if let text = object["content"] as? String { entry.events.append(.remove(text: text)) }
      default:
        break
      }
      return entry
    default:
      break
    }
    guard let message = object["message"] as? [String: Any] else { return entry }

    switch type {
    case "user":
      // The compact summary is Claude's own recap, not something the user typed;
      // the compaction notice above already marks the spot.
      if object["isCompactSummary"] as? Bool == true { return entry }
      if object["isMeta"] as? Bool == true { return entry }
      if let text = message["content"] as? String {
        if let taskID = finishedBackgroundTaskID(in: text) {
          entry.events.append(.backgroundTaskFinished(id: taskID))
        } else if let cleaned = cleanedUserText(text) {
          add(.user(cleaned))
        }
      } else if let parts = message["content"] as? [[String: Any]] {
        for part in parts {
          switch part["type"] as? String {
          case "text":
            if let text = part["text"] as? String {
              if let taskID = finishedBackgroundTaskID(in: text) {
                entry.events.append(.backgroundTaskFinished(id: taskID))
              } else if let cleaned = cleanedUserText(text) {
                add(.user(cleaned))
              }
            }
          case "tool_result":
            if let taskID = startedBackgroundTaskID(in: part["content"]) {
              entry.events.append(.backgroundTaskStarted(id: taskID, at: timestamp))
            }
          default:
            break
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
    return entry
  }

  /// Your typed text, minus slash-command and hook wrappers Claude records.
  static func cleanedUserText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if hiddenPrefixes.contains(where: trimmed.hasPrefix) { return nil }
    return trimmed
  }

  private static let hiddenPrefixes = [
    "<command-name>", "<command-message>", "<local-command", "<system-reminder>",
    "<task-notification>", "Caveat: The messages below", "[Request interrupted",
  ]

  /// Queue entries Claude Code adds for itself (task notifications, hook
  /// output): never shown as queued user input, never recalled.
  static func isMachineInput(_ text: String) -> Bool {
    cleanedUserText(text) == nil
  }

  /// The id in "Command running in background with ID: xyz" inside a tool result.
  static func startedBackgroundTaskID(in content: Any?) -> String? {
    let texts: [String]
    if let text = content as? String {
      texts = [text]
    } else if let parts = content as? [[String: Any]] {
      texts = parts.compactMap { $0["text"] as? String }
    } else {
      return nil
    }
    let marker = "Command running in background with ID: "
    for text in texts {
      guard let range = text.range(of: marker) else { continue }
      let id = text[range.upperBound...].prefix { !$0.isWhitespace && $0 != "." }
      if !id.isEmpty { return String(id) }
    }
    return nil
  }

  /// The id of a `<task-notification>` Claude Code appends when a background
  /// command ends. Only a user record that starts with the notification counts.
  static func finishedBackgroundTaskID(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("<task-notification>") || trimmed.hasPrefix("<system-reminder>"),
      trimmed.contains("<task-notification>"),
      let open = trimmed.range(of: "<task-id>"),
      let close = trimmed.range(of: "</task-id>", range: open.upperBound..<trimmed.endIndex)
    else { return nil }
    let id = trimmed[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
    return id.isEmpty ? nil : id
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

  // MARK: - Antigravity

  /// One step per line: USER_INPUT wraps the prompt in `<USER_REQUEST>`,
  /// PLANNER_RESPONSE carries the agent text and its `tool_calls`; GENERIC is tool output.
  static func antigravityItems(line: Data, idPrefix: String) -> [ChatTranscriptItem] {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
    let timestamp = (object["created_at"] as? String).flatMap(parseDate)
    var items: [ChatTranscriptItem] = []
    func add(_ kind: ChatTranscriptItem.Kind) {
      items.append(ChatTranscriptItem(id: "\(idPrefix)-\(items.count)", kind: kind, timestamp: timestamp))
    }

    switch object["type"] as? String {
    case "USER_INPUT":
      if let text = AntigravitySessionJSONLParser.userRequestText(object) { add(.user(text)) }
    case "PLANNER_RESPONSE":
      let text = (object["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { add(.assistant(text)) }
      for call in object["tool_calls"] as? [[String: Any]] ?? [] {
        let name = call["name"] as? String ?? "tool"
        let args = call["args"] as? [String: Any] ?? [:]
        let raw = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        add(.tool(name: name, summary: codexToolSummary(raw)))
      }
    default:
      break  // GENERIC tool output
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
