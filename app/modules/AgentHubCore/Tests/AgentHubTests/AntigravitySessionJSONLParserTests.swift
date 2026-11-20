import Foundation
import Testing

@testable import AgentHubCore

@Suite("AntigravitySessionJSONLParser")
struct AntigravitySessionJSONLParserTests {

  @Test("Summary strips the USER_REQUEST wrapper and counts user and assistant text steps")
  func parsesSessionSummary() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "transcript.jsonl")
    try [
      userInput("Fix the failing test", at: "2026-11-19T08:04:43Z"),
      plannerToolCall("run_command", at: "2026-11-19T08:04:44Z"),
      generic("exit 0", at: "2026-11-19T08:04:45Z"),
      plannerText("Done, the test passes.", at: "2026-11-19T08:04:50Z"),
    ].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

    let summary = AntigravitySessionJSONLParser.parseSessionSummaryFile(at: file.path)
    #expect(summary.messageCount == 2)
    #expect(summary.firstUserMessage == "Fix the failing test")
    #expect(summary.lastUserMessage == "Fix the failing test")
    #expect(summary.lastActivityAt == iso8601Date("2026-11-19T08:04:50Z"))
  }

  @Test("Tool call without a result step is executing, then awaiting approval after the timeout")
  func pendingToolCallStatus() {
    var result = AntigravitySessionJSONLParser.ParseResult()
    let now = ISO8601DateFormatter().string(from: Date())
    AntigravitySessionJSONLParser.parseNewLines(
      [userInput("ls", at: now), plannerToolCall("run_command", at: now)],
      into: &result, approvalTimeoutSeconds: 30)

    #expect(result.currentStatus == .executingTool(name: "run_command"))
    #expect(result.pendingToolUses.map(\.toolName) == ["run_command"])

    var stale = AntigravitySessionJSONLParser.ParseResult()
    let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
    AntigravitySessionJSONLParser.parseNewLines(
      [userInput("ls", at: old), plannerToolCall("run_command", at: old)],
      into: &stale, approvalTimeoutSeconds: 30)
    #expect(stale.currentStatus == .awaitingApproval(tool: "run_command"))
  }

  @Test("Result step closes the tool call; final text waits for the user and keeps tokens")
  func completedTurn() {
    var result = AntigravitySessionJSONLParser.ParseResult()
    let now = ISO8601DateFormatter().string(from: Date())
    AntigravitySessionJSONLParser.parseNewLines(
      [
        userInput("ls", at: now),
        plannerToolCall("run_command", at: now),
        generic("f1.txt", at: now),
        plannerText("done.", at: now),
      ],
      into: &result, approvalTimeoutSeconds: 30)

    #expect(result.pendingToolUses.isEmpty)
    #expect(result.currentStatus == .waitingForUser)
    #expect(result.lastAssistantMessage == "done.")
    #expect(result.model == "gemini-3.8-flash-high")
    #expect(result.totalInputTokens == 2 * (100 + 20))
    #expect(result.totalOutputTokens == 2 * 7)
    #expect(result.lastInputTokens == 120)
    #expect(result.messageCount == 2)
  }

  @Test("Ask-question tool is treated as waiting for the user's answer")
  func interactiveToolAwaitsApproval() {
    var result = AntigravitySessionJSONLParser.ParseResult()
    let now = ISO8601DateFormatter().string(from: Date())
    AntigravitySessionJSONLParser.parseNewLines(
      [userInput("pick one", at: now), plannerToolCall("ask_question", at: now)],
      into: &result, approvalTimeoutSeconds: 3600)
    #expect(result.currentStatus == .awaitingApproval(tool: "ask_question"))
  }

  // MARK: - Fixtures

  private func userInput(_ text: String, at createdAt: String) -> String {
    jsonLine([
      "step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE",
      "created_at": createdAt,
      "content": "<USER_REQUEST>\n\(text)\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: x.\n</ADDITIONAL_METADATA>",
    ])
  }

  private func plannerToolCall(_ tool: String, at createdAt: String) -> String {
    jsonLine([
      "step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
      "created_at": createdAt, "model": "gemini-3.8-flash-high",
      "input_tokens": 100, "cache_read_tokens": 20, "output_tokens": 7,
      "tool_calls": [["name": tool, "args": ["CommandLine": "ls"]]],
    ])
  }

  private func generic(_ output: String, at createdAt: String) -> String {
    jsonLine([
      "step_index": 2, "source": "MODEL", "type": "GENERIC", "status": "DONE",
      "created_at": createdAt, "content": output,
    ])
  }

  private func plannerText(_ text: String, at createdAt: String) -> String {
    jsonLine([
      "step_index": 3, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
      "created_at": createdAt, "model": "gemini-3.8-flash-high",
      "input_tokens": 100, "cache_read_tokens": 20, "output_tokens": 7, "content": text,
    ])
  }

  private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "antigravity-parser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func iso8601Date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
