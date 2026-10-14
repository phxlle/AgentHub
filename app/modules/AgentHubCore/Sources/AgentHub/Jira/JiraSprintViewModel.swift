//
//  JiraSprintViewModel.swift
//  AgentHub
//
//  A Jira sprint board (via the Atlassian CLI) whose tickets can be handed to an agent.
//

import AgentHubGitHub
import AgentWorkflowJiraCLI
import Foundation
import Observation

public typealias JiraSprintService = JiraTicketReading & JiraTicketSearching & JiraAuthenticating
  & JiraBoardBrowsing & JiraTicketTransitioning

@MainActor
@Observable
public final class JiraSprintViewModel {
  public enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  public enum AssigneeFilter: Hashable {
    case everyone
    case me
    case unassigned
    case person(accountId: String)

    var storageValue: String {
      switch self {
      case .everyone: return "everyone"
      case .me: return "me"
      case .unassigned: return "unassigned"
      case .person(let accountId): return "person:\(accountId)"
      }
    }

    init(storageValue: String?) {
      switch storageValue {
      case "everyone": self = .everyone
      case "unassigned": self = .unassigned
      case let value? where value.hasPrefix("person:"):
        self = .person(accountId: String(value.dropFirst("person:".count)))
      default: self = .me
      }
    }
  }

  public struct Assignee: Identifiable, Equatable {
    public let accountId: String
    public let name: String
    public let email: String?
    public let avatarURL: URL?
    public let ticketCount: Int
    public var id: String { accountId }
  }

  public struct BoardColumn: Identifiable, Equatable {
    public let status: String
    /// Jira status category key: `new`, `indeterminate`, `done`, or nil when unknown.
    public let category: String?
    public let tickets: [JiraTicketSnapshot]
    public var id: String { status }
  }

  // MARK: - State

  public private(set) var state: LoadState = .idle
  public private(set) var isConnecting = false
  public private(set) var account: JiraAccount?
  public private(set) var boards: [JiraBoard] = []
  public private(set) var sprints: [JiraSprint] = []
  /// Every ticket of the selected sprint, in rank order. Filters apply on top.
  public private(set) var sprintTickets: [JiraTicketSnapshot] = []
  public private(set) var selectedBoardID: Int?
  public private(set) var selectedSprintID: Int?
  public private(set) var selectedTicketKey: String?
  /// Full ticket (with description) for the open detail panel.
  public private(set) var ticketDetail: JiraTicketSnapshot?
  public private(set) var isLoadingDetail = false
  /// Pull requests mentioning each ticket key, fetched when a ticket is opened.
  public private(set) var pullRequestsByTicket: [String: [GitHubProjectPullRequest]] = [:]
  public private(set) var loadingPullRequestKeys: Set<String> = []
  /// Result of the last pick-up's move to In Progress, shown in the detail panel.
  public private(set) var statusNotice: StatusNotice?
  private var loadedStatuses: [(name: String, category: String?)] = []

  // MARK: Sync

  public struct SyncChange: Identifiable, Equatable {
    public let key: String
    public let summary: String
    public let fromStatus: String
    public let toStatus: String
    public let toCategory: String?
    public let reason: String
    public var id: String { key }
  }

  /// Planned moves awaiting the user's Apply; nil when no plan is shown.
  public private(set) var syncPlan: [SyncChange]?
  public private(set) var isPlanningSync = false
  public private(set) var isApplyingSync = false
  /// Tickets the plan skipped, e.g. no "UX Review" status in this workflow.
  public private(set) var syncSkipped: [String] = []

  /// Names for sessions started from the board, applied once the pending session
  /// resolves to a real one (keyed by pending id).
  @ObservationIgnored private var pendingSessionNames: [UUID: String] = [:]

  static func sessionName(for ticket: JiraTicketSnapshot) -> String {
    let summary = ticket.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let shortened = summary.count > 70 ? String(summary.prefix(69)) + "…" : summary
    return "\(ticket.key): \(shortened)"
  }

