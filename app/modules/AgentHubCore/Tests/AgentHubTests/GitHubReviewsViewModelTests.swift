import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

private final class GitHubProjectReviewServiceStub:
  GitHubProjectReviewServiceProtocol, @unchecked Sendable
{
  var projects: [GitHubReviewProject] = []
  var pullRequests: [GitHubProjectPullRequest] = []
  private(set) var requestedViewIDs: [String] = []

  func listProjects() async throws -> [GitHubReviewProject] {
    projects
  }

  func listPullRequests(
    project: GitHubReviewProject,
    view: GitHubProjectView,
    limit: Int
  ) async throws -> [GitHubProjectPullRequest] {
    requestedViewIDs.append(view.id)
    return pullRequests
  }
}

@MainActor
@Suite("GitHub Reviews view model")
struct GitHubReviewsViewModelTests {
  @Test("Selects the Code review view and removes draft results")
  func loadsPreferredReviewView() async {
    let service = GitHubProjectReviewServiceStub()
    let project = makeProject()
    service.projects = [project]
    service.pullRequests = [
      makePullRequest(id: "ready", isDraft: false),
      makePullRequest(id: "draft", isDraft: true),
    ]
    let defaults = isolatedDefaults()
    let viewModel = GitHubReviewsViewModel(service: service, userDefaults: defaults)

    await viewModel.load()

    #expect(viewModel.selectedProjectID == project.id)
    #expect(viewModel.selectedView?.name == "Code review")
    #expect(service.requestedViewIDs == ["code-review"])
    #expect(viewModel.pullRequests.map(\.id) == ["ready"])
  }

  @Test("Review prompt carries Project context and stays read-only")
  func reviewPromptContainsGuardrails() {
    let project = makeProject()
    let pullRequest = makePullRequest(id: "ready", isDraft: false)
    let prompt = GitHubProjectReviewPromptBuilder.prompt(
      pullRequest: pullRequest,
      project: project,
      view: project.views[1]
    )

    #expect(prompt.contains(pullRequest.url))
    #expect(prompt.contains("GitHub Project: gl-ventures / XFA"))
    #expect(prompt.contains("status:\"Code Review 🔎\""))
    #expect(prompt.contains("Do not edit files, commit, push"))
    #expect(prompt.contains("file and line references"))
  }

  @Test("Links the latest review session for each provider by exact pull request context")
  func linksExistingReviewSessions() {
    let pullRequest = makePullRequest(id: "ready", isDraft: false)
    let olderCodex = makeSession(
      id: "codex-old",
      date: Date(timeIntervalSince1970: 100),
      message: "Review this pull request independently: \(pullRequest.url)"
    )
    let newerCodex = makeSession(
      id: "codex-new",
      date: Date(timeIntervalSince1970: 200),
      message: "Perform a read-only review for \(pullRequest.url)"
    )
    let implementationSession = makeSession(
      id: "implementation",
      date: Date(timeIntervalSince1970: 300),
      message: "Implementation finished at \(pullRequest.url)"
    )
    let claude = makeSession(
      id: "claude-review",
      date: Date(timeIntervalSince1970: 150),
      message: "Review this pull request independently: \(pullRequest.url)"
    )

    let links = GitHubReviewSessionLinker.links(
      for: pullRequest,
      launches: [],
      inventories: [
        GitHubReviewSessionInventory(
          provider: .codex,
          sessions: [olderCodex, newerCodex, implementationSession],
          pendingSessions: [],
          resolvedPendingSessionIDs: [:],
          customNames: ["codex-new": "PR 450 review"],
          statuses: ["codex-new": .waitingForUser]
        ),
        GitHubReviewSessionInventory(
          provider: .claude,
          sessions: [claude],
          pendingSessions: [],
          resolvedPendingSessionIDs: [:],
          customNames: [:],
          statuses: [:]
        ),
      ]
    )

    #expect(links.map(\.session.id) == ["codex-new", "claude-review"])
    #expect(links.first?.displayName == "PR 450 review")
    #expect(links.first?.statusText == "Ready")
    #expect(!links.contains { $0.session.id == "implementation" })
  }

