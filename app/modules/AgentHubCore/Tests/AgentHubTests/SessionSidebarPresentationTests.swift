import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session sidebar presentation")
struct SessionSidebarPresentationTests {
  @Test("Uses the custom session name as the primary title")
  func customNameIsPrimary() throws {
    let pullRequest = try #require(
      GitHubPullRequestURLReference(
        urlString: "https://github.com/gl-ventures/xfa-dashboard/pull/1186"
      )
    )
    let session = makeSession(
      branchName: "codex/xfa-3277-status-icon",
      firstMessage: "Perform an independent code review."
    )

    let presentation = SessionSidebarPresentation(
      session: session,
      customName: "XFA-3277: Fix device status icon alignment",
      linkedPullRequests: [pullRequest]
    )

    #expect(presentation.title == "XFA-3277: Fix device status icon alignment")
    #expect(
      presentation.context
        == "Reviewing PR #1186 · gl-ventures/xfa-dashboard · codex/xfa-3277-status-icon"
    )
    #expect(presentation.linkedPullRequest == pullRequest)
  }

  @Test("Suppresses a misleading default branch for a linked pull request")
  func linkedPullRequestSuppressesMainBranch() throws {
    let pullRequest = try #require(
      GitHubPullRequestURLReference(
        urlString: "https://github.com/gl-ventures/xfa-dashboard/pull/1186"
      )
    )
    let session = makeSession(
      branchName: "main",
      firstMessage: "Perform an independent code review."
    )

    let presentation = SessionSidebarPresentation(
      session: session,
      customName: "Fix device status icon alignment",
      linkedPullRequests: [pullRequest]
    )

    #expect(presentation.context == "Reviewing PR #1186 · gl-ventures/xfa-dashboard")
    #expect(!presentation.context.contains("main"))
  }

  @Test("Uses a feature branch instead of a repeated launch prompt")
  func featureBranchIsPrimary() {
    let session = makeSession(
      branchName: "codex/xfa-3313-discovery-url",
      firstMessage: "Perform an independent code review."
    )

    let presentation = SessionSidebarPresentation(
      session: session,
      customName: nil,
      linkedPullRequests: []
    )

    #expect(presentation.title == "codex/xfa-3313-discovery-url")
    #expect(presentation.context == "xfa-dashboard")
  }

  @Test("Falls back to repository and session id instead of the prompt")
  func repositoryFallbackIsUnique() {
    let session = makeSession(
      branchName: "main",
      firstMessage: "Perform an independent code review."
    )

    let presentation = SessionSidebarPresentation(
      session: session,
      customName: nil,
      linkedPullRequests: []
    )

    #expect(presentation.title == "xfa-dashboard · 019fc0db")
    #expect(presentation.context == "xfa-dashboard · main")
  }

  private func makeSession(branchName: String, firstMessage: String) -> CLISession {
    CLISession(
      id: "019fc0db-example-session",
      projectPath: "/Users/dev/Github/xfa-dashboard",
      branchName: branchName,
      firstMessage: firstMessage
    )
  }
}
