import Foundation
import Testing

@testable import AgentHubCore

@Suite("Antigravity launch arguments")
struct AntigravityLaunchArgumentsTests {
  private let configuration = CLICommandConfiguration.antigravityDefault

  @Test("New session passes plan mode, model, effort and the prompt interactively")
  func newSessionArguments() {
    let args = configuration.argumentsForSession(
      sessionId: "pending-123",
      prompt: "Fix the test",
      agentHubMCPServerPath: "/Applications/AgentHub.app/Contents/Helpers/agenthub",
      dangerouslySkipPermissions: true,
      permissionModePlan: true,
      model: "gemini-3.8-flash-high",
      effortLevel: "high"
    )
    #expect(args == ["--mode", "plan", "--model", "gemini-3.8-flash-high", "--effort", "high", "-i", "Fix the test"])
  }

  @Test("Skip-permissions is used when plan mode is off")
  func skipPermissions() {
    let args = configuration.argumentsForSession(sessionId: nil, prompt: nil, dangerouslySkipPermissions: true)
    #expect(args == ["--dangerously-skip-permissions"])
  }

  @Test("Resume reuses the conversation and does not re-send new-session flags")
  func resumeArguments() {
    let args = configuration.argumentsForSession(
      sessionId: "11ba75cf-e514-446b-8ef1-e8888f3bc1ca",
      prompt: "continue",
      dangerouslySkipPermissions: true,
      model: "gemini-3.8-flash-high"
    )
    #expect(args == ["--conversation", "11ba75cf-e514-446b-8ef1-e8888f3bc1ca", "-i", "continue"])
  }

  @Test("Wrapper command injects agy and passes provider arguments after --")
  func wrapperCommand() {
    let wrapper = CLICommandConfiguration(command: "agenthub", mode: .antigravity, extraArgs: ["--verbose"])
    let args = wrapper.argumentsForSession(sessionId: nil, prompt: "hi")
    #expect(args == ["agy", "--verbose", "--", "-i", "hi"])
  }

  @Test("Provider kind maps from the CLI mode")
  func providerKindMapping() {
    #expect(SessionProviderKind(cliMode: .antigravity) == .antigravity)
    #expect(SessionProviderKind.allCases.contains(.antigravity))
  }
}
