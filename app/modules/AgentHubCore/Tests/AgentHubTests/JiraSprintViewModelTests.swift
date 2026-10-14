import AgentHubGitHub
import AgentWorkflowJiraCLI
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Jira sprint view model")
struct JiraSprintViewModelTests {
  @Test("Loads the active sprint of the first board and queries it by id")
  func loadsActiveSprint() async {
    let service = MockJiraSprintService(tickets: Self.sprintTickets)
    let viewModel = JiraSprintViewModel(service: service, userDefaults: Self.makeDefaults())

    await viewModel.load()

    #expect(viewModel.state == .loaded)
    #expect(viewModel.selectedBoard?.name == "XFA board")
    #expect(viewModel.selectedSprint?.name == "Sprint 10")
    #expect(await service.searchedJQL == ["sprint = 266 ORDER BY rank"])
  }

  @Test("Columns follow Jira category order and keep rank order within a category")
  func columnOrder() async {
    let viewModel = JiraSprintViewModel(
      service: MockJiraSprintService(tickets: Self.sprintTickets), userDefaults: Self.makeDefaults())
    viewModel.assigneeFilter = .everyone

    await viewModel.load()

    #expect(viewModel.columns.map(\.status) == ["To Do", "In Progress", "In Review", "Done"])
    #expect(viewModel.columns[0].tickets.map(\.key) == ["XFA-1", "XFA-4"])
  }

  @Test("Assignee filters: me by email, a person, unassigned; columns stay put")
  func assigneeFilters() async {
    let viewModel = JiraSprintViewModel(
      service: MockJiraSprintService(tickets: Self.sprintTickets), userDefaults: Self.makeDefaults())
    await viewModel.load()

    #expect(viewModel.assigneeFilter == .me)
    #expect(viewModel.filteredTickets.map(\.key) == ["XFA-1", "XFA-3"])
    #expect(viewModel.columns.count == 4)
    #expect(viewModel.assignees.map(\.name) == ["Philippe", "Gijs"])

    viewModel.assigneeFilter = .person(accountId: "gijs")
    #expect(viewModel.filteredTickets.map(\.key) == ["XFA-2"])

    viewModel.assigneeFilter = .unassigned
    #expect(viewModel.filteredTickets.map(\.key) == ["XFA-4", "XFA-5"])

    viewModel.searchText = "login"
    #expect(viewModel.filteredTickets.map(\.key) == ["XFA-5"])
  }

  @Test("Board, sprint, and assignee choices persist")
  func persistsChoices() async {
    let defaults = Self.makeDefaults()
    let service = MockJiraSprintService(tickets: Self.sprintTickets)
    let viewModel = JiraSprintViewModel(service: service, userDefaults: defaults)
    await viewModel.load()

    await viewModel.selectSprint(267)
    viewModel.assigneeFilter = .person(accountId: "gijs")
    viewModel.repositoryPath = "/tmp/repo"

    #expect(await service.searchedJQL.last == "sprint = 267 ORDER BY rank")
    let restored = JiraSprintViewModel(service: service, userDefaults: defaults)
    await restored.load()
    #expect(restored.selectedSprintID == 267)
    #expect(restored.assigneeFilter == .person(accountId: "gijs"))
    #expect(restored.repositoryPath == "/tmp/repo")
  }

  @Test("Opening a ticket loads its full detail")
  func opensTicketDetail() async {
    let detailed = JiraTicketSnapshot(key: "XFA-2", summary: "Busy", description: "Full text")
    let viewModel = JiraSprintViewModel(
      service: MockJiraSprintService(tickets: Self.sprintTickets, detailed: detailed),
      userDefaults: Self.makeDefaults())
    await viewModel.load()

    viewModel.openTicket("XFA-2")
    #expect(viewModel.selectedTicket?.key == "XFA-2")
    for _ in 0..<50 where viewModel.isLoadingDetail {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(viewModel.selectedTicket?.description == "Full text")
    #expect(
      viewModel.browseURL(for: detailed)?.absoluteString == "https://xfatech.atlassian.net/browse/XFA-2")

    viewModel.closeTicket()
    #expect(viewModel.selectedTicket == nil)
  }

