//
//  GitHubReviewsViewModel.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation
import Observation

@MainActor
@Observable
public final class GitHubReviewsViewModel {
  private enum DefaultsKey {
    static let projectID = "agenthub.reviews.github-project-id"
    static let viewID = "agenthub.reviews.github-project-view-id"
    static let cache = "agenthub.reviews.github-project-cache-v1"
  }

  private struct CachedReviewQueue: Codable {
    let pullRequests: [GitHubProjectPullRequest]
    let updatedAt: Date
  }

  private struct ReviewCache: Codable {
    var projects: [GitHubReviewProject]
    var queues: [String: CachedReviewQueue]
  }

  private let service: any GitHubProjectReviewServiceProtocol
  private let sessionStore: (any GitHubReviewSessionStoreProtocol)?
  private let defaults: UserDefaults
  private var didLoad = false
  private var didLoadSessionAssociations = false
  private var didAttemptLegacySessionRecovery = false
  private var refreshGeneration = 0
  private var cachedQueues: [String: CachedReviewQueue] = [:]
  private var reviewSessionLaunchesByPullRequestID: [String: [GitHubReviewSessionLaunch]] = [:] {
    didSet { linkedReferencesCache = [:] }
  }
  /// Every session card reads this on each render; with hundreds of launches the
  /// sort + URL parsing showed up in profiles. Rebuilt only when launches change.
  @ObservationIgnored private var linkedReferencesCache:
    [SessionProviderKind: [String: [GitHubPullRequestURLReference]]] = [:]

  public private(set) var projects: [GitHubReviewProject] = []
  public private(set) var selectedProjectID: String?
  public private(set) var selectedViewID: String?
  public private(set) var pullRequests: [GitHubProjectPullRequest] = []
  public private(set) var isLoadingProjects = false
  public private(set) var isLoadingPullRequests = false
  public private(set) var isShowingCachedPullRequests = false
  public private(set) var cachedPullRequestsUpdatedAt: Date?
  public private(set) var errorMessage: String?
  private(set) var recoveryIssue: GitHubReviewRecoveryIssue?
  public private(set) var sessionLinkErrorMessage: String?

  // Table state lives here, not in the view: the Reviews view is rebuilt every
  // time the user comes back from a session, and @State would reset the order.
  public var searchText = ""
  var tableSortOrder = GitHubReviewTableRow.suggestedSortOrder
  public var selectedPullRequestID: String?
  /// Your GitHub login, so bulk review can skip your own pull requests.
  public private(set) var viewerLogin: String?

  /// Selects the pull request a session is linked to, e.g. when jumping in from a session.
  public func focusPullRequest(owner: String, repository: String, number: Int) {
    let nameWithOwner = "\(owner)/\(repository)"
    guard
      let pullRequest = pullRequests.first(where: {
        $0.number == number
          && $0.repositoryNameWithOwner.caseInsensitiveCompare(nameWithOwner) == .orderedSame
      })
    else { return }
    selectedPullRequestID = pullRequest.id
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty, !pullRequest.title.localizedCaseInsensitiveContains(query) {
      searchText = ""
    }
  }

  public var isRefreshing: Bool {
    isLoadingProjects || isLoadingPullRequests
  }

  public convenience init(
    service: any GitHubProjectReviewServiceProtocol,
    userDefaults: UserDefaults = .standard
  ) {
    self.init(service: service, sessionStore: nil, userDefaults: userDefaults)
  }

  init(
    service: any GitHubProjectReviewServiceProtocol,
    sessionStore: (any GitHubReviewSessionStoreProtocol)?,
    userDefaults: UserDefaults = .standard
  ) {
    self.service = service
    self.sessionStore = sessionStore
    defaults = userDefaults
    selectedProjectID = userDefaults.string(forKey: DefaultsKey.projectID)
    selectedViewID = userDefaults.string(forKey: DefaultsKey.viewID)
    restoreCache()
  }

  public var selectedProject: GitHubReviewProject? {
    projects.first { $0.id == selectedProjectID }
  }

  public var availableViews: [GitHubProjectView] {
    selectedProject?.views ?? []
  }

  public var selectedView: GitHubProjectView? {
    availableViews.first { $0.id == selectedViewID }
  }

