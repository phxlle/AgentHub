import Foundation
import Testing

@testable import AgentHubCore

@Suite("Chat transcript reader")
struct ChatTranscriptReaderTests {
  private func kinds(_ items: [ChatTranscriptItem]) -> [ChatTranscriptItem.Kind] { items.map(\.kind) }

  @Test("Claude: your text, replies, and tool steps; meta and thinking stay hidden")
  func claudeLines() {
    let lines = [
      #"{"type":"user","message":{"role":"user","content":"Fix the login bug"}}"#,
      #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#,
      #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
      #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"On it."},{"type":"tool_use","name":"Bash","input":{"command":"git status\nmore"}}]}}"#,
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
    ]
    let items = lines.flatMap { ChatTranscriptReader.claudeItems(line: Data($0.utf8), idPrefix: "x") }
    #expect(kinds(items) == [.user("Fix the login bug"), .assistant("On it."), .tool(name: "Bash", summary: "git status")])
  }

  @Test("Codex: injected context is dropped, exec commands become tool steps")
  func codexLines() {
    let lines = [
      ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n..."},{"type":"input_text","text":"<environment_context>x</environment_context>"},{"type":"input_text","text":"Review PR 12"}]}}"##,
      ##"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"##,
      ##"{"type":"response_item","payload":{"type":"reasoning","encrypted_content":"x"}}"##,
      ##"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd:\"gh pr view 12\"})"}}"##,
      ##"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"git\",\"diff\"]}"}}"##,
      ##"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Looks good."}]}}"##,
    ]
    let items = lines.flatMap { ChatTranscriptReader.codexItems(line: Data($0.utf8), idPrefix: "x") }
    #expect(
      kinds(items) == [
        .user("Review PR 12"), .tool(name: "exec", summary: "gh pr view 12"),
        .tool(name: "shell", summary: "git diff"), .assistant("Looks good."),
      ])
  }

  @Test("Reads only appended lines and waits for a partial last line")
  func incremental() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let first = #"{"type":"user","message":{"role":"user","content":"one"}}"# + "\n"
    try first.write(to: url, atomically: true, encoding: .utf8)
    let reader = ChatTranscriptReader()
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("one")])

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"two"}]}}"# + "\n" + #"{"type":"user","mes"#).utf8))
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("one"), .assistant("two")])

    try handle.write(contentsOf: Data((#"sage":{"role":"user","content":"three"}}"# + "\n").utf8))
    try handle.close()
    #expect(
      kinds(await reader.items(at: url.path, provider: .claude))
        == [.user("one"), .assistant("two"), .user("three")])
  }
}

@Suite("Chat actions")
struct ChatActionsTests {
  @Test("Questions get numbered options plus yes/no; statements get nothing")
  func quickReplies() {
    let question = """
      I found two ways to fix it.

      1. **Patch** the parser
      2. Rewrite the reader

      Which one do you want?
      """
    let replies = QuickReply.replies(for: question)
    #expect(replies.map(\.message) == ["1", "2", "Yes, go ahead.", "No."])
    #expect(replies.first?.label == "1 · Patch the parser")
    #expect(QuickReply.replies(for: "Done. All tests pass.").isEmpty)
  }

  @Test("Fenced code blocks are extracted for one-click copy")
  func codeBlocks() {
    let text = "Run this:\n\n```bash\nnpm install\nnpm test\n```\n\nand ```\n```\n"
    let blocks = ChatCodeBlocks.extract(from: text)
    #expect(blocks.map(\.code) == ["npm install\nnpm test"])
    #expect(blocks.first?.preview == "npm install")
  }
}

@Suite("Chat markdown text")
struct ChatMarkdownTextTests {
  @Test("Splits prose and fenced code; keeps an unclosed fence as code")
  func segments() {
    let text = "Intro **bold**\n\n```swift\nlet x = 1\n```\nAfter\n```\nopen"
    #expect(
      ChatMarkdownText.segments(of: text)
        == [.prose("Intro **bold**"), .code("let x = 1"), .prose("After"), .code("open")])
  }

  @Test("Inline markdown keeps line breaks and turns headings bold")
  func inline() {
    let rendered = ChatMarkdownText.inline("# Title\nline one\nline `two`")
    #expect(String(rendered.characters) == "Title\nline one\nline two")
  }
}