  @Test("Arrow keys walk the visible board")
  func keyboardNavigation() async {
    let viewModel = JiraSprintViewModel(
      service: MockJiraSprintService(tickets: Self.sprintTickets), userDefaults: Self.makeDefaults())
    viewModel.assigneeFilter = .everyone
    await viewModel.load()

    viewModel.moveSelection(.down)
    #expect(viewModel.selectedTicketKey == "XFA-1")
    viewModel.moveSelection(.down)
    #expect(viewModel.selectedTicketKey == "XFA-4")
    viewModel.moveSelection(.right)
    #expect(viewModel.selectedTicketKey == "XFA-2")
    viewModel.moveSelection(.right)
    #expect(viewModel.selectedTicketKey == "XFA-5")
    viewModel.moveSelection(.right)
    viewModel.moveSelection(.right)
    #expect(viewModel.selectedTicketKey == "XFA-3")
    viewModel.moveSelection(.up)
    #expect(viewModel.selectedTicketKey == "XFA-3")
  }

  @Test("Picking up a To do ticket moves it to the board's in-progress status")
  func pickUpMovesToInProgress() async {
    let service = MockJiraSprintService(tickets: Self.sprintTickets)
    let viewModel = JiraSprintViewModel(service: service, userDefaults: Self.makeDefaults())
    viewModel.assigneeFilter = .everyone
    await viewModel.load()

    await viewModel.markInProgressIfNeeded("XFA-1")
    await viewModel.markInProgressIfNeeded("XFA-2")  // already in progress: untouched

    #expect(await service.transitions == ["XFA-1->In Progress"])
    #expect(viewModel.sprintTickets.first { $0.key == "XFA-1" }?.status == "In Progress")
    #expect(viewModel.statusNotice?.isError == false)
  }

  @Test("Dragging moves a ticket; a refused transition moves it back and keeps the column")
  func dragMovesAndRollsBack() async {
    let service = MockJiraSprintService(tickets: Self.sprintTickets)
    let viewModel = JiraSprintViewModel(service: service, userDefaults: Self.makeDefaults())
    viewModel.assigneeFilter = .everyone
    await viewModel.load()

    await viewModel.moveTicket("XFA-5", toStatus: "Done", category: "done")
    #expect(viewModel.columns.first { $0.status == "Done" }?.tickets.map(\.key) == ["XFA-3", "XFA-5"])
    // The emptied "In Review" column stays as a drop target.
    #expect(viewModel.columns.map(\.status).contains("In Review"))

    await service.failTransitions(JiraTicketReaderError.commandFailed(exitCode: 1, message: "not allowed"))
    await viewModel.moveTicket("XFA-1", toStatus: "Done", category: "done")
    #expect(viewModel.sprintTickets.first { $0.key == "XFA-1" }?.status == "To Do")
    #expect(viewModel.statusNotice?.isError == true)
    #expect(viewModel.statusNotice?.text.contains("not allowed") == true)
  }

  @Test("Opening a ticket searches its pull requests once, scoped to the owner")
  func ticketPullRequests() async {
    let search = PullRequestSearchStub()
    let viewModel = JiraSprintViewModel(
      service: MockJiraSprintService(tickets: Self.sprintTickets),
      pullRequestSearch: search,
      gitHubOwner: { _ in "gl-ventures" },
      userDefaults: Self.makeDefaults())
    await viewModel.load()

    viewModel.openTicket("XFA-1")
    for _ in 0..<50 where viewModel.pullRequestsByTicket["XFA-1"] == nil {
      try? await Task.sleep(for: .milliseconds(10))
    }
    viewModel.openTicket("XFA-1")

    #expect(viewModel.pullRequestsByTicket["XFA-1"]?.map(\.number) == [42])
    #expect(await search.queries == ["XFA-1@gl-ventures"])
  }