  public func registerPendingSession(_ pendingID: UUID, for ticket: JiraTicketSnapshot) {
    pendingSessionNames[pendingID] = Self.sessionName(for: ticket)
  }

  /// Session names to apply for pending sessions that just resolved.
  public func takeSessionNames(resolved: [UUID: String]) -> [(sessionID: String, name: String)] {
    var names: [(sessionID: String, name: String)] = []
    for (pendingID, sessionID) in resolved {
      if let name = pendingSessionNames.removeValue(forKey: pendingID) {
        names.append((sessionID, name))
      }
    }
    return names
  }

  public struct StatusNotice: Equatable {
    public let ticketKey: String
    public let text: String
    public let isError: Bool
  }

  public var searchText = ""

  public var assigneeFilter: AssigneeFilter {
    didSet {
      userDefaults.set(assigneeFilter.storageValue, forKey: AgentHubDefaults.jiraSprintAssigneeFilter)
    }
  }

  /// Local repository path new ticket sessions start in.
  public var repositoryPath: String? {
    didSet { userDefaults.set(repositoryPath, forKey: AgentHubDefaults.jiraSprintRepositoryPath) }
  }

  @ObservationIgnored private let service: any JiraSprintService
  @ObservationIgnored private let pullRequestSearch: (any GitHubProjectReviewServiceProtocol)?
  /// GitHub owner to scope the PR search to (the review project's org), if known.
  @ObservationIgnored private let gitHubOwner: @MainActor (_ repositoryPath: String?) -> String?
  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private var detailTask: Task<Void, Never>?
  @ObservationIgnored let sessionLinker = JiraSessionLinker()

  public init(
    service: any JiraSprintService = ACLITicketReader(),
    pullRequestSearch: (any GitHubProjectReviewServiceProtocol)? = nil,
    gitHubOwner: @escaping @MainActor (_ repositoryPath: String?) -> String? = { _ in nil },
    userDefaults: UserDefaults = .standard
  ) {
    self.service = service
    self.pullRequestSearch = pullRequestSearch
    self.gitHubOwner = gitHubOwner
    self.userDefaults = userDefaults
    assigneeFilter = AssigneeFilter(
      storageValue: userDefaults.string(forKey: AgentHubDefaults.jiraSprintAssigneeFilter))
    repositoryPath = userDefaults.string(forKey: AgentHubDefaults.jiraSprintRepositoryPath)
    let boardID = userDefaults.integer(forKey: AgentHubDefaults.jiraSprintBoardID)
    selectedBoardID = boardID == 0 ? nil : boardID
    let sprintID = userDefaults.integer(forKey: AgentHubDefaults.jiraSprintSprintID)
    selectedSprintID = sprintID == 0 ? nil : sprintID
  }

  // MARK: - Derived

  public var selectedBoard: JiraBoard? { boards.first { $0.id == selectedBoardID } }
  public var selectedSprint: JiraSprint? { sprints.first { $0.id == selectedSprintID } }

  public var selectedTicket: JiraTicketSnapshot? {
    if let ticketDetail, ticketDetail.key == selectedTicketKey { return ticketDetail }
    return sprintTickets.first { $0.key == selectedTicketKey }
  }

