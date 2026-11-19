//
//  AntigravitySessionJSONLParser.swift
//  AgentHub
//
//  Parser for Antigravity CLI transcript JSONL files
//  (`<data>/brain/<conversationId>/.system_generated/logs/transcript.jsonl`).
//
//  One line per step, written when the step completes:
//    {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE",
//     "created_at":"2026-11-19T08:04:43Z","content":"<USER_REQUEST>\n...\n</USER_REQUEST>..."}
//    {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE",
//     "model":"gemini-3.8-flash-high","input_tokens":9633,"cache_read_tokens":0,
//     "output_tokens":363,"tool_calls":[{"name":"run_command","args":{...}}]}
//    {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","content":"<tool output>"}
//    {"step_index":7,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"done."}
//

import AgentHubGitHub
import AgentHubMCPUI
import AgentHubSessionGraph
import Foundation

public struct AntigravitySessionJSONLParser {

  private static let maxRecentActivities = 100
  private static let maxDetectedResourceLinks = 50
  private static let maxDetectedMCPAppResources = 50

  // MARK: - Results

  public struct GlobalStatsParseResult: Sendable {
    public var model: String?
    public var totalInputTokens: Int = 0
    public var totalOutputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var messageCount: Int = 0

    public init() {}
  }

  public struct SessionSummaryParseResult: Sendable {
    public var messageCount: Int = 0
    public var lastActivityAt: Date?
    public var firstUserMessage: String?
    public var lastUserMessage: String?

    public init() {}
  }

  public struct ParseResult: Sendable {
    public var model: String?
    public var lastInputTokens: Int = 0
    public var lastOutputTokens: Int = 0
    public var totalInputTokens: Int = 0
    public var totalOutputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var messageCount: Int = 0
    /// Tool calls whose result step has not been written yet, oldest first.
    public var pendingToolUses: [PendingToolInfo] = []
    public var recentActivities: [ActivityEntry] = []
    public var lastAssistantMessage: String?
    public var lastActivityAt: Date?
    public var sessionStartedAt: Date?
    public var currentStatus: SessionStatus = .idle
    public var hasMermaidContent: Bool = false
    public var detectedResourceLinks: [ResourceLink] = []
    public var detectedMCPAppResources: [MCPAppResourceDescriptor] = []
    public var detectedMCPAppInvocations: [MCPAppInvocation] = []
    public var detectedLocalhostURL: URL?

    public init() {}
  }

  public struct PendingToolInfo: Sendable, Equatable {
    public let toolName: String
    public let toolUseId: String
    public let timestamp: Date
  }

  // MARK: - Public API

  public static func parseForGlobalStats(at path: String) -> GlobalStatsParseResult {
    var result = GlobalStatsParseResult()
    for entry in entries(at: path) {
      guard let type = entry["type"] as? String else { continue }
      switch type {
      case "USER_INPUT":
        result.messageCount += 1
      case "PLANNER_RESPONSE":
        if let model = entry["model"] as? String { result.model = model }
        let input = entry["input_tokens"] as? Int ?? 0
        let cached = entry["cache_read_tokens"] as? Int ?? 0
        result.totalInputTokens += input + cached
        result.totalOutputTokens += entry["output_tokens"] as? Int ?? 0
        result.cacheReadTokens += cached
        if nonEmptyContent(entry) != nil { result.messageCount += 1 }
      default:
        break
      }
    }
    return result
  }

  public static func parseSessionSummaryFile(at path: String) -> SessionSummaryParseResult {
    var result = SessionSummaryParseResult()
    for entry in entries(at: path) {
      if let timestamp = parseTimestamp(entry["created_at"] as? String) {
        result.lastActivityAt = timestamp
      }
      guard let type = entry["type"] as? String else { continue }
      switch type {
      case "USER_INPUT":
        result.messageCount += 1
        guard let message = userRequestText(entry) else { continue }
        let preview = String(message.prefix(500))
        if result.firstUserMessage == nil { result.firstUserMessage = preview }
        result.lastUserMessage = preview
      case "PLANNER_RESPONSE":
        if nonEmptyContent(entry) != nil { result.messageCount += 1 }
      default:
        break
      }
    }
    return result
  }

  public static func parseSessionFile(at path: String, approvalTimeoutSeconds: Int = 0) -> ParseResult {
    var result = ParseResult()
    for entry in entries(at: path) {
      processEntry(entry, into: &result)
    }
    updateCurrentStatus(&result, approvalTimeoutSeconds: approvalTimeoutSeconds)
    return result
  }