  @Test("Sync plans moves from PRs and open sessions, then applies them")
  func syncPlansAndApplies() async {
    let service = MockJiraSprintService(tickets: Self.sprintTickets)
    let search = PullRequestSearchStub()
    await search.setTicketPullRequests([
      "XFA-1": [.init(pullRequest: PullRequestSearchStub.pullRequest("XFA-1", state: "merged"), isApproved: true)],
      "XFA-2": [.init(pullRequest: PullRequestSearchStub.pullRequest("XFA-2", state: "open"), isApproved: true)],
    ])
    let viewModel = JiraSprintViewModel(
      service: service, pullRequestSearch: search, userDefaults: Self.makeDefaults())
    viewModel.assigneeFilter = .everyone
    await viewModel.load()

    await viewModel.planSync(openSessionKeys: ["XFA-4"])

    let plan = viewModel.syncPlan ?? []
    #expect(plan.map { "\($0.key)->\($0.toStatus)" } == ["XFA-1->Done", "XFA-4->In Progress"])
    // XFA-2 would go to UX review, but this workflow has no such status: reported, not moved.
    #expect(viewModel.syncSkipped.contains { $0.hasPrefix("XFA-2") })
    #expect(await service.transitions.isEmpty)

    await viewModel.applySync()
    #expect(await service.transitions == ["XFA-1->Done", "XFA-4->In Progress"])
    #expect(viewModel.syncPlan == nil)
    #expect(viewModel.sprintTickets.first { $0.key == "XFA-1" }?.status == "Done")
  }

  @Test("Sessions started from the board get the ticket as their name")
  func sessionNames() {
    let viewModel = JiraSprintViewModel(service: MockJiraSprintService(), userDefaults: Self.makeDefaults())
    let pendingID = UUID()
    viewModel.registerPendingSession(
      pendingID, for: JiraTicketSnapshot(key: "XFA-7", summary: "Fix the login screen"))

    #expect(viewModel.takeSessionNames(resolved: [UUID(): "other"]).isEmpty)
    let names = viewModel.takeSessionNames(resolved: [pendingID: "session-1"])
    #expect(names.map(\.sessionID) == ["session-1"])
    #expect(names.map(\.name) == ["XFA-7: Fix the login screen"])
    #expect(viewModel.takeSessionNames(resolved: [pendingID: "session-1"]).isEmpty)
  }

  @Test("Surfaces the acli error message")
  func failure() async {
    let service = MockJiraSprintService(
      error: JiraTicketReaderError.commandFailed(exitCode: 1, message: "not logged in"))
    let viewModel = JiraSprintViewModel(service: service, userDefaults: Self.makeDefaults())

    await viewModel.load()

    #expect(viewModel.state == .failed("not logged in"))
  }

  @Test("Launch prompt uses the full ticket description, falling back to the snapshot")
  func launchPrompt() async {
    let detailed = JiraTicketSnapshot(
      key: "XFA-9", summary: "Fix login", issueType: "Bug", description: "Users get logged out.")
    let viewModel = JiraSprintViewModel(
      service: MockJiraSprintService(detailed: detailed), userDefaults: Self.makeDefaults())

    let prompt = await viewModel.launchPrompt(for: JiraTicketSnapshot(key: "XFA-9", summary: "Fix login"))
    #expect(prompt.hasPrefix("Pick up Jira ticket XFA-9: Fix login"))
    #expect(prompt.contains("Type: Bug"))
    #expect(prompt.contains("Users get logged out."))
    #expect(prompt.contains("xfa-9-short-description"))
    #expect(prompt.contains("GitHub API budget"))

    let fallback = await JiraSprintViewModel(
      service: MockJiraSprintService(), userDefaults: Self.makeDefaults()
    ).launchPrompt(for: JiraTicketSnapshot(key: "XFA-7", summary: "Offline"))
    #expect(fallback.hasPrefix("Pick up Jira ticket XFA-7: Offline"))
    #expect(!fallback.contains("Description:"))
  }

  private static let sprintTickets = [
    ticket("XFA-1", "Todo mine", status: "To Do", category: "new", assignee: me),
    ticket("XFA-2", "Busy", status: "In Progress", category: "indeterminate", assignee: gijs),
    ticket("XFA-3", "Done mine", status: "Done", category: "done", assignee: me),
    ticket("XFA-4", "Todo free", status: "To Do", category: "new", assignee: nil),
    ticket("XFA-5", "Review login", status: "In Review", category: "indeterminate", assignee: nil),
  ]

