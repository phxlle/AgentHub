import Foundation
import Testing

@testable import AgentHubCore

@Suite("Inherited agent session environment")
struct InheritedAgentSessionEnvironmentTests {
  @Test("Only session identity markers are dropped, user settings stay")
  func markers() {
    let environment = [
      "CLAUDECODE": "1",
      "CLAUDE_CODE_CHILD_SESSION": "1",
      "CLAUDE_CODE_SESSION_ID": "abc",
      "CLAUDE_CODE_MESSAGING_TOKEN": "secret",
      "CLAUDE_CODE_USE_BEDROCK": "1",
      "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8000",
      "PATH": "/usr/bin",
    ]
    #expect(
      InheritedAgentSessionEnvironment.markers(in: environment)
        == ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ID"])
  }

  @Test("Scrubbing removes the markers from the process environment")
  func scrub() {
    setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1)
    setenv("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "8000", 1)
    InheritedAgentSessionEnvironment.scrubFromProcess()
    #expect(ProcessInfo.processInfo.environment["CLAUDE_CODE_CHILD_SESSION"] == nil)
    #expect(ProcessInfo.processInfo.environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "8000")
    unsetenv("CLAUDE_CODE_MAX_OUTPUT_TOKENS")
  }
}
