import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

private final class GitHubProjectReviewServiceStub:
  GitHubProjectReviewServiceProtocol, @unchecked Sendable
{
  var projects: [GitHubReviewProject] = []
  var pullRequests: [GitHubProjectPullRequest] = []
  var projectsError: GitHubCLIError?
  var pullRequestsError: GitHubCLIError?
  var projectsDelay: Duration?
  var rateLimitReset: Date?
  var login: String?
  func viewerLogin() async -> String? { login }
  private(set) var requestedViewIDs: [String] = []

  func rateLimitResetDate() async -> Date? { rateLimitReset }

  func listProjects() async throws -> [GitHubReviewProject] {
    if let projectsDelay {
      try await Task.sleep(for: projectsDelay)
    }
    if let projectsError { throw projectsError }
    return projects
  }

  func listPullRequests(
    project: GitHubReviewProject,
    view: GitHubProjectView,
    limit: Int
  ) async throws -> [GitHubProjectPullRequest] {
    if let pullRequestsError { throw pullRequestsError }
    requestedViewIDs.append(view.id)
    return pullRequests
  }
}

private actor GitHubReviewSessionStoreStub: GitHubReviewSessionStoreProtocol {
  private var associations: [GitHubReviewSessionAssociation] = []

  func saveGitHubReviewSessionAssociation(
    _ association: GitHubReviewSessionAssociation
  ) async throws {
    associations.removeAll {
      $0.pullRequestID == association.pullRequestID && $0.provider == association.provider
    }
    associations.append(association)
  }

  func githubReviewSessionAssociations() async throws -> [GitHubReviewSessionAssociation] {
    associations
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

  @Test("Focusing a session's pull request selects it and keeps table state on the model")
  func focusesPullRequestFromSession() async {
    let service = GitHubProjectReviewServiceStub()
    service.projects = [makeProject()]
    service.pullRequests = [makePullRequest(id: "ready", isDraft: false)]
    let viewModel = GitHubReviewsViewModel(service: service, userDefaults: isolatedDefaults())
    await viewModel.load()
    viewModel.searchText = "something else"

    viewModel.focusPullRequest(owner: "GL-Ventures", repository: "xfa-native-mobile", number: 450)

    #expect(viewModel.selectedPullRequestID == "ready")
    #expect(viewModel.searchText.isEmpty)

    viewModel.focusPullRequest(owner: "gl-ventures", repository: "other", number: 450)
    #expect(viewModel.selectedPullRequestID == "ready")
  }

  @Test("Own-message template keeps the user's words and optionally adds PR context")
  @MainActor
  func customMessageTemplate() {
    let library = GitHubPromptLibrary(userDefaults: isolatedDefaults())
    let context = GitHubPromptContext(
      pullRequest: makePullRequest(id: "ready", isDraft: false),
      project: makeProject(),
      view: makeProject().views[0],
      provider: .codex
    )

    let withContext = library.renderedPrompt(
      template: GitHubPromptLibrary.customMessageTemplate(
        message: "  Is this safe to merge?  ", includePullRequestContext: true),
      context: context)
    #expect(
      withContext.hasPrefix(
        "Context: pull request #450 \"XFA-2129: Add production Teams Maestro test\" (https://github.com/gl-ventures/xfa-native-mobile/pull/450) in gl-ventures/xfa-native-mobile."
      ))
    #expect(withContext.contains("\n\nIs this safe to merge?"))

    let bare = library.renderedPrompt(
      template: GitHubPromptLibrary.customMessageTemplate(
        message: "Is this safe to merge?", includePullRequestContext: false),
      context: context)
    #expect(bare.hasPrefix("Is this safe to merge?"))
    #expect(!bare.contains("Context: pull request"))
  }

  @Test("Bulk review skips your own pull requests, and everything while your login is unknown")
  func bulkReviewSkipsOwnPullRequests() async {
    let service = GitHubProjectReviewServiceStub()
    service.projects = [makeProject()]
    service.login = "PHXLLE"
    let viewModel = GitHubReviewsViewModel(service: service, userDefaults: isolatedDefaults())
    let mine = makePullRequest(id: "mine", isDraft: false, author: "phxlle")
    let theirs = makePullRequest(id: "theirs", isDraft: false, author: "lvlrt")
    let unknownAuthor = makePullRequest(id: "ghost", isDraft: false, author: nil)

    #expect(viewModel.bulkReviewCandidates([mine, theirs]).isEmpty)

    await viewModel.load()
    #expect(viewModel.bulkReviewCandidates([mine, theirs, unknownAuthor]).map(\.id) == ["theirs", "ghost"])
  }

  @Test("Follow-ups: re-review targets others' PRs, resolve targets yours, both need a ready session")
  func followUpTargets() async {
    let service = GitHubProjectReviewServiceStub()
    service.projects = [makeProject()]
    service.login = "phxlle"
    let viewModel = GitHubReviewsViewModel(service: service, userDefaults: isolatedDefaults())
    func link(_ id: String, pending: Bool = false) -> GitHubReviewSessionLink {
      GitHubReviewSessionLink(
        provider: .codex, session: makeSession(id: id, date: .now, message: nil),
        itemID: "codex-\(id)", isPending: pending, displayName: id, status: nil)
    }
    let rows = [
      GitHubReviewTableRow(pullRequest: makePullRequest(id: "theirs", isDraft: false, author: "lvlrt"), sessionLinks: [link("r1")]),
      GitHubReviewTableRow(pullRequest: makePullRequest(id: "mine", isDraft: false, author: "phxlle"), sessionLinks: [link("i1")]),
      GitHubReviewTableRow(pullRequest: makePullRequest(id: "mine-no-session", isDraft: false, author: "phxlle"), sessionLinks: []),
      GitHubReviewTableRow(pullRequest: makePullRequest(id: "theirs-starting", isDraft: false, author: "x"), sessionLinks: [link("p1", pending: true)]),
    ]

    #expect(viewModel.followUpTargets(rows, kind: .reReview).isEmpty)  // login unknown yet

    await viewModel.load()
    #expect(viewModel.followUpTargets(rows, kind: .reReview).map(\.pullRequest.id) == ["theirs"])
    #expect(viewModel.followUpTargets(rows, kind: .resolveComments).map(\.pullRequest.id) == ["mine"])
    #expect(viewModel.followUpTargets(rows, kind: .resolveComments).first?.link.session.id == "i1")
  }

  @Test("Resolve-comments prompt targets the PR and spares the GitHub API")
  func resolvePrompt() {
    let prompt = GitHubReviewFollowUpPromptBuilder.resolveRequestedChanges(
      makePullRequest(id: "mine", isDraft: false))
    #expect(prompt.contains("Reviewers requested changes"))
    #expect(prompt.contains("https://github.com/gl-ventures/xfa-native-mobile/pull/450"))
    #expect(prompt.contains("GitHub API budget"))
  }

  @Test("Bulk launch targets only pull requests without a linked session")
  func bulkLaunchTargets() {
    let linked = GitHubReviewTableRow(
      pullRequest: makePullRequest(id: "linked", isDraft: false),
      sessionLinks: [
        GitHubReviewSessionLink(
          provider: .codex,
          session: makeSession(id: "s1", date: .now, message: nil),
          itemID: "codex-s1",
          isPending: false,
          displayName: "Review",
          status: nil
        )
      ]
    )
    let open = GitHubReviewTableRow(
      pullRequest: makePullRequest(id: "open", isDraft: false), sessionLinks: [])

    #expect(GitHubReviewTableRow.withoutSessions([linked, open]).map(\.id) == ["open"])
  }

  @Test("A GitHub rate limit is reported as such, with the reset time")
  func reportsRateLimitWithResetTime() async {
    let service = GitHubProjectReviewServiceStub()
    service.projectsError = .commandFailed("GraphQL: API rate limit already exceeded for user ID 16558334.")
    let resetAt = Date(timeIntervalSinceNow: 25 * 60)
    service.rateLimitReset = resetAt
    let viewModel = GitHubReviewsViewModel(service: service, userDefaults: isolatedDefaults())

    await viewModel.load()

    #expect(viewModel.recoveryIssue?.kind == .rateLimited)
    #expect(viewModel.recoveryIssue?.title == "GitHub API rate limit reached")
    #expect(viewModel.recoveryIssue?.primaryAction == .retry)
    for _ in 0..<50 where viewModel.recoveryIssue?.message.contains("resets at") != true {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let expectedTime = resetAt.formatted(date: .omitted, time: .shortened)
    #expect(viewModel.recoveryIssue?.message.contains("resets at \(expectedTime)") == true)
  }

  @Test("Rate limits are not mistaken for login problems")
  func rateLimitIsNotAuthentication() {
    let issue = GitHubReviewRecoveryIssue.classify(
      GitHubCLIError.commandFailed("API rate limit exceeded for user. Requires authentication? no"))
    #expect(issue.kind == .rateLimited)
    #expect(
      GitHubReviewRecoveryIssue.classify(GitHubCLIError.commandFailed("Bad credentials")).kind
        == .authenticationRequired)
  }

  @Test("Every rendered review prompt asks agents to spare the GitHub API")
  @MainActor
  func promptsCarryGitHubBudgetGuidance() {
    let library = GitHubPromptLibrary(userDefaults: isolatedDefaults())
    let context = GitHubPromptContext(
      pullRequest: makePullRequest(id: "ready", isDraft: false),
      project: makeProject(),
      view: makeProject().views[0],
      provider: .codex
    )
    for template in library.templates {
      #expect(library.renderedPrompt(template: template, context: context).contains("GitHub API budget"))
    }
  }

  @Test("Offers a scoped GitHub reconnect when Projects permission is missing")
  func recoversMissingProjectScope() async {
    let service = GitHubProjectReviewServiceStub()
    service.projectsError = .commandFailed(
      "Your token has not been granted the required scopes. The 'id' field requires: ['read:project'], but your token only has: ['gist', 'read:org', 'repo']."
    )
    let viewModel = GitHubReviewsViewModel(
      service: service,
      userDefaults: isolatedDefaults()
    )

    await viewModel.load()

    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.recoveryIssue?.kind == .projectPermissionRequired)
    #expect(viewModel.recoveryIssue?.primaryAction == .reconnectWithProjectAccess)
    #expect(viewModel.recoveryIssue?.secondaryAction == .retry)
    #expect(viewModel.recoveryIssue?.message.contains("read:project") == true)
  }

  @Test("Offers a new GitHub login when authentication expired")
  func recoversExpiredAuthentication() async {
    let service = GitHubProjectReviewServiceStub()
    service.projectsError = .notAuthenticated
    let viewModel = GitHubReviewsViewModel(
      service: service,
      userDefaults: isolatedDefaults()
    )

    await viewModel.load()

    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.recoveryIssue?.kind == .authenticationRequired)
    #expect(viewModel.recoveryIssue?.primaryAction == .signIn)
    #expect(viewModel.recoveryIssue?.secondaryAction == .retry)
  }

  @Test("Clears the recovery state after GitHub reconnects")
  func clearsRecoveryAfterRetry() async {
    let service = GitHubProjectReviewServiceStub()
    service.projectsError = .notAuthenticated
    let project = makeProject()
    service.projects = [project]
    service.pullRequests = [makePullRequest(id: "ready", isDraft: false)]
    let viewModel = GitHubReviewsViewModel(
      service: service,
      userDefaults: isolatedDefaults()
    )

    await viewModel.load()
    #expect(viewModel.recoveryIssue != nil)

    service.projectsError = nil
    await viewModel.reloadProjects()

    #expect(viewModel.recoveryIssue == nil)
    #expect(viewModel.selectedProjectID == project.id)
    #expect(viewModel.pullRequests.map(\.id) == ["ready"])
  }

  @Test("A stuck refresh can be cancelled without restarting the app")
  func cancelsRefreshImmediately() async {
    let service = GitHubProjectReviewServiceStub()
    service.projectsDelay = .seconds(30)
    let viewModel = GitHubReviewsViewModel(
      service: service,
      userDefaults: isolatedDefaults()
    )

    let refresh = Task { await viewModel.reloadProjects() }
    while !viewModel.isRefreshing {
      await Task.yield()
    }

    viewModel.cancelRefresh()
    refresh.cancel()
    await refresh.value

    #expect(!viewModel.isRefreshing)
    #expect(viewModel.recoveryIssue == nil)
  }

  @Test("Cached review queue is available before GitHub refresh finishes")
  func restoresCachedReviewQueueImmediately() async {
    let defaults = isolatedDefaults()
    let project = makeProject()
    let cachedPullRequest = makePullRequest(id: "cached", isDraft: false)
    let firstService = GitHubProjectReviewServiceStub()
    firstService.projects = [project]
    firstService.pullRequests = [cachedPullRequest]
    let first = GitHubReviewsViewModel(service: firstService, userDefaults: defaults)
    await first.load()

    let slowService = GitHubProjectReviewServiceStub()
    slowService.projects = [project]
    slowService.pullRequests = [makePullRequest(id: "fresh", isDraft: false)]
    slowService.projectsDelay = .seconds(30)
    let restored = GitHubReviewsViewModel(service: slowService, userDefaults: defaults)

    #expect(restored.projects == [project])
    #expect(restored.pullRequests.map(\.id) == ["cached"])
    #expect(restored.isShowingCachedPullRequests)
    #expect(restored.cachedPullRequestsUpdatedAt != nil)
  }

  @Test("A failed GitHub refresh keeps the searchable cached queue")
  func failedRefreshKeepsCachedReviewQueue() async {
    let defaults = isolatedDefaults()
    let project = makeProject()
    let cachedPullRequest = makePullRequest(id: "cached", isDraft: false)
    let firstService = GitHubProjectReviewServiceStub()
    firstService.projects = [project]
    firstService.pullRequests = [cachedPullRequest]
    let first = GitHubReviewsViewModel(service: firstService, userDefaults: defaults)
    await first.load()

    let failingService = GitHubProjectReviewServiceStub()
    failingService.projectsError = .notAuthenticated
    let restored = GitHubReviewsViewModel(service: failingService, userDefaults: defaults)
    await restored.load()

    #expect(restored.pullRequests.map(\.id) == ["cached"])
    #expect(restored.isShowingCachedPullRequests)
    #expect(restored.recoveryIssue?.kind == .authenticationRequired)
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

  @Test("Pull and review again refreshes the existing session context")
  func pullAndReviewAgainPrompt() {
    let pullRequest = makePullRequest(id: "ready", isDraft: false)

    let prompt = GitHubReviewFollowUpPromptBuilder.pullAndReviewAgain(pullRequest)

    #expect(prompt.contains(pullRequest.url))
    #expect(prompt.contains(pullRequest.repositoryNameWithOwner))
    #expect(prompt.contains("latest remote head"))
    #expect(prompt.contains("previous finding"))
    #expect(prompt.contains("Do not edit implementation files"))
  }

  @Test("Custom review commands retain exact user intent and pull request context")
  func customReviewFollowUpPrompt() {
    let pullRequest = makePullRequest(id: "ready", isDraft: false)

    let prompt = GitHubReviewFollowUpPromptBuilder.custom(
      "  Pull the latest changes and review the CI fix.  ",
      pullRequest: pullRequest
    )

    #expect(prompt?.contains(pullRequest.url) == true)
    #expect(prompt?.contains("Pull the latest changes and review the CI fix.") == true)
    #expect(prompt?.contains("latest remote pull request state") == true)
    #expect(GitHubReviewFollowUpPromptBuilder.custom("   ", pullRequest: pullRequest) == nil)
  }

  @Test("Follow-up commands can resume every resolved session")
  func reviewSessionCommandPolicy() {
    #expect(GitHubReviewSessionCommandPolicy.canSend(isPending: false))
    #expect(!GitHubReviewSessionCommandPolicy.canSend(isPending: true))
  }

  @Test("Suggested review order understands common project priorities")
  func ranksReviewPriorities() {
    #expect(GitHubReviewRecommendation.priorityRank("Urgent ‼️") == 0)
    #expect(GitHubReviewRecommendation.priorityRank("P1 High") == 1)
    #expect(GitHubReviewRecommendation.priorityRank("Medium") == 2)
    #expect(GitHubReviewRecommendation.priorityRank("Low") == 3)
    #expect(GitHubReviewRecommendation.priorityRank("Custom") == 4)
    #expect(GitHubReviewRecommendation.priorityRank(nil) == 5)
  }

  @Test("Prompt library starts with review, CI, and comment workflows")
  func promptLibraryProvidesBuiltIns() {
    let library = GitHubPromptLibrary(userDefaults: isolatedDefaults())

    let expectedNames = [
      "Independent review",
      "Fix CI issues",
      "Resolve review comments",
    ]
    #expect(library.templates.map(\.name) == expectedNames)
    #expect(library.templates[1].prompt.contains("gh pr checks"))
    #expect(library.templates[2].prompt.contains("unresolved threads"))
    #expect(library.sharedInstructions.contains("Obsidian"))
  }

  @Test("Custom prompts and shared instructions persist")
  func promptLibraryPersistsEdits() {
    let defaults = isolatedDefaults()
    let library = GitHubPromptLibrary(userDefaults: defaults)
    let custom = library.addCustomTemplate()
    let customIndex = library.templates.firstIndex { $0.id == custom.id }!
    library.templates[customIndex].name = "Investigate performance"
    library.templates[customIndex].prompt = "Inspect {{pull_request_url}} with {{provider}}."
    library.sharedInstructions = "Update my Obsidian log before and after the task."

    let restored = GitHubPromptLibrary(userDefaults: defaults)

    #expect(restored.templates.last?.name == "Investigate performance")
    #expect(restored.templates.last?.prompt.contains("{{provider}}") == true)
    #expect(restored.sharedInstructions == "Update my Obsidian log before and after the task.")
  }

  @Test("Prompt rendering fills pull request variables and appends shared instructions")
  func promptLibraryRendersContext() {
    let library = GitHubPromptLibrary(userDefaults: isolatedDefaults())
    library.sharedInstructions = "Log completion in Obsidian."
    let project = makeProject()
    let pullRequest = makePullRequest(id: "ready", isDraft: false)
    let template = GitHubPromptTemplate(
      id: "test",
      name: "Test",
      prompt: "{{provider}} handles #{{pull_request_number}} by {{author}} in {{repository}}.",
      builtInKind: nil
    )

    let prompt = library.renderedPrompt(
      template: template,
      context: GitHubPromptContext(
        pullRequest: pullRequest,
        project: project,
        view: project.views[1],
        provider: .claude
      )
    )

    #expect(prompt.contains("Claude handles #450 by @phxlle"))
    #expect(prompt.contains("gl-ventures/xfa-native-mobile"))
    #expect(prompt.hasSuffix("Log completion in Obsidian."))
    #expect(!prompt.contains("{{"))
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
      worktree: WorktreeBranch(name: pullRequest.title, path: "/tmp/xfa-native-mobile")
    )
    let launch = GitHubReviewSessionLaunch(
      pullRequestID: pullRequest.id,
      pullRequestURL: pullRequest.url,
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
    #expect(pendingLinks[0].displayName == pullRequest.title)
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

  @Test("Persists a resolved review session and restores it in a new view model")
  func persistsResolvedReviewSession() async throws {
    let service = GitHubProjectReviewServiceStub()
    service.projects = [makeProject()]
    let pullRequest = makePullRequest(id: "ready", isDraft: false)
    service.pullRequests = [pullRequest]
    let store = GitHubReviewSessionStoreStub()
    let pendingID = UUID()

    let first = GitHubReviewsViewModel(
      service: service,
      sessionStore: store,
      userDefaults: isolatedDefaults()
    )
    await first.load()
    await first.registerReviewLaunch(
      for: pullRequest,
      provider: .codex,
      pendingID: pendingID,
      projectPath: "/tmp/xfa-native-mobile"
    )
    await first.resolveReviewLaunches([pendingID: "codex-review-session"], provider: .codex)

    #expect(
      first.linkedSessionTitles(provider: .codex)
        == ["codex-review-session": pullRequest.title]
    )

    let restored = GitHubReviewsViewModel(
      service: service,
      sessionStore: store,
      userDefaults: isolatedDefaults()
    )
    await restored.load()

    #expect(
      restored.reviewSessionLaunches(for: pullRequest).first?.sessionID
        == "codex-review-session"
    )
    #expect(
      restored.linkedSessionReferences
        == [
          AgentWorkspaceSessionReference(
            provider: .codex,
            sessionId: "codex-review-session",
            projectPath: "/tmp/xfa-native-mobile"
          )
        ]
    )
  }

  @Test("Cached session PR links refresh when launches change")
  func linkedReferencesCacheInvalidates() async throws {
    let store = GitHubReviewSessionStoreStub()
    let viewModel = GitHubReviewsViewModel(
      service: GitHubProjectReviewServiceStub(), sessionStore: store, userDefaults: isolatedDefaults())
    let itemID = SidebarSessionItemID.monitored(provider: .codex, sessionId: "codex-review-session")

    #expect(viewModel.linkedPullRequestReferencesByItemID(provider: .codex).isEmpty)

    try await store.saveGitHubReviewSessionAssociation(
      GitHubReviewSessionAssociation(
        pullRequestID: "ready",
        pullRequestURL: "https://github.com/gl-ventures/xfa-native-mobile/pull/450",
        provider: .codex, pendingID: nil, sessionID: "codex-review-session",
        projectPath: "/tmp/xfa-native-mobile"))
    await viewModel.loadSessionAssociations()

    #expect(viewModel.linkedPullRequestReferencesByItemID(provider: .codex)[itemID]?.first?.number == 450)
  }

  @Test("Restores session PR context without loading the review queue")
  func restoresSessionPullRequestContextIndependently() async throws {
    let service = GitHubProjectReviewServiceStub()
    service.projects = [makeProject()]
    let store = GitHubReviewSessionStoreStub()
    try await store.saveGitHubReviewSessionAssociation(
      GitHubReviewSessionAssociation(
        pullRequestID: "ready",
        pullRequestURL: "https://github.com/gl-ventures/xfa-native-mobile/pull/450",
        provider: .codex,
        pendingID: nil,
        sessionID: "codex-review-session",
        projectPath: "/tmp/xfa-native-mobile"
      )
    )
    let viewModel = GitHubReviewsViewModel(
      service: service,
      sessionStore: store,
      userDefaults: isolatedDefaults()
    )

    await viewModel.loadSessionAssociations()

    let itemID = SidebarSessionItemID.monitored(
      provider: .codex,
      sessionId: "codex-review-session"
    )
    #expect(viewModel.projects.isEmpty)
    #expect(
      viewModel.linkedPullRequestReferencesByItemID(provider: .codex)[itemID]?.first?.number
        == 450
    )
  }

  @Test("Recovers generated review prompts once and persists their real session id")
  func recoversGeneratedReviewPrompt() async throws {
    let service = GitHubProjectReviewServiceStub()
    let project = makeProject()
    let pullRequest = makePullRequest(id: "ready", isDraft: false)
    service.projects = [project]
    service.pullRequests = [pullRequest]
    let store = GitHubReviewSessionStoreStub()
    let viewModel = GitHubReviewsViewModel(
      service: service,
      sessionStore: store,
      userDefaults: isolatedDefaults()
    )
    await viewModel.load()

    let prompt = GitHubProjectReviewPromptBuilder.prompt(
      pullRequest: pullRequest,
      project: project,
      view: project.views[1]
    )
    let result = SessionSearchResult(
      id: "legacy-review-session",
      slug: "review",
      projectPath: "/tmp/xfa-native-mobile",
      gitBranch: "main",
      firstMessage: prompt,
      summaries: [],
      lastActivityAt: Date(timeIntervalSince1970: 500),
      matchedField: .firstMessage,
      matchedText: prompt
    )

    await viewModel.recoverReviewSessions(provider: .claude, searchResults: [result])

    #expect(viewModel.reviewSessionLaunches(for: pullRequest).first?.sessionID == result.id)
    let stored = try await store.githubReviewSessionAssociations()
    #expect(stored.first?.sessionID == result.id)
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

  private func makePullRequest(id: String, isDraft: Bool, author: String?) -> GitHubProjectPullRequest {
    let base = makePullRequest(id: id, isDraft: isDraft)
    return GitHubProjectPullRequest(
      id: base.id, number: base.number, title: base.title, url: base.url,
      repositoryName: base.repositoryName, repositoryNameWithOwner: base.repositoryNameWithOwner,
      authorLogin: author, updatedAt: base.updatedAt, isDraft: base.isDraft, state: base.state,
      projectStatus: base.projectStatus, projectPriority: base.projectPriority)
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
      projectStatus: "Code Review 🔎",
      projectPriority: id == "urgent" ? "Urgent ‼️" : nil
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