  private static let me = (id: "me", name: "Philippe", email: "philippe@xfa.tech")
  private static let gijs = (id: "gijs", name: "Gijs", email: "gijs@xfa.tech")

  private static func ticket(
    _ key: String,
    _ summary: String,
    status: String,
    category: String,
    assignee: (id: String, name: String, email: String)?
  ) -> JiraTicketSnapshot {
    JiraTicketSnapshot(
      key: key,
      summary: summary,
      status: status,
      assignee: assignee?.name,
      assigneeAccountId: assignee?.id,
      assigneeEmail: assignee?.email,
      statusCategory: category
    )
  }

  private static func makeDefaults() -> UserDefaults {
    let name = "JiraSprintViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }
}

private actor MockJiraSprintService: JiraTicketReading, JiraTicketSearching, JiraAuthenticating,
  JiraBoardBrowsing, JiraTicketTransitioning
{
  private(set) var transitions: [String] = []
  var transitionError: Error?

  func failTransitions(_ error: Error) { transitionError = error }

  func transition(key: String, toStatus status: String) async throws {
    transitions.append("\(key)->\(status)")
    if let transitionError { throw transitionError }
  }

  private let tickets: [JiraTicketSnapshot]
  private let error: Error?
  private let detailed: JiraTicketSnapshot?
  private(set) var searchedJQL: [String] = []

  init(tickets: [JiraTicketSnapshot] = [], error: Error? = nil, detailed: JiraTicketSnapshot? = nil) {
    self.tickets = tickets
    self.error = error
    self.detailed = detailed
  }

  func searchTickets(jql: String, limit: Int) async throws -> [JiraTicketSnapshot] {
    searchedJQL.append(jql)
    if let error { throw error }
    return tickets
  }

  func ticket(key: String) async throws -> JiraTicketSnapshot {
    guard let detailed else { throw JiraTicketReaderError.invalidResponse }
    return detailed
  }

  func authenticate() async throws {}

  func currentAccount() async throws -> JiraAccount {
    if let error { throw error }
    return JiraAccount(site: "xfatech.atlassian.net", email: "Philippe@xfa.tech")
  }

  func boards() async throws -> [JiraBoard] {
    [JiraBoard(id: 1, name: "XFA board"), JiraBoard(id: 2, name: "MKT board")]
  }

  func openSprints(boardID: Int) async throws -> [JiraSprint] {
    [
      JiraSprint(id: 266, name: "Sprint 10", state: "active"),
      JiraSprint(id: 267, name: "Sprint 11", state: "future"),
    ]
  }
}

private actor PullRequestSearchStub: GitHubProjectReviewServiceProtocol {
  private(set) var queries: [String] = []
  private var ticketPullRequests: [String: [GitHubTicketPullRequest]] = [:]

  func setTicketPullRequests(_ value: [String: [GitHubTicketPullRequest]]) { ticketPullRequests = value }

  func ticketPullRequests(forKeys keys: [String], owner: String?) async throws
    -> [String: [GitHubTicketPullRequest]]
  { ticketPullRequests.filter { keys.contains($0.key) } }

  static func pullRequest(_ key: String, state: String) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: key, number: 1, title: "\(key): x", url: "https://github.com/o/r/pull/\(key)",
      repositoryName: "r", repositoryNameWithOwner: "o/r", authorLogin: nil, updatedAt: nil,
      isDraft: false, state: state, projectStatus: nil, projectPriority: nil)
  }

  func listProjects() async throws -> [GitHubReviewProject] { [] }

  func listPullRequests(project: GitHubReviewProject, view: GitHubProjectView, limit: Int)
    async throws -> [GitHubProjectPullRequest]
  { [] }

  func searchPullRequests(mentioning text: String, owner: String?) async throws
    -> [GitHubProjectPullRequest]
  {
    queries.append("\(text)@\(owner ?? "-")")
    return [
      GitHubProjectPullRequest(
        id: "pr", number: 42, title: "\(text): fix", url: "https://github.com/o/r/pull/42",
        repositoryName: "r", repositoryNameWithOwner: "o/r", authorLogin: nil, updatedAt: nil,
        isDraft: false, state: "open", projectStatus: nil, projectPriority: nil)
    ]
  }
}
