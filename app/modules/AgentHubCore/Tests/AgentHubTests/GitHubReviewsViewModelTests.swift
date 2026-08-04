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

  private func isolatedDefaults() -> UserDefaults {
    let suiteName = "GitHubReviewsViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