  public var activeFilter: String {
    selectedView?.filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  var linkedSessionReferences: [AgentWorkspaceSessionReference] {
    var references: Set<AgentWorkspaceSessionReference> = []
    for launch in reviewSessionLaunchesByPullRequestID.values.flatMap({ $0 }) {
      guard let sessionID = launch.sessionID else { continue }
      references.insert(
        AgentWorkspaceSessionReference(
          provider: launch.provider,
          sessionId: sessionID,
          projectPath: launch.projectPath
        ))
    }
    return references.sorted {
      if $0.provider.rawValue == $1.provider.rawValue {
        return $0.sessionId < $1.sessionId
      }
      return $0.provider.rawValue < $1.provider.rawValue
    }
  }

  var shouldRecoverLegacySessionLinks: Bool {
    !didAttemptLegacySessionRecovery
  }

  public func load() async {
    guard !didLoad else { return }
    didLoad = true
    await loadSessionAssociations()
    async let login = service.viewerLogin()
    await loadProjects()
    viewerLogin = await login
  }

  /// Pull requests a bulk review should start on: authored by someone else.
  /// Empty while your login is unknown, so your own PRs are never included by accident.
  func bulkReviewCandidates(_ pullRequests: [GitHubProjectPullRequest]) -> [GitHubProjectPullRequest] {
    guard let viewerLogin else { return [] }
    return pullRequests.filter {
      $0.authorLogin?.caseInsensitiveCompare(viewerLogin) != .orderedSame
    }
  }

  /// Restores durable Reviews-to-Sessions links without fetching the GitHub
  /// Project queue. Sessions calls this during app startup so PR context is
  /// available even when the user never opens the Reviews tab.
  public func loadSessionAssociations() async {
    guard !didLoadSessionAssociations else { return }
    didLoadSessionAssociations = true
    await restoreReviewSessionLaunches()
  }

  public func reloadProjects() async {
    await loadProjects()
  }

  public func cancelRefresh() {
    refreshGeneration += 1
    isLoadingProjects = false
    isLoadingPullRequests = false
  }

  public func selectProject(id: String) {
    guard selectedProjectID != id, projects.contains(where: { $0.id == id }) else { return }
    selectedProjectID = id
    defaults.set(id, forKey: DefaultsKey.projectID)
    selectedViewID = preferredView(in: selectedProject)?.id
    persistSelectedView()
    restoreCachedPullRequests()
    Task { await refreshPullRequests() }
  }

  public func selectView(id: String) {
    guard selectedViewID != id, availableViews.contains(where: { $0.id == id }) else { return }
    selectedViewID = id
    persistSelectedView()
    restoreCachedPullRequests()
    Task { await refreshPullRequests() }
  }

  public func refreshPullRequests() async {
    guard let project = selectedProject, let view = selectedView else {
      pullRequests = []
      cachedPullRequestsUpdatedAt = nil
      isShowingCachedPullRequests = false
      return
    }

    refreshGeneration += 1
    let generation = refreshGeneration
    isLoadingPullRequests = true
    errorMessage = nil
    recoveryIssue = nil
    do {
      let requests = try await service.listPullRequests(
        project: project,
        view: view,
        limit: 1_000
      )
      guard generation == refreshGeneration,
        selectedProjectID == project.id,
        selectedViewID == view.id
      else { return }
      pullRequests = requests.filter { !$0.isDraft }
      let updatedAt = Date()
      cachedPullRequestsUpdatedAt = updatedAt
      isShowingCachedPullRequests = false
      cachedQueues[cacheKey(projectID: project.id, viewID: view.id)] = CachedReviewQueue(
        pullRequests: pullRequests,
        updatedAt: updatedAt
      )
      persistCache()
      isLoadingPullRequests = false
    } catch {
      guard generation == refreshGeneration else { return }
      isLoadingPullRequests = false
      isShowingCachedPullRequests = !pullRequests.isEmpty
      presentRecoveryIssue(for: error)
    }
  }

  public func presentLaunchError(_ message: String) {
    recoveryIssue = nil
    errorMessage = message
  }

  public func registerReviewLaunch(
    for pullRequest: GitHubProjectPullRequest,
    provider: SessionProviderKind,
    pendingID: UUID,
    projectPath: String,
    launchedAt: Date = Date()
  ) async {
    let launch = GitHubReviewSessionLaunch(
      pullRequestID: pullRequest.id,
      pullRequestURL: pullRequest.url,
      provider: provider,
      pendingID: pendingID,
      projectPath: projectPath,
      launchedAt: launchedAt
    )
    upsert(launch)
    await persist(launch)
  }

  public func resolveReviewLaunches(
    _ resolutions: [UUID: String],
    provider: SessionProviderKind
  ) async {
    guard !resolutions.isEmpty else { return }

    for (pullRequestID, launches) in reviewSessionLaunchesByPullRequestID {
      var updatedLaunches = launches
      var didChange = false
      for index in updatedLaunches.indices {
        let launch = updatedLaunches[index]
        guard launch.provider == provider,
          let pendingID = launch.pendingID,
          let sessionID = resolutions[pendingID],
          launch.sessionID != sessionID
        else { continue }

        let resolved = launch.resolving(to: sessionID)
        updatedLaunches[index] = resolved
        didChange = true
        await persist(resolved)
      }
      if didChange {
        reviewSessionLaunchesByPullRequestID[pullRequestID] = updatedLaunches
      }
    }
  }

  func recoverReviewSessions(
    provider: SessionProviderKind,
    searchResults: [SessionSearchResult]
  ) async {
    for pullRequest in pullRequests {
      let existing = reviewSessionLaunchesByPullRequestID[pullRequest.id]?.first {
        $0.provider == provider && $0.sessionID != nil
      }
      guard existing == nil else { continue }
      guard
        let result =
          searchResults
          .filter({ isReviewResult($0, for: pullRequest) })
          .max(by: { $0.lastActivityAt < $1.lastActivityAt })
      else { continue }

      let launch = GitHubReviewSessionLaunch(
        pullRequestID: pullRequest.id,
        pullRequestURL: pullRequest.url,
        provider: provider,
        pendingID: nil,
        sessionID: result.id,
        projectPath: result.projectPath,
        launchedAt: result.lastActivityAt
      )
      upsert(launch)
      await persist(launch)
    }
  }

  func finishLegacySessionRecovery() {
    didAttemptLegacySessionRecovery = true
  }

  func reviewSessionLaunches(
    for pullRequest: GitHubProjectPullRequest
  ) -> [GitHubReviewSessionLaunch] {
    reviewSessionLaunchesByPullRequestID[pullRequest.id] ?? []
  }

  func linkedSessionTitles(provider: SessionProviderKind) -> [String: String] {
    let titlesByPullRequestID = Dictionary(
      uniqueKeysWithValues: pullRequests.map { ($0.id, $0.title) }
    )
    var titles: [String: String] = [:]
    for (pullRequestID, launches) in reviewSessionLaunchesByPullRequestID {
      guard let title = titlesByPullRequestID[pullRequestID] else { continue }
      for launch in launches where launch.provider == provider {
        if let sessionID = launch.sessionID {
          titles[sessionID] = title
        }
      }
    }
    return titles
  }

  func linkedPullRequestReferencesByItemID(
    provider: SessionProviderKind
  ) -> [String: [GitHubPullRequestURLReference]] {
    // Touch the observed source so views still update when launches change.
    _ = reviewSessionLaunchesByPullRequestID.count
    if let cached = linkedReferencesCache[provider] { return cached }
    var referencesByItemID: [String: [GitHubPullRequestURLReference]] = [:]
    let launches = reviewSessionLaunchesByPullRequestID.values
      .flatMap { $0 }
      .filter { $0.provider == provider }
      .sorted { $0.launchedAt < $1.launchedAt }

    for launch in launches {
      guard let reference = GitHubPullRequestURLReference(urlString: launch.pullRequestURL) else {
        continue
      }

      let itemID: String
      if let sessionID = launch.sessionID {
        itemID = SidebarSessionItemID.monitored(provider: provider, sessionId: sessionID)
      } else if let pendingID = launch.pendingID {
        itemID = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
      } else {
        continue
      }

      if referencesByItemID[itemID]?.contains(reference) != true {
        referencesByItemID[itemID, default: []].append(reference)
      }
    }
    linkedReferencesCache[provider] = referencesByItemID
    return referencesByItemID
  }

  private func upsert(_ launch: GitHubReviewSessionLaunch) {
    var launches = reviewSessionLaunchesByPullRequestID[launch.pullRequestID] ?? []
    launches.removeAll { $0.provider == launch.provider }
    launches.append(launch)
    reviewSessionLaunchesByPullRequestID[launch.pullRequestID] = launches
  }

  private func restoreReviewSessionLaunches() async {
    guard let sessionStore else { return }
    do {
      let associations = try await sessionStore.githubReviewSessionAssociations()
      reviewSessionLaunchesByPullRequestID = Dictionary(
        grouping: associations.compactMap(GitHubReviewSessionLaunch.init),
        by: \.pullRequestID
      )
      sessionLinkErrorMessage = nil
    } catch {
      sessionLinkErrorMessage =
        "Could not restore linked review sessions: \(error.localizedDescription)"
    }
  }

  private func persist(_ launch: GitHubReviewSessionLaunch) async {
    guard let sessionStore else { return }
    do {
      try await sessionStore.saveGitHubReviewSessionAssociation(launch.association)
      sessionLinkErrorMessage = nil
    } catch {
      sessionLinkErrorMessage =
        "Could not save the review session link: \(error.localizedDescription)"
    }
  }

  private func isReviewResult(
    _ result: SessionSearchResult,
    for pullRequest: GitHubProjectPullRequest
  ) -> Bool {
    guard let message = result.firstMessage,
      message.contains(pullRequest.url)
    else { return false }
    return message.localizedCaseInsensitiveContains("independent code review")
      || message.localizedCaseInsensitiveContains("Review this pull request independently")
      || message.localizedCaseInsensitiveContains("read-only review")
  }

  private func loadProjects() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    isLoadingProjects = true
    errorMessage = nil
    recoveryIssue = nil
    do {
      let loadedProjects = try await service.listProjects()
      guard generation == refreshGeneration else { return }
      projects = loadedProjects
      normalizeSelection()
      restoreCachedPullRequests()
      persistCache()
      isLoadingProjects = false
      await refreshPullRequests()
    } catch {
      guard generation == refreshGeneration else { return }
      isLoadingProjects = false
      isShowingCachedPullRequests = !pullRequests.isEmpty
      presentRecoveryIssue(for: error)
    }
  }