  @Test("Keeps an explicit review launch linked while its pending session resolves")
  func linksPendingAndResolvedReviewLaunch() {
    let pullRequest = makePullRequest(id: "ready", isDraft: false)
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "main", path: "/tmp/xfa-native-mobile")
    )
    let launch = GitHubReviewSessionLaunch(
      pullRequestID: pullRequest.id,
      provider: .claude,
      pendingID: pending.id,
      projectPath: pending.projectPath,
      launchedAt: pending.startedAt
    )
    let pendingInventory = GitHubReviewSessionInventory(
      provider: .claude,
      sessions: [],
      pendingSessions: [pending],
      resolvedPendingSessionIDs: [:],
      customNames: [:],
      statuses: [:]
    )

    let pendingLinks = GitHubReviewSessionLinker.links(
      for: pullRequest,
      launches: [launch],
      inventories: [pendingInventory]
    )

    #expect(pendingLinks.count == 1)
    #expect(pendingLinks[0].isPending)
    #expect(pendingLinks[0].statusText == "Starting")
    #expect(
      pendingLinks[0].itemID
        == "pending-claude-\(pending.id.uuidString)"
    )

    let resolvedSession = makeSession(
      id: "resolved-review",
      date: Date(timeIntervalSince1970: 400),
      message: nil
    )
    let resolvedInventory = GitHubReviewSessionInventory(
      provider: .claude,
      sessions: [resolvedSession],
      pendingSessions: [],
      resolvedPendingSessionIDs: [pending.id: resolvedSession.id],
      customNames: [:],
      statuses: [resolvedSession.id: .thinking]
    )

    let resolvedLinks = GitHubReviewSessionLinker.links(
      for: pullRequest,
      launches: [launch],
      inventories: [resolvedInventory]
    )

    #expect(resolvedLinks.count == 1)
    #expect(!resolvedLinks[0].isPending)
    #expect(resolvedLinks[0].session.id == resolvedSession.id)
    #expect(resolvedLinks[0].statusText == "Working")
  }

  private func makeProject() -> GitHubReviewProject {
    GitHubReviewProject(
      id: "project-3",
      ownerLogin: "gl-ventures",
      ownerType: "Organization",
      number: 3,
      title: "XFA",
      url: "https://github.com/orgs/gl-ventures/projects/3",
      views: [
        GitHubProjectView(
          id: "board",
          number: 1,
          name: "Board",
          filter: "-is:closed",
          layout: "BOARD_LAYOUT"
        ),
        GitHubProjectView(
          id: "code-review",
          number: 48,
          name: "Code review",
          filter: #"is:pr status:"Code Review 🔎" -is:draft"#,
          layout: "TABLE_LAYOUT"
        ),
      ]
    )
  }

  private func makePullRequest(id: String, isDraft: Bool) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: id,
      number: 450,
      title: "XFA-2129: Add production Teams Maestro test",
      url: "https://github.com/gl-ventures/xfa-native-mobile/pull/450",
      repositoryName: "xfa-native-mobile",
      repositoryNameWithOwner: "gl-ventures/xfa-native-mobile",
      authorLogin: "phxlle",
      updatedAt: Date(timeIntervalSince1970: 100),
      isDraft: isDraft,
      state: "open",
      projectStatus: "Code Review 🔎"
    )
  }

  private func makeSession(id: String, date: Date, message: String?) -> CLISession {
    CLISession(
      id: id,
      projectPath: "/tmp/xfa-native-mobile",
      branchName: "main",
      lastActivityAt: date,
      firstMessage: message
    )
  }

  private func isolatedDefaults() -> UserDefaults {
    let suiteName = "GitHubReviewsViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