  public static func parseNewLines(
    _ lines: [String], into result: inout ParseResult, approvalTimeoutSeconds: Int = 0
  ) {
    for line in lines where !line.isEmpty {
      if let entry = parseEntry(line) {
        processEntry(entry, into: &result)
      }
    }
    updateCurrentStatus(&result, approvalTimeoutSeconds: approvalTimeoutSeconds)
  }

  // MARK: - Parsing

  private static func entries(at path: String) -> [[String: Any]] {
    guard let data = FileManager.default.contents(atPath: path),
      let content = String(data: data, encoding: .utf8)
    else { return [] }
    return content.split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { parseEntry(String($0)) }
  }

  private static func parseEntry(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func processEntry(_ entry: [String: Any], into result: inout ParseResult) {
    guard let type = entry["type"] as? String else { return }
    let timestamp = parseTimestamp(entry["created_at"] as? String)
    if let timestamp {
      if result.sessionStartedAt == nil { result.sessionStartedAt = timestamp }
      result.lastActivityAt = timestamp
    }

    switch type {
    case "USER_INPUT":
      result.messageCount += 1
      let message = userRequestText(entry) ?? ""
      addActivity(type: .userMessage, description: String(message.prefix(80)), timestamp: timestamp, to: &result)

    case "PLANNER_RESPONSE":
      if let model = entry["model"] as? String { result.model = model }
      let input = entry["input_tokens"] as? Int ?? 0
      let cached = entry["cache_read_tokens"] as? Int ?? 0
      let output = entry["output_tokens"] as? Int ?? 0
      result.lastInputTokens = input + cached
      result.lastOutputTokens = output
      result.totalInputTokens += input + cached
      result.totalOutputTokens += output
      result.cacheReadTokens += cached

      if entry["thinking"] as? String != nil {
        addActivity(type: .thinking, description: "Thinking...", timestamp: timestamp, to: &result)
      }

      if let message = nonEmptyContent(entry) {
        result.messageCount += 1
        result.lastAssistantMessage = String(message.suffix(32_000))
        if message.contains("```mermaid") { result.hasMermaidContent = true }
        appendResourceLinks(extractResourceLinks(from: message, timestamp: timestamp), to: &result)
        appendMCPAppResources(MCPAppResourceExtractor.extract(from: message), to: &result)
        if let localhostURL = LocalhostURLNormalizer.extractFirstURL(from: message) {
          result.detectedLocalhostURL = localhostURL
        }
        addActivity(type: .assistantMessage, description: String(message.prefix(80)), timestamp: timestamp, to: &result)
      }

      let stepIndex = entry["step_index"] as? Int ?? result.recentActivities.count
      for (offset, call) in ((entry["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
        guard let name = call["name"] as? String else { continue }
        result.pendingToolUses.append(
          PendingToolInfo(toolName: name, toolUseId: "\(stepIndex)-\(offset)", timestamp: timestamp ?? Date()))
        addActivity(type: .toolUse(name: name), description: name, timestamp: timestamp, to: &result)
      }

    case "GENERIC":
      // Tool output step: closes the oldest pending tool call.
      let toolName = result.pendingToolUses.isEmpty ? "tool" : result.pendingToolUses.removeFirst().toolName
      addActivity(type: .toolResult(name: toolName, success: true), description: "Completed", timestamp: timestamp, to: &result)
      if let output = nonEmptyContent(entry) {
        if let localhostURL = LocalhostURLNormalizer.extractFirstURL(from: output) {
          result.detectedLocalhostURL = localhostURL
        }
        appendResourceLinks(extractResourceLinks(from: output, timestamp: timestamp), to: &result)
        appendMCPAppResources(MCPAppResourceExtractor.extract(from: output), to: &result)
      }

    case "ERROR_MESSAGE":
      let message = (entry["error"] as? String) ?? nonEmptyContent(entry) ?? "Error"
      if let pending = result.pendingToolUses.first {
        result.pendingToolUses.removeFirst()
        addActivity(type: .toolResult(name: pending.toolName, success: false), description: String(message.prefix(80)), timestamp: timestamp, to: &result)
      } else {
        result.lastAssistantMessage = message
        addActivity(type: .assistantMessage, description: String(message.prefix(80)), timestamp: timestamp, to: &result)
      }

    default:
      break
    }
  }

  // MARK: - Status

  /// Antigravity writes a tool call step before the tool runs and the result
  /// step after it finishes. While the CLI waits for the user to approve the
  /// call nothing is written, so a tool call that stays open past the approval
  /// timeout is shown as awaiting approval.
  // ponytail: timeout heuristic; switch to agy PreToolUse hooks for exact approval state.
  public static func updateCurrentStatus(_ result: inout ParseResult, approvalTimeoutSeconds: Int = 0) {
    guard let lastActivity = result.recentActivities.last else {
      result.currentStatus = .idle
      return
    }
    let timeSince = Date().timeIntervalSince(lastActivity.timestamp)

    if case .toolUse(let name) = lastActivity.type, result.pendingToolUses.contains(where: { $0.toolName == name }) {
      if SessionInteractiveInputTool.matches(name) {
        result.currentStatus = .awaitingApproval(tool: name)
        return
      }
      if approvalTimeoutSeconds > 0, timeSince > Double(approvalTimeoutSeconds), timeSince <= 3600 {
        result.currentStatus = .awaitingApproval(tool: name)
        return
      }
    }

    if timeSince > 300 {
      result.currentStatus = .idle
      return
    }

    switch lastActivity.type {
    case .toolUse(let name):
      result.currentStatus = .executingTool(name: name)
    case .toolResult:
      result.currentStatus = timeSince < 60 ? .thinking : .idle
    case .assistantMessage:
      result.currentStatus = .waitingForUser
    case .userMessage:
      result.currentStatus = timeSince < 60 ? .thinking : .idle
    case .thinking:
      result.currentStatus = timeSince < 30 ? .thinking : .idle
    }
  }

  // MARK: - Helpers

  private static func nonEmptyContent(_ entry: [String: Any]) -> String? {
    guard let content = entry["content"] as? String else { return nil }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The user's own text. Antigravity wraps it in `<USER_REQUEST>` and appends
  /// metadata blocks (local time, settings changes) the user never typed.
  static func userRequestText(_ entry: [String: Any]) -> String? {
    guard let content = nonEmptyContent(entry) else { return nil }
    if let start = content.range(of: "<USER_REQUEST>"),
      let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex)
    {
      let text = content[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
    return content
  }

  private static func addActivity(type: ActivityType, description: String, timestamp: Date?, to result: inout ParseResult) {
    result.recentActivities.append(
      ActivityEntry(timestamp: timestamp ?? Date(), type: type, description: description, toolInput: nil))
    if result.recentActivities.count > maxRecentActivities {
      result.recentActivities.removeFirst(result.recentActivities.count - maxRecentActivities)
    }
  }

  private static func appendResourceLinks(_ links: [ResourceLink], to result: inout ParseResult) {
    for link in links where !result.detectedResourceLinks.contains(where: { $0.url == link.url }) {
      result.detectedResourceLinks.append(link)
    }
    if result.detectedResourceLinks.count > maxDetectedResourceLinks {
      result.detectedResourceLinks.removeFirst(result.detectedResourceLinks.count - maxDetectedResourceLinks)
    }
  }

  private static func appendMCPAppResources(_ descriptors: [MCPAppResourceDescriptor], to result: inout ParseResult) {
    for descriptor in descriptors
    where !result.detectedMCPAppResources.contains(where: {
      $0.serverName == descriptor.serverName && $0.uri == descriptor.uri
    }) {
      result.detectedMCPAppResources.append(descriptor)
    }
    if result.detectedMCPAppResources.count > maxDetectedMCPAppResources {
      result.detectedMCPAppResources.removeFirst(result.detectedMCPAppResources.count - maxDetectedMCPAppResources)
    }
  }

  private static func extractResourceLinks(from text: String, timestamp: Date?) -> [ResourceLink] {
    guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s)\\]>\"'`]+") else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    var links: [ResourceLink] = []
    for match in regex.matches(in: text, range: range) {
      guard let matchRange = Range(match.range, in: text) else { continue }
      var urlString = String(text[matchRange])
      while let last = urlString.last, [".", ",", ";", ":"].contains(String(last)) {
        urlString.removeLast()
      }
      links.append(ResourceLink(url: urlString, timestamp: timestamp ?? Date()))
    }
    let pullRequestLinks = links.filter { GitHubPullRequestURLReference(urlString: $0.url) != nil }
    return pullRequestLinks.isEmpty ? links : pullRequestLinks
  }

  private static func parseTimestamp(_ string: String?) -> Date? {
    CodexTimestampParser.parse(string)
  }
}
