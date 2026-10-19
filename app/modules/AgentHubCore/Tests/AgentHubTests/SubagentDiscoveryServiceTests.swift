import Foundation
import Testing

@testable import AgentHubCore

@Suite("Subagent discovery")
struct SubagentDiscoveryServiceTests {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subagents-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  @Test("Claude: reads subagents next to the session file, with type and status")
  func claudeSubagents() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionFile = root.appendingPathComponent("project/abc.jsonl")
    try write("{}\n", to: sessionFile)
    let dir = root.appendingPathComponent("project/abc/subagents")
    try write(
      #"{"type":"user","message":{"role":"user","content":"go"}}"# + "\n"
        + #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"# + "\n",
      to: dir.appendingPathComponent("agent-1.jsonl"))
    try write(
      #"{"agentType":"Explore","description":"Find callers"}"#,
      to: dir.appendingPathComponent("agent-1.meta.json"))
    try write(
      #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}"# + "\n",
      to: dir.appendingPathComponent("agent-2.jsonl"))

    let session = CLISession(
      id: "abc", projectPath: "/p", lastActivityAt: .now, sessionFilePath: sessionFile.path)
    let found = await SubagentDiscoveryService(codexDataPath: root.path)
      .subagents(for: session, provider: .claude)
      .sorted { $0.id < $1.id }

    #expect(found.map(\.name) == ["Find callers", "agent-2"])
    #expect(found.map(\.kind) == ["Explore", nil])
    #expect(found.map(\.status) == [.done, .running])
  }

  @Test("Codex: finds spawned threads of this session, skips guardian reviews and other parents")
  func codexSubagents() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.dateComponents([.year, .month, .day], from: .now)
    let dayDir = root.appendingPathComponent(
      String(format: "sessions/%04d/%02d/%02d", day.year!, day.month!, day.day!))
    let parentFile = dayDir.appendingPathComponent("rollout-parent.jsonl")
    try write(#"{"type":"session_meta","payload":{"id":"P1"}}"# + "\n", to: parentFile)

    func meta(_ source: String, parent: String = "P1") -> String {
      #"{"type":"session_meta","payload":{"id":"x","parent_thread_id":"\#(parent)","timestamp":"2026-10-19T10:00:00.000Z","source":\#(source)}}"#
    }
    try write(
      meta(#"{"subagent":{"thread_spawn":{"parent_thread_id":"P1","depth":1,"agent_path":"/root/mobile_ci_review"}}}"#)
        + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n",
      to: dayDir.appendingPathComponent("rollout-a.jsonl"))
    try write(
      meta(#"{"subagent":{"thread_spawn":{"parent_thread_id":"P1","depth":1,"agent_path":"/root/docs"}}}"#)
        + "\n" + #"{"type":"response_item","payload":{"type":"message"}}"# + "\n",
      to: dayDir.appendingPathComponent("rollout-b.jsonl"))
    try write(
      meta(#"{"subagent":{"other":"guardian"}}"#) + "\n",
      to: dayDir.appendingPathComponent("rollout-guardian.jsonl"))
    try write(
      meta(#"{"subagent":{"thread_spawn":{"parent_thread_id":"OTHER","depth":1,"agent_path":"/root/x"}}}"#, parent: "OTHER") + "\n",
      to: dayDir.appendingPathComponent("rollout-other.jsonl"))

    let session = CLISession(
      id: "P1", projectPath: "/p", lastActivityAt: .now, sessionFilePath: parentFile.path)
    let found = await SubagentDiscoveryService(codexDataPath: root.path)
      .subagents(for: session, provider: .codex)
      .sorted { $0.name < $1.name }

    #expect(found.map(\.name) == ["docs", "mobile ci review"])
    #expect(found.map(\.status) == [.running, .done])
  }

  @Test("Last line is read from the end of large transcripts")
  func lastLineOfLargeFile() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("big.jsonl")
    let filler = String(repeating: "é", count: 70_000)
    try write("{\"a\":\"\(filler)\"}\n{\"last\":true}\n", to: file)
    #expect(SubagentDiscoveryService.lastLine(ofFileAt: file.path) == #"{"last":true}"#)
  }
}