  private func presentRecoveryIssue(for error: Error) {
    errorMessage = nil
    let issue = GitHubReviewRecoveryIssue.classify(error)
    recoveryIssue = issue
    guard issue.kind == .rateLimited else { return }
    // Say when the quota frees up; the lookup itself costs no quota.
    Task { [service] in
      let resetAt = await service.rateLimitResetDate()
      guard let resetAt, self.recoveryIssue?.kind == .rateLimited else { return }
      self.recoveryIssue = .rateLimited(resetAt: resetAt, details: issue.technicalDetails)
    }
  }

  private func normalizeSelection() {
    if !projects.contains(where: { $0.id == selectedProjectID }) {
      selectedProjectID =
        projects.first {
          $0.views.contains {
            $0.name.localizedCaseInsensitiveContains("code review")
          }
        }?.id ?? projects.first?.id
    }
    if !availableViews.contains(where: { $0.id == selectedViewID }) {
      selectedViewID = preferredView(in: selectedProject)?.id
    }
    if let selectedProjectID {
      defaults.set(selectedProjectID, forKey: DefaultsKey.projectID)
    }
    persistSelectedView()
  }

  private func preferredView(in project: GitHubReviewProject?) -> GitHubProjectView? {
    guard let project else { return nil }
    return project.views.first {
      $0.name.localizedCaseInsensitiveContains("code review")
    } ?? project.views.first {
      let filter = $0.filter?.lowercased() ?? ""
      return filter.contains("is:pr") && filter.contains("status:")
    } ?? project.views.first {
      $0.filter?.localizedCaseInsensitiveContains("is:pr") == true
    } ?? project.views.first
  }