  public var filteredTickets: [JiraTicketSnapshot] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return sprintTickets.filter { ticket in
      matchesAssignee(ticket)
        && (query.isEmpty
          || ticket.key.localizedCaseInsensitiveContains(query)
          || ticket.summary.localizedCaseInsensitiveContains(query))
    }
  }

  /// One column per status in the sprint, ordered To do → In progress → Done like a Jira board.
  /// Columns come from the whole sprint so they stay put while filtering.
  public var columns: [BoardColumn] {
    let categoryOrder = ["new", "indeterminate", "done"]
    // Statuses seen when the sprint loaded stay as columns, so dragging the last
    // ticket out of a column doesn't make it (and its drop target) disappear.
    var statuses: [(name: String, category: String?)] = loadedStatuses
    for ticket in sprintTickets {
      let name = ticket.status ?? "No status"
      if !statuses.contains(where: { $0.name == name }) {
        statuses.append((name, ticket.statusCategory))
      }
    }
    let ordered = statuses.enumerated().sorted { lhs, rhs in
      let left = categoryOrder.firstIndex(of: lhs.element.category ?? "") ?? categoryOrder.count
      let right = categoryOrder.firstIndex(of: rhs.element.category ?? "") ?? categoryOrder.count
      return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)

    let visible = filteredTickets
    return ordered.map { status in
      BoardColumn(
        status: status.name,
        category: status.category,
        tickets: visible.filter { ($0.status ?? "No status") == status.name }
      )
    }
  }

  public var assignees: [Assignee] {
    var byID: [String: Assignee] = [:]
    for ticket in sprintTickets {
      guard let id = ticket.assigneeAccountId, let name = ticket.assignee else { continue }
      let count = (byID[id]?.ticketCount ?? 0) + 1
      byID[id] = Assignee(
        accountId: id,
        name: name,
        email: ticket.assigneeEmail,
        avatarURL: ticket.assigneeAvatarURL.flatMap(URL.init(string:)),
        ticketCount: count
      )
    }
    return byID.values.sorted { lhs, rhs in
      if isMe(lhs) != isMe(rhs) { return isMe(lhs) }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  /// Jira project keys (e.g. `XFA`) seen on the boards and in the sprint. Used to
  /// accept ticket keys found in branch names without matching `release-2`.
  public var knownProjectKeys: Set<String> {
    var keys = Set(sprintTickets.compactMap { $0.key.split(separator: "-").first.map(String.init) })
    for board in boards {
      // Board locations look like "Product (Current tasks) (XFA)".
      guard let location = board.location, location.hasSuffix(")"),
        let open = location.lastIndex(of: "(")
      else { continue }
      keys.insert(String(location[location.index(after: open)..<location.index(before: location.endIndex)]))
    }
    return keys
  }

  /// Your tickets not done yet: the Sprint tab's badge. Cheap, no sorting.
  public var myOpenTicketCount: Int {
    guard let email = account?.email else { return 0 }
    return sprintTickets.filter {
      $0.statusCategory != "done"
        && $0.assigneeEmail?.caseInsensitiveCompare(email) == .orderedSame
    }.count
  }

  public var unassignedCount: Int {
    sprintTickets.filter { $0.assigneeAccountId == nil }.count
  }

  public func isMe(_ assignee: Assignee) -> Bool {
    guard let email = account?.email, let assigneeEmail = assignee.email else { return false }
    return email.caseInsensitiveCompare(assigneeEmail) == .orderedSame
  }

  public func browseURL(for ticket: JiraTicketSnapshot) -> URL? {
    account?.browseURL(forKey: ticket.key)
  }

  private func matchesAssignee(_ ticket: JiraTicketSnapshot) -> Bool {
    switch assigneeFilter {
    case .everyone:
      return true
    case .unassigned:
      return ticket.assigneeAccountId == nil
    case .person(let accountId):
      return ticket.assigneeAccountId == accountId
    case .me:
      guard let email = account?.email, let ticketEmail = ticket.assigneeEmail else { return false }
      return email.caseInsensitiveCompare(ticketEmail) == .orderedSame
    }
  }

  // MARK: - Loading

  /// Loads account, boards, the sprints of the selected board, and the selected sprint's tickets.
  public func load() async {
    state = .loading
    do {
      if account == nil { account = try await service.currentAccount() }
      if boards.isEmpty { boards = try await service.boards() }
      if selectedBoard == nil { selectedBoardID = boards.first?.id }
      try await loadSprintsAndTickets()
      state = .loaded
    } catch {
      state = .failed(Self.message(for: error))
    }
  }

  /// Loads once in the background, e.g. so sessions can show their ticket chip.
  public func loadIfNeeded() async {
    if state == .idle { await load() }
  }

  public func selectBoard(_ boardID: Int) async {
    guard boardID != selectedBoardID else { return }
    selectedBoardID = boardID
    selectedSprintID = nil
    userDefaults.set(boardID, forKey: AgentHubDefaults.jiraSprintBoardID)
    await reloadSprint()
  }

  public func selectSprint(_ sprintID: Int) async {
    guard sprintID != selectedSprintID else { return }
    selectedSprintID = sprintID
    userDefaults.set(sprintID, forKey: AgentHubDefaults.jiraSprintSprintID)
    await reloadSprint()
  }

  private func reloadSprint() async {
    state = .loading
    closeTicket()
    do {
      try await loadSprintsAndTickets()
      state = .loaded
    } catch {
      state = .failed(Self.message(for: error))
    }
  }

  private func loadSprintsAndTickets() async throws {
    guard let boardID = selectedBoardID else {
      sprints = []
      sprintTickets = []
      loadedStatuses = []
      return
    }
    // Boards without sprint support (kanban/simple) error here; treat as "no sprints".
    sprints = (try? await service.openSprints(boardID: boardID)) ?? []
    if selectedSprint == nil {
      selectedSprintID = (sprints.first(where: \.isActive) ?? sprints.first)?.id
    }
    guard let sprintID = selectedSprintID else {
      sprintTickets = []
      loadedStatuses = []
      return
    }
    sprintTickets = try await service.searchTickets(jql: "sprint = \(sprintID) ORDER BY rank", limit: 300)
    var statuses: [(name: String, category: String?)] = []
    for ticket in sprintTickets where !statuses.contains(where: { $0.name == (ticket.status ?? "No status") }) {
      statuses.append((ticket.status ?? "No status", ticket.statusCategory))
    }
    loadedStatuses = statuses
  }

  /// Runs the Atlassian CLI browser login, then reloads.
  public func connect() async {
    isConnecting = true
    defer { isConnecting = false }
    do {
      try await service.authenticate()
      account = nil
      boards = []
      await load()
    } catch {
      state = .failed(Self.message(for: error))
    }
  }

  // MARK: - Ticket detail

  public func openTicket(_ key: String) {
    loadPullRequestsIfNeeded(for: key)
    selectedTicketKey = key
    ticketDetail = nil
    isLoadingDetail = true
    detailTask?.cancel()
    detailTask = Task { [service] in
      let detail = try? await service.ticket(key: key)
      guard !Task.isCancelled, self.selectedTicketKey == key else { return }
      self.ticketDetail = detail
      self.isLoadingDetail = false
    }
  }

  public enum MoveDirection { case up, down, left, right }

  /// Keyboard navigation over the visible board: up/down within a column,
  /// left/right to the nearest non-empty column at the same row.
  public func moveSelection(_ direction: MoveDirection) {
    let columns = self.columns.map(\.tickets).filter { !$0.isEmpty }
    guard !columns.isEmpty else { return }
    guard
      let key = selectedTicketKey,
      let column = columns.firstIndex(where: { $0.contains { $0.key == key } }),
      let row = columns[column].firstIndex(where: { $0.key == key })
    else {
      openTicket(columns[0][0].key)
      return
    }
    var target = (column: column, row: row)
    switch direction {
    case .up: target.row = max(row - 1, 0)
    case .down: target.row = min(row + 1, columns[column].count - 1)
    case .left: target.column = max(column - 1, 0)
    case .right: target.column = min(column + 1, columns.count - 1)
    }
    target.row = min(target.row, columns[target.column].count - 1)
    let next = columns[target.column][target.row].key
    if next != key { openTicket(next) }
  }

  // MARK: - Pull requests

  /// Searches once per ticket per run: GitHub's search quota is 30 requests a minute.
  public func loadPullRequestsIfNeeded(for key: String, force: Bool = false) {
    guard let pullRequestSearch, !loadingPullRequestKeys.contains(key),
      force || pullRequestsByTicket[key] == nil
    else { return }
    loadingPullRequestKeys.insert(key)
    let owner = gitHubOwner(repositoryPath)
    Task {
      let found = (try? await pullRequestSearch.searchPullRequests(mentioning: key, owner: owner)) ?? []
      self.pullRequestsByTicket[key] = found
      self.loadingPullRequestKeys.remove(key)
    }
  }

  // MARK: - Status

  /// The board's "in progress" status: the first column in Jira's in-progress category.
  var inProgressStatusName: String {
    columns.first(where: { $0.category == "indeterminate" })?.status ?? "In Progress"
  }

  /// Moves a To do ticket to In Progress when an agent picks it up. Tickets already
  /// in progress, in review, or done are left alone.
  public func markInProgressIfNeeded(_ key: String) async {
    let ticket = sprintTickets.first { $0.key == key } ?? (ticketDetail?.key == key ? ticketDetail : nil)
    guard let ticket, ticket.statusCategory == "new" else { return }
    await moveTicket(key, toStatus: inProgressStatusName, category: "indeterminate")
  }

  /// Moves a ticket to another status (drag between columns, or pick-up). The
  /// board updates immediately; if Jira refuses the transition, it moves back.
  public func moveTicket(_ key: String, toStatus status: String, category: String?) async {
    guard let original = sprintTickets.first(where: { $0.key == key }) ?? ticketDetail,
      original.key == key, original.status != status
    else { return }
    let originalDetail = ticketDetail
    applyStatus(status, category: category, to: key)
    do {
      try await service.transition(key: key, toStatus: status)
      statusNotice = StatusNotice(ticketKey: key, text: "\(key) moved to \(status)", isError: false)
    } catch {
      applyStatus(original.status ?? "", category: original.statusCategory, to: key)
      if originalDetail?.key == key { ticketDetail = originalDetail }
      statusNotice = StatusNotice(
        ticketKey: key,
        text: "Could not move \(key) to \(status): \(Self.message(for: error))",
        isError: true)
    }
  }

  /// Works out which visible tickets should move, from their PRs (GitHub search)
  /// and open agent sessions. Nothing changes in Jira until `applySync()`.
  public func planSync(openSessionKeys: Set<String>) async {
    guard let pullRequestSearch, !isPlanningSync else { return }
    isPlanningSync = true
    defer { isPlanningSync = false }
    let tickets = filteredTickets.filter { $0.statusCategory != "done" }
    guard !tickets.isEmpty else {
      syncPlan = []
      syncSkipped = []
      return
    }
    do {
      let pullRequests = try await pullRequestSearch.ticketPullRequests(
        forKeys: tickets.map(\.key), owner: gitHubOwner(repositoryPath))
      for (key, linked) in pullRequests {
        pullRequestsByTicket[key] = linked.map(\.pullRequest)
      }
      let statuses = await workflowStatuses()
      var changes: [SyncChange] = []
      var skipped: [String] = []
      for ticket in tickets {
        guard
          let decision = JiraTicketSync.target(
            pullRequests: pullRequests[ticket.key] ?? [],
            hasOpenSession: openSessionKeys.contains(ticket.key))
        else { continue }
        guard let status = JiraTicketSync.statusName(for: decision.target, among: statuses) else {
          skipped.append("\(ticket.key): no status for “\(decision.reason)” in this workflow")
          continue
        }
        guard status != ticket.status else { continue }
        changes.append(
          SyncChange(
            key: ticket.key, summary: ticket.summary, fromStatus: ticket.status ?? "No status",
            toStatus: status,
            toCategory: statuses.first { $0.name == status }?.category,
            reason: decision.reason))
      }
      syncPlan = changes
      syncSkipped = skipped
    } catch {
      statusNotice = StatusNotice(
        ticketKey: "", text: "Sync failed: \(Self.message(for: error))", isError: true)
    }
  }

  public func applySync() async {
    guard let plan = syncPlan, !isApplyingSync else { return }
    isApplyingSync = true
    defer { isApplyingSync = false }
    var failures: [String] = []
    for change in plan {
      do {
        try await service.transition(key: change.key, toStatus: change.toStatus)
        applyStatus(change.toStatus, category: change.toCategory, to: change.key)
      } catch {
        failures.append("\(change.key): \(Self.message(for: error))")
      }
    }
    syncPlan = nil
    statusNotice =
      failures.isEmpty
      ? StatusNotice(ticketKey: "", text: "Synced \(plan.count) tickets", isError: false)
      : StatusNotice(
        ticketKey: "",
        text: "Synced \(plan.count - failures.count) of \(plan.count). " + failures.joined(separator: "; "),
        isError: true)
  }

  public func cancelSync() {
    syncPlan = nil
    syncSkipped = []
  }

  /// Statuses this workflow uses: the board's plus those of recently updated tickets
  /// in the same projects (the sprint may have no ticket in "UX Review" right now).
  private func workflowStatuses() async -> [(name: String, category: String?)] {
    var statuses = loadedStatuses
    let projects = Set(sprintTickets.compactMap { $0.key.split(separator: "-").first.map(String.init) })
    if !projects.isEmpty,
      let recent = try? await service.searchTickets(
        jql: "project in (\(projects.sorted().joined(separator: ","))) AND updated >= -60d", limit: 200)
    {
      for ticket in recent {
        let name = ticket.status ?? ""
        if !name.isEmpty, !statuses.contains(where: { $0.name == name }) {
          statuses.append((name, ticket.statusCategory))
        }
      }
    }
    return statuses
  }

  public func dismissStatusNotice() {
    statusNotice = nil
  }

  private func applyStatus(_ status: String, category: String?, to key: String) {
    sprintTickets = sprintTickets.map {
      $0.key == key ? $0.withStatus(status, category: category) : $0
    }
    if ticketDetail?.key == key {
      ticketDetail = ticketDetail?.withStatus(status, category: category)
    }
  }

  public func closeTicket() {
    detailTask?.cancel()
    selectedTicketKey = nil
    ticketDetail = nil
    isLoadingDetail = false
  }

  // MARK: - Launch

  /// Builds the agent prompt, using the full ticket (with description) when it can be read.
  public func launchPrompt(for ticket: JiraTicketSnapshot) async -> String {
    if ticket.description != nil { return Self.prompt(for: ticket) }
    let detailed = (try? await service.ticket(key: ticket.key)) ?? ticket
    return Self.prompt(for: detailed)
  }

  static func prompt(for ticket: JiraTicketSnapshot) -> String {
    var lines = ["Pick up Jira ticket \(ticket.key): \(ticket.summary)"]
    if let issueType = ticket.issueType { lines.append("Type: \(issueType)") }
    if let status = ticket.status { lines.append("Status: \(status)") }
    if let description = ticket.description?.trimmingCharacters(in: .whitespacesAndNewlines),
      !description.isEmpty
    {
      lines.append("")
      lines.append("Description:")
      lines.append(description)
    }
    lines.append("")
    lines.append(
      "Read the full ticket with `acli jira workitem view \(ticket.key)` if you need more context "
        + "(comments, acceptance criteria). Work on a branch named after the ticket key "
        + "(for example `\(ticket.key.lowercased())-short-description`), implement the change, "
        + "and run the relevant tests before you finish."
    )
    lines.append("")
    lines.append(GitHubAPIBudgetGuidance.text)
    return lines.joined(separator: "\n")
  }

  static func message(for error: Error) -> String {
    switch error as? JiraTicketReaderError {
    case .commandFailed(_, let message) where !message.isEmpty:
      return message
    case .commandFailed(let exitCode, _):
      return "acli exited with code \(exitCode). Is Jira connected?"
    case .invalidResponse:
      return "Jira returned a response AgentHub could not read."
    case .invalidTicketKey:
      return "Invalid Jira ticket key."
    case nil:
      return error.localizedDescription
    }
  }
}