  private func persistSelectedView() {
    if let selectedViewID {
      defaults.set(selectedViewID, forKey: DefaultsKey.viewID)
    } else {
      defaults.removeObject(forKey: DefaultsKey.viewID)
    }
  }

  private func restoreCache() {
    guard let data = defaults.data(forKey: DefaultsKey.cache),
      let cache = try? JSONDecoder().decode(ReviewCache.self, from: data)
    else { return }

    projects = cache.projects
    cachedQueues = cache.queues
    normalizeSelection()
    restoreCachedPullRequests()
  }

  private func restoreCachedPullRequests() {
    guard let selectedProjectID, let selectedViewID,
      let cachedQueue = cachedQueues[
        cacheKey(
          projectID: selectedProjectID,
          viewID: selectedViewID
        )]
    else {
      pullRequests = []
      cachedPullRequestsUpdatedAt = nil
      isShowingCachedPullRequests = false
      return
    }

    pullRequests = cachedQueue.pullRequests.filter { !$0.isDraft }
    cachedPullRequestsUpdatedAt = cachedQueue.updatedAt
    isShowingCachedPullRequests = true
  }

  private func persistCache() {
    let cache = ReviewCache(projects: projects, queues: cachedQueues)
    guard let data = try? JSONEncoder().encode(cache) else { return }
    defaults.set(data, forKey: DefaultsKey.cache)
  }

  private func cacheKey(projectID: String, viewID: String) -> String {
    "\(projectID)::\(viewID)"
  }
}
