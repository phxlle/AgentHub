import AgentHubGitHub
import AgentHubSessionGraph
import AgentWorkflowCore
import Foundation
import Observation

struct AgentWorkflowReviewAutomationHooks {
  let status: (DetectedAgentSession) -> SessionStatus?
  let lastAssistantMessage: (DetectedAgentSession) -> String?
  let lastActivityAt: (DetectedAgentSession) -> Date?
  let startMonitoring: (DetectedAgentSession) -> Void
  let startReviewer: (DetectedBranchWorkflow, SessionProviderKind, String) -> Bool
  let sendPrompt: (DetectedAgentSession, String) -> Bool
}

@MainActor
@Observable
public final class AgentWorkflowDashboardViewModel {
  private let runtime: (any AgentWorkflowRuntimeProtocol)?
  private let claudeSessionsViewModel: CLISessionsViewModel?
  private let codexSessionsViewModel: CLISessionsViewModel?
  private let gitHubService: (any GitHubCLIServiceProtocol)?
  private let sessionInventoryLoader: (() -> Void)?
  private let sessionObservationSource: (() -> [AgentSessionObservation])?
  private let reviewAutomationHooks: AgentWorkflowReviewAutomationHooks?
  private let reviewerLaunchTimeout: TimeInterval
  private let transcriptEvidenceReader = AgentSessionTranscriptEvidenceReader()
  private let manualStateStore: ManualWorkflowDashboardStateStore
  private var didLoad = false
  private var pullRequestCache: [String: CachedPullRequest] = [:]
  private var analyzedObservations: [String: AgentSessionObservation] = [:]
  private var requestedSessionCount = 10
  private var discoveryGeneration = 0
  private var classifiedBranches: [DetectedBranchWorkflow] = []
  private var manualState: ManualWorkflowDashboardState
  private var pendingManualSessionLaunches: [PendingManualSessionLaunch] = []
  private var prioritySessionIDs: Set<String> = []

  private static let sessionAnalysisBatchSize = 10

  private struct CachedPullRequest {
    let pullRequest: DetectedPullRequest?
    let fetchedAt: Date
    let failed: Bool
  }

  private struct PullRequestLookup: Sendable {
    let index: Int
    let key: String
    let branch: DetectedBranchWorkflow
  }

  private struct PullRequestLookupResult: Sendable {
    let index: Int
    let key: String
    let pullRequest: DetectedPullRequest?
    let errorMessage: String?
  }

  private struct PendingManualSessionLaunch {
    let workflowID: String
    let provider: SessionProviderKind
    let role: DetectedAgentRole
    let repositoryPath: String
    let existingSessionIDs: Set<String>
    let startedAt: Date
    var pendingSessionID: UUID?
  }

  private struct ReviewerLaunchResult {
    let pendingSessionID: UUID?
  }

  public var ticketKey = ""
  public var coordinatorProvider = SessionProviderKind.codex
  public private(set) var tickets: [TicketRun] = []
  public private(set) var branches: [BranchRun] = []
  public private(set) var selectedTicketID: UUID?
  public private(set) var selectedBranchID: UUID?
  public private(set) var isLoading = false
  public private(set) var isStartingTicket = false
  public private(set) var errorMessage: String?
  var workflowScope = AgentWorkflowListScope.active
  private(set) var detectedBranches: [DetectedBranchWorkflow] = []
  private(set) var selectedWorkflowID: String?
  private(set) var selectedDetectedBranchID: String?
  private(set) var isDiscoveringSessions = false
  private(set) var pullRequestWarning: String?
  private(set) var analyzedSessionCount = 0
  private(set) var totalSessionCount = 0

  public init(
    runtime: (any AgentWorkflowRuntimeProtocol)?,
    startupError: String? = nil,
    claudeSessionsViewModel: CLISessionsViewModel? = nil,
    codexSessionsViewModel: CLISessionsViewModel? = nil,
    gitHubService: (any GitHubCLIServiceProtocol)? = nil,
    userDefaults: UserDefaults = .standard
  ) {
    self.runtime = runtime
    self.claudeSessionsViewModel = claudeSessionsViewModel
    self.codexSessionsViewModel = codexSessionsViewModel
    self.gitHubService = gitHubService
    sessionInventoryLoader = {
      claudeSessionsViewModel?.ensureBrowseSessionsLoaded()
      codexSessionsViewModel?.ensureBrowseSessionsLoaded()
    }
    sessionObservationSource = nil
    reviewAutomationHooks = nil
    reviewerLaunchTimeout = 60
    manualStateStore = ManualWorkflowDashboardStateStore(defaults: userDefaults)
    manualState = manualStateStore.load()
    errorMessage = startupError
  }

  init(
    runtime: (any AgentWorkflowRuntimeProtocol)? = nil,
    gitHubService: (any GitHubCLIServiceProtocol)? = nil,
    userDefaults: UserDefaults = .standard,
    reviewAutomationHooks: AgentWorkflowReviewAutomationHooks? = nil,
    sessionInventoryLoader: (() -> Void)? = nil,
    reviewerLaunchTimeout: TimeInterval = 60,
    sessionObservationSource: @escaping () -> [AgentSessionObservation]
  ) {
    self.runtime = runtime
    claudeSessionsViewModel = nil
    codexSessionsViewModel = nil
    self.gitHubService = gitHubService
    self.sessionInventoryLoader = sessionInventoryLoader
    self.sessionObservationSource = sessionObservationSource
    self.reviewAutomationHooks = reviewAutomationHooks
    self.reviewerLaunchTimeout = reviewerLaunchTimeout
    manualStateStore = ManualWorkflowDashboardStateStore(defaults: userDefaults)
    manualState = manualStateStore.load()
  }

  var displayedWorkflows: [DetectedTicketWorkflow] {
    AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: workflowScope)
  }

  var activeWorkflowDestinations: [SessionWorkflowDestination] {
    AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .active)
      .map { workflow in
        SessionWorkflowDestination(
          id: workflow.id,
          title: workflow.ticketKey ?? workflow.summary ?? "Unassigned sessions"
        )
      }
      .sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
  }

  var activeWorkflowCount: Int {
    AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .active).count
  }

  var completedWorkflowCount: Int {
    AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .completed).count
  }

  var remainingSessionCount: Int {
    max(0, totalSessionCount - analyzedSessionCount)
  }

  var nextSessionBatchCount: Int {
    min(Self.sessionAnalysisBatchSize, remainingSessionCount)
  }

  var sessionLibraryItems: [WorkflowSessionLibraryItem] {
    let activeWorkflows = AgentSessionWorkflowClassifier.workflows(
      from: detectedBranches,
      scope: .active
    )
    let completedSessionIDs = Set(
      AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .completed)
        .flatMap(\.branches)
        .flatMap { $0.implementerSessions + $0.reviewerSessions }
        .map(\.id)
    )
    var activeAssignments: [String: DetectedAgentSession] = [:]
    var workflowTitles: [String: String] = [:]

    for workflow in activeWorkflows {
      let title = workflow.ticketKey ?? workflow.summary ?? "Unassigned sessions"
      for assignment in workflow.branches.flatMap({
        $0.implementerSessions + $0.reviewerSessions
      }) {
        activeAssignments[assignment.id] = assignment
        workflowTitles[assignment.id] = title
      }
    }

    return sessionObservations()
      .sorted(by: analysisObservationSort)
      .compactMap { observation in
        let id = observationID(observation)
        guard !completedSessionIDs.contains(id) else { return nil }
        let assignment =
          activeAssignments[id]
          ?? DetectedAgentSession(
            session: observation.session,
            provider: observation.provider,
            role: .implementer,
            roleConfidence: .low,
            roleReason: "Not analyzed yet"
          )
        return WorkflowSessionLibraryItem(
          assignment: assignment,
          workflowTitle: workflowTitles[id],
          isAnalyzed: analyzedObservations[id] != nil
        )
      }
  }

  var canAnalyzeNextSessionBatch: Bool {
    !isDiscoveringSessions
      && remainingSessionCount > 0
      && analyzedSessionCount >= min(requestedSessionCount, totalSessionCount)
  }

  var selectedDetectedWorkflow: DetectedTicketWorkflow? {
    displayedWorkflows.first { $0.id == selectedWorkflowID }
  }

  var selectedDetectedBranch: DetectedBranchWorkflow? {
    selectedDetectedWorkflow?.branches.first { $0.id == selectedDetectedBranchID }
  }

  var sessionRevision: Int {
    var hasher = Hasher()
    for observation in sessionObservations().sorted(by: observationSort) {
      let session = observation.session
      hasher.combine(observation.provider.rawValue)
      hasher.combine(session.id)
      hasher.combine(session.branchName)
      hasher.combine(session.lastActivityAt)
      hasher.combine(session.isActive)
      hasher.combine(session.firstMessage)
      hasher.combine(session.lastMessage)
      let assignment = DetectedAgentSession(
        session: session,
        provider: observation.provider,
        role: .implementer,
        roleConfidence: .low,
        roleReason: "revision"
      )
      hasher.combine(status(for: assignment)?.displayName)
      hasher.combine(lastAssistantMessage(for: assignment))
    }
    return hasher.finalize()
  }

  public var selectedTicket: TicketRun? {
    tickets.first { $0.id == selectedTicketID }
  }

  public var selectedBranch: BranchRun? {
    branches.first { $0.id == selectedBranchID }
  }

  public var canStartTicket: Bool {
    runtime != nil && !normalizedTicketKey.isEmpty && !isStartingTicket
  }

  public func load() async {
    guard !didLoad else { return }
    didLoad = true
    sessionInventoryLoader?()
    schedulePersistedReviewerLaunchTimeouts()
    isLoading = true
    defer { isLoading = false }

    if let runtime {
      do {
        tickets = try await runtime.tickets()
        errorMessage = nil
        if selectedTicketID == nil, let firstTicket = tickets.first {
          await selectTicket(firstTicket.id)
        }
      } catch {
        errorMessage = "Could not load workflows: \(error.localizedDescription)"
      }
    }
  }

  func refreshDetectedWorkflows(forcePullRequestRefresh: Bool = false) async {
    discoveryGeneration += 1
    let generation = discoveryGeneration
    isDiscoveringSessions = true
    defer {
      if generation == discoveryGeneration {
        isDiscoveringSessions = false
      }
    }

    let allObservations = sessionObservations().sorted(by: analysisObservationSort)
    capturePendingManualSessionLaunches(in: allObservations)
    captureAutomatedReviewerSessions(in: allObservations)
    synchronizeAnalyzedObservations(with: allObservations)
    prioritySessionIDs.formUnion(knownWorkflowSessionIDs)
    totalSessionCount = allObservations.count

    if forcePullRequestRefresh {
      await rebuildDetectedBranches(
        forcePullRequestRefresh: true,
        discoveryGeneration: generation
      )
      return
    }

    let targetCount = min(requestedSessionCount, totalSessionCount)
    let requestedBatchCount = max(0, targetCount - analyzedSessionCount)
    let unprocessedObservations = allObservations.filter {
      analyzedObservations[observationID($0)] == nil
    }
    let priorityObservationCount = unprocessedObservations.count {
      prioritySessionIDs.contains(observationID($0))
    }
    let batch = Array(
      unprocessedObservations
        .sorted { lhs, rhs in
          let lhsIsPriority = prioritySessionIDs.contains(observationID(lhs))
          let rhsIsPriority = prioritySessionIDs.contains(observationID(rhs))
          if lhsIsPriority != rhsIsPriority { return lhsIsPriority }
          return analysisObservationSort(lhs, rhs)
        }
        .prefix(
          max(
            min(Self.sessionAnalysisBatchSize, requestedBatchCount),
            priorityObservationCount
          )
        )
    )

    guard !batch.isEmpty else {
      await rebuildDetectedBranches(
        forcePullRequestRefresh: false,
        discoveryGeneration: generation
      )
      return
    }

    let preliminaryObservations = Array(analyzedObservations.values) + batch
    var lightweightBranches = AgentSessionWorkflowClassifier.classify(preliminaryObservations)
    lightweightBranches = await resolvingPullRequests(
      for: lightweightBranches,
      forceRefresh: false
    )
    guard !Task.isCancelled, generation == discoveryGeneration else { return }

    let completedBranches = lightweightBranches.filter(\.isCompleted)
    let completedSessionIDs = Set(
      completedBranches
        .flatMap { $0.implementerSessions + $0.reviewerSessions }
        .map(\.id)
    )
    let activeObservations = batch.filter {
      !completedSessionIDs.contains(observationID($0))
    }
    let enrichedActiveObservations = await transcriptEvidenceReader.enrich(activeObservations)
    guard !Task.isCancelled, generation == discoveryGeneration else { return }

    let enrichedByID = Dictionary(
      uniqueKeysWithValues: enrichedActiveObservations.map { (observationID($0), $0) }
    )
    for observation in batch {
      let id = observationID(observation)
      analyzedObservations[id] = enrichedByID[id] ?? observation
      prioritySessionIDs.remove(id)
    }
    analyzedSessionCount = analyzedObservations.count

    await rebuildDetectedBranches(
      forcePullRequestRefresh: false,
      discoveryGeneration: generation
    )
  }

  func analyzeNextSessionBatch() async {
    guard canAnalyzeNextSessionBatch else { return }
    requestedSessionCount = min(
      totalSessionCount,
      max(requestedSessionCount, analyzedSessionCount) + Self.sessionAnalysisBatchSize
    )
    await refreshDetectedWorkflows()
  }

  private var knownWorkflowSessionIDs: Set<String> {
    var result = Set(manualState.sessionAssignments.keys)
    for review in manualState.automatedReviews.values {
      result.insert(review.implementerSessionID)
      if let reviewerSessionID = review.reviewerSessionID {
        result.insert(reviewerSessionID)
      }
    }
    for branch in detectedBranches {
      result.formUnion((branch.implementerSessions + branch.reviewerSessions).map(\.id))
    }
    return result
  }

  @discardableResult
  func createManualWorkflow(
    name: String,
    repositoryPath: String,
    branchName: String? = nil
  ) -> String? {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRepositoryPath = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    guard !normalizedName.isEmpty, !normalizedRepositoryPath.isEmpty else { return nil }

    let normalizedBranchName = branchName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let definition = ManualWorkflowDefinition(
      id: UUID(),
      name: normalizedName,
      repositoryPath: normalizedRepositoryPath,
      branchName: normalizedBranchName?.isEmpty == false ? normalizedBranchName : nil,
      createdAt: Date()
    )
    manualState.workflows.append(definition)
    persistManualState()
    applyManualWorkflowProjection()
    workflowScope = .active
    selectedWorkflowID = definition.workflowID
    selectedDetectedBranchID = selectedDetectedWorkflow?.branches.first?.id
    return definition.workflowID
  }

  @discardableResult
  func createManualWorkflowAndMoveSession(
    name: String,
    repositoryPath: String,
    branchName: String?,
    sessionID: String
  ) async -> String? {
    let observation = sessionObservations().first { observationID($0) == sessionID }
    let resolvedRepositoryPath = observation?.repositoryPath ?? repositoryPath
    let resolvedBranchName = observation?.branchName ?? branchName
    guard
      let workflowID = createManualWorkflow(
        name: name,
        repositoryPath: resolvedRepositoryPath,
        branchName: resolvedBranchName
      )
    else {
      return nil
    }
    await moveSession(sessionID, to: workflowID)
    return workflowID
  }

  func deleteManualWorkflow(_ workflowID: String) {
    let removedSessionIDs = Set(
      manualState.sessionAssignments.compactMap { sessionID, assignedWorkflowID in
        assignedWorkflowID == workflowID ? sessionID : nil
      }
    )
    manualState.workflows.removeAll { $0.workflowID == workflowID }
    manualState.archivedWorkflowIDs.remove(workflowID)
    manualState.sessionAssignments = manualState.sessionAssignments.filter {
      $0.value != workflowID
    }
    manualState.sessionRoleOverrides = manualState.sessionRoleOverrides.filter {
      !removedSessionIDs.contains($0.key)
    }
    manualState.automatedReviews = manualState.automatedReviews.filter {
      $0.value.workflowID != workflowID
    }
    persistManualState()
    applyManualWorkflowProjection()
    repairDetectedSelection()
  }

  func archiveWorkflow(_ workflowID: String) {
    guard displayedWorkflows.contains(where: { $0.id == workflowID }) else { return }
    for record in manualState.automatedReviews.values where record.workflowID == workflowID {
      cancelPendingReviewerSession(for: record)
    }
    manualState.automatedReviews = manualState.automatedReviews.filter {
      $0.value.workflowID != workflowID
    }
    manualState.archivedWorkflowIDs.insert(workflowID)
    persistManualState()
    applyManualWorkflowProjection()
    repairDetectedSelection()
  }

  func restoreWorkflow(_ workflowID: String) {
    guard manualState.archivedWorkflowIDs.remove(workflowID) != nil else { return }
    persistManualState()
    applyManualWorkflowProjection()
    repairDetectedSelection()
  }

  func moveSession(_ sessionID: String, to workflowID: String) async {
    guard availableWorkflowIDs.contains(workflowID) else { return }
    let promotedObservation = sessionObservations().first {
      observationID($0) == sessionID && analyzedObservations[sessionID] == nil
    }
    if let promotedObservation {
      analyzedObservations[sessionID] = promotedObservation
      analyzedSessionCount = analyzedObservations.count
      prioritySessionIDs.remove(sessionID)
    }
    manualState.dismissedSessionIDs.remove(sessionID)
    manualState.sessionAssignments[sessionID] = workflowID
    persistManualState()
    if promotedObservation != nil {
      await rebuildDetectedBranches(
        forcePullRequestRefresh: false,
        discoveryGeneration: discoveryGeneration
      )
    } else {
      applyManualWorkflowProjection()
    }
    selectedWorkflowID = workflowID
    selectedDetectedBranchID = selectedDetectedWorkflow?.branches.first?.id
  }

  func removeSessionWorkflowOverride(_ sessionID: String) {
    guard manualState.sessionAssignments.removeValue(forKey: sessionID) != nil else { return }
    manualState.sessionRoleOverrides.removeValue(forKey: sessionID)
    persistManualState()
    applyManualWorkflowProjection()
    repairDetectedSelection()
  }

  func hasSessionWorkflowOverride(_ sessionID: String) -> Bool {
    manualState.sessionAssignments[sessionID] != nil
  }

  func workflowID(containing sessionID: String) -> String? {
    if let assignedWorkflowID = manualState.sessionAssignments[sessionID] {
      return assignedWorkflowID
    }
    return AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .active)
      .first { workflow in
        workflow.branches.contains { branch in
          (branch.implementerSessions + branch.reviewerSessions).contains { $0.id == sessionID }
        }
      }?
      .id
  }

  func workflowAssociation(for sessionID: String) -> SessionWorkflowAssociation? {
    for workflow in allProjectedWorkflows {
      for branch in workflow.branches {
        if branch.implementerSessions.contains(where: { $0.id == sessionID }) {
          return SessionWorkflowAssociation(
            workflowID: workflow.id,
            title: workflowDisplayTitle(workflow),
            role: .implementer,
            comparisonRequest: comparisonRequest(for: branch, workflow: workflow)
          )
        }
        if branch.reviewerSessions.contains(where: { $0.id == sessionID }) {
          return SessionWorkflowAssociation(
            workflowID: workflow.id,
            title: workflowDisplayTitle(workflow),
            role: .reviewer,
            comparisonRequest: comparisonRequest(for: branch, workflow: workflow)
          )
        }
      }
    }
    return nil
  }

  func comparisonRequest(for branchID: String) -> WorkflowSessionComparisonRequest? {
    for workflow in allProjectedWorkflows {
      guard let branch = workflow.branches.first(where: { $0.id == branchID }) else { continue }
      return comparisonRequest(for: branch, workflow: workflow)
    }
    return nil
  }

  func displayName(for assignment: DetectedAgentSession) -> String {
    switch assignment.provider {
    case .claude:
      return claudeSessionsViewModel?.displayName(for: assignment.session)
        ?? assignment.session.displayName
    case .codex:
      return codexSessionsViewModel?.displayName(for: assignment.session)
        ?? assignment.session.displayName
    }
  }

  private var allProjectedWorkflows: [DetectedTicketWorkflow] {
    AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .active)
      + AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .completed)
  }

  private func workflowDisplayTitle(_ workflow: DetectedTicketWorkflow) -> String {
    workflow.ticketKey ?? workflow.summary ?? "Workflow"
  }

  private func comparisonRequest(
    for branch: DetectedBranchWorkflow,
    workflow: DetectedTicketWorkflow
  ) -> WorkflowSessionComparisonRequest? {
    guard let implementer = branch.primaryImplementer,
      let reviewer = branch.primaryReviewer,
      implementer.id != reviewer.id
    else {
      return nil
    }
    return WorkflowSessionComparisonRequest(
      workflowID: workflow.id,
      title: workflowDisplayTitle(workflow),
      implementation: WorkflowSessionComparisonTarget(
        providerKind: implementer.provider,
        session: implementer.session
      ),
      review: WorkflowSessionComparisonTarget(
        providerKind: reviewer.provider,
        session: reviewer.session
      )
    )
  }

  func retryAutomatedReview(for branchID: String) {
    guard let record = manualState.automatedReviews[branchID], record.phase == .failed else {
      return
    }
    cancelPendingReviewerSession(for: record)
    manualState.automatedReviews.removeValue(forKey: branchID)
    guard
      let branch = detectedBranches.first(where: { $0.id == branchID }),
      let implementer = branch.primaryImplementer,
      beginReview(for: branch, implementer: implementer)
    else {
      persistManualState()
      applyManualWorkflowProjection()
      return
    }
    persistManualState()
    applyManualWorkflowProjection()
  }

  @discardableResult
  func createReviewAgent(for branchID: String) -> Bool {
    guard
      let branch = detectedBranches.first(where: { $0.id == branchID }),
      !branch.isCompleted,
      let implementer = branch.primaryImplementer,
      branch.reviewerSessions.isEmpty
    else {
      return false
    }

    if let record = manualState.automatedReviews[branchID] {
      guard record.phase == .failed else { return false }
      cancelPendingReviewerSession(for: record)
      manualState.automatedReviews.removeValue(forKey: branchID)
    }

    guard beginReview(for: branch, implementer: implementer) else { return false }
    persistManualState()
    applyManualWorkflowProjection()
    return true
  }

  func dismissSession(_ sessionID: String) {
    dismissSessions([sessionID])
  }

  func dismissSessions(_ sessionIDs: [String]) {
    let sessionIDs = Set(sessionIDs)
    guard !sessionIDs.isEmpty else { return }
    manualState.dismissedSessionIDs.formUnion(sessionIDs)
    manualState.sessionAssignments = manualState.sessionAssignments.filter {
      !sessionIDs.contains($0.key)
    }
    manualState.sessionRoleOverrides = manualState.sessionRoleOverrides.filter {
      !sessionIDs.contains($0.key)
    }
    for record in manualState.automatedReviews.values
    where sessionIDs.contains(record.implementerSessionID)
      || sessionIDs.contains(record.reviewerSessionID ?? "")
    {
      cancelPendingReviewerSession(for: record)
    }
    manualState.automatedReviews = manualState.automatedReviews.filter {
      !sessionIDs.contains($0.value.implementerSessionID)
        && !sessionIDs.contains($0.value.reviewerSessionID ?? "")
    }
    analyzedObservations = analyzedObservations.filter { !sessionIDs.contains($0.key) }
    prioritySessionIDs.subtract(sessionIDs)
    analyzedSessionCount = analyzedObservations.count
    totalSessionCount = max(analyzedSessionCount, totalSessionCount - sessionIDs.count)
    for sessionID in sessionIDs {
      classifiedBranches = branches(classifiedBranches, removingSessionID: sessionID)
    }
    persistManualState()
    applyManualWorkflowProjection()
    repairDetectedSelection()
  }

  func prepareManualSessionLaunch(
    workflowID: String,
    provider: SessionProviderKind,
    role: DetectedAgentRole = .implementer
  ) -> ManualWorkflowDefinition? {
    guard let workflow = manualState.workflows.first(where: { $0.workflowID == workflowID }) else {
      return nil
    }
    let existingSessionIDs = Set(
      sessionObservations()
        .filter { $0.provider == provider }
        .map(observationID)
    )
    pendingManualSessionLaunches.append(
      PendingManualSessionLaunch(
        workflowID: workflowID,
        provider: provider,
        role: role,
        repositoryPath: workflow.repositoryPath,
        existingSessionIDs: existingSessionIDs,
        startedAt: Date(),
        pendingSessionID: nil
      )
    )
    return workflow
  }

  func associateManualSessionLaunch(
    workflowID: String,
    provider: SessionProviderKind,
    pendingSessionID: UUID
  ) {
    guard
      let index = pendingManualSessionLaunches.lastIndex(where: {
        $0.workflowID == workflowID
          && $0.provider == provider
          && $0.pendingSessionID == nil
      })
    else {
      return
    }
    pendingManualSessionLaunches[index].pendingSessionID = pendingSessionID
  }

  func selectWorkflow(_ id: String?) {
    selectedWorkflowID = id
    selectedDetectedBranchID = selectedDetectedWorkflow?.branches.first?.id
  }

  func selectDetectedBranch(_ id: String?) {
    selectedDetectedBranchID = id
  }

  func changeScope(_ scope: AgentWorkflowListScope) {
    workflowScope = scope
    repairDetectedSelection()
  }

  public func startTicket() async {
    guard canStartTicket, let runtime else { return }
    isStartingTicket = true
    defer { isStartingTicket = false }

    do {
      let ticket = try await runtime.startTicketFromJira(
        key: normalizedTicketKey,
        coordinatorProvider: coordinatorProvider
      )
      tickets.removeAll { $0.id == ticket.id }
      tickets.insert(ticket, at: 0)
      ticketKey = ""
      errorMessage = nil
      await selectTicket(ticket.id)
    } catch {
      errorMessage = "Could not start \(normalizedTicketKey): \(error.localizedDescription)"
    }
  }

  public func selectTicket(_ id: UUID?) async {
    selectedTicketID = id
    selectedBranchID = nil
    branches = []
    guard let id, let runtime else { return }

    do {
      branches = try await runtime.branches(ticketRunID: id)
      selectedBranchID = branches.first?.id
      errorMessage = nil
    } catch {
      errorMessage = "Could not load branches: \(error.localizedDescription)"
    }
  }

  public func selectBranch(_ id: UUID?) {
    selectedBranchID = id
  }

  private var normalizedTicketKey: String {
    ticketKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private func sessionObservations() -> [AgentSessionObservation] {
    let availableObservations: [AgentSessionObservation]
    if let sessionObservationSource {
      availableObservations = sessionObservationSource()
    } else {
      availableObservations =
        observations(from: claudeSessionsViewModel, provider: .claude)
        + observations(from: codexSessionsViewModel, provider: .codex)
    }
    return availableObservations.filter {
      !manualState.dismissedSessionIDs.contains(observationID($0))
    }
  }

  private func synchronizeAnalyzedObservations(
    with availableObservations: [AgentSessionObservation]
  ) {
    let availableByID = Dictionary(
      uniqueKeysWithValues: availableObservations.map { (observationID($0), $0) }
    )
    analyzedObservations = analyzedObservations.reduce(into: [:]) { result, entry in
      guard let current = availableByID[entry.key] else { return }
      result[entry.key] = AgentSessionObservation(
        session: current.session,
        provider: current.provider,
        repositoryPath: current.repositoryPath,
        branchName: current.branchName,
        linkedPullRequests: Array(
          Set(current.linkedPullRequests + entry.value.linkedPullRequests)
        ).sorted { $0.number < $1.number },
        transcriptEvidence: entry.value.transcriptEvidence
      )
    }
    analyzedSessionCount = analyzedObservations.count
  }

  private func rebuildDetectedBranches(
    forcePullRequestRefresh: Bool,
    discoveryGeneration: Int
  ) async {
    var branches = AgentSessionWorkflowClassifier.classify(Array(analyzedObservations.values))
    branches = await resolvingPullRequests(
      for: branches,
      forceRefresh: forcePullRequestRefresh
    )
    guard !Task.isCancelled, discoveryGeneration == self.discoveryGeneration else { return }
    classifiedBranches = mergeBranchesSharingPullRequest(branches)
    applyManualWorkflowProjection()
    advanceAutomatedReviews()
    applyManualWorkflowProjection()
    repairDetectedSelection()
  }

  private var availableWorkflowIDs: Set<String> {
    let detectedWorkflowIDs = AgentSessionWorkflowClassifier.workflows(
      from: classifiedBranches,
      scope: .active
    ).map(\.id)
    return Set(detectedWorkflowIDs + manualState.workflows.map(\.workflowID))
  }

  private func persistManualState() {
    manualStateStore.save(manualState)
  }

  private func schedulePersistedReviewerLaunchTimeouts() {
    for (branchID, record) in manualState.automatedReviews
    where record.phase == .reviewerLaunching {
      scheduleReviewerLaunchTimeout(branchID: branchID, startedAt: record.startedAt)
    }
  }

  private func scheduleReviewerLaunchTimeout(branchID: String, startedAt: Date) {
    let remaining = max(
      0,
      reviewerLaunchTimeout - Date().timeIntervalSince(startedAt)
    )
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(remaining * 1_000)))
      let timeout = Int(self?.reviewerLaunchTimeout ?? 0)
      self?.failReviewerLaunch(
        branchID: branchID,
        startedAt: startedAt,
        message: "No reviewer session appeared within \(timeout) seconds."
      )
    }
  }

  private func failReviewerLaunch(
    branchID: String,
    startedAt: Date,
    message: String
  ) {
    guard var record = manualState.automatedReviews[branchID],
      record.phase == .reviewerLaunching,
      record.startedAt == startedAt
    else {
      return
    }
    cancelPendingReviewerSession(for: record)
    record.phase = .failed
    record.failureMessage = message
    manualState.automatedReviews[branchID] = record
    persistManualState()
    applyManualWorkflowProjection()
  }

  private func cancelPendingReviewerSession(for record: AutomatedReviewRecord) {
    guard
      let pendingID = record.reviewerPendingSessionID,
      let reviewerViewModel = sessionsViewModel(for: record.reviewerProvider),
      let pending = reviewerViewModel.pendingHubSessions.first(where: { $0.id == pendingID })
    else {
      return
    }
    reviewerViewModel.cancelPendingSession(pending)
  }

  private func capturePendingManualSessionLaunches(
    in observations: [AgentSessionObservation]
  ) {
    guard !pendingManualSessionLaunches.isEmpty else { return }
    var claimedSessionIDs = Set<String>()
    var remainingLaunches: [PendingManualSessionLaunch] = []
    var didChangeState = false

    for launch in pendingManualSessionLaunches {
      let repositoryPath = WorktreeModuleResolver.normalizedDirectoryPath(launch.repositoryPath)
      let candidate: AgentSessionObservation?
      if let pendingSessionID = launch.pendingSessionID {
        guard
          let resolvedSessionID = sessionsViewModel(for: launch.provider)?
            .resolvedPendingSessionHistory[pendingSessionID]
        else {
          remainingLaunches.append(launch)
          continue
        }
        candidate = observations.first { observation in
          observation.provider == launch.provider
            && observation.session.id == resolvedSessionID
        }
      } else {
        candidate = observations.first { observation in
          let id = observationID(observation)
          return observation.provider == launch.provider
            && !launch.existingSessionIDs.contains(id)
            && !claimedSessionIDs.contains(id)
            && WorktreeModuleResolver.normalizedDirectoryPath(observation.repositoryPath)
              == repositoryPath
            && observation.session.lastActivityAt >= launch.startedAt.addingTimeInterval(-5)
        }
      }
      guard let candidate else {
        remainingLaunches.append(launch)
        continue
      }
      let id = observationID(candidate)
      manualState.sessionAssignments[id] = launch.workflowID
      manualState.sessionRoleOverrides[id] = launch.role
      prioritySessionIDs.insert(id)
      claimedSessionIDs.insert(id)
      didChangeState = true
    }

    pendingManualSessionLaunches = remainingLaunches
    if didChangeState {
      persistManualState()
    }
  }

  private func captureAutomatedReviewerSessions(
    in observations: [AgentSessionObservation]
  ) {
    var didChangeState = false
    var claimedSessionIDs = Set<String>()

    for (branchID, storedRecord) in manualState.automatedReviews {
      guard storedRecord.phase == .reviewerLaunching,
        storedRecord.reviewerSessionID == nil
      else {
        continue
      }
      if Date().timeIntervalSince(storedRecord.startedAt) >= reviewerLaunchTimeout {
        failReviewerLaunch(
          branchID: branchID,
          startedAt: storedRecord.startedAt,
          message: "No reviewer session appeared within \(Int(reviewerLaunchTimeout)) seconds."
        )
        didChangeState = true
        continue
      }
      let repositoryPath = WorktreeModuleResolver.normalizedDirectoryPath(
        storedRecord.repositoryPath
      )
      let resolvedSessionID = storedRecord.reviewerPendingSessionID.flatMap { pendingID in
        sessionsViewModel(for: storedRecord.reviewerProvider)?
          .resolvedPendingSessionHistory[pendingID]
      }
      let candidate = observations.first { observation in
        let id = observationID(observation)
        if let resolvedSessionID {
          return observation.provider == storedRecord.reviewerProvider
            && observation.session.id == resolvedSessionID
        }
        return observation.provider == storedRecord.reviewerProvider
          && !storedRecord.reviewerBaselineSessionIDs.contains(id)
          && !claimedSessionIDs.contains(id)
          && WorktreeModuleResolver.normalizedDirectoryPath(observation.repositoryPath)
            == repositoryPath
          && observation.session.lastActivityAt >= storedRecord.startedAt.addingTimeInterval(-5)
      }
      guard let candidate else { continue }

      let sessionID = observationID(candidate)
      var record = storedRecord
      record.reviewerSessionID = sessionID
      record.phase = .reviewing
      record.failureMessage = nil
      manualState.automatedReviews[branchID] = record
      if record.workflowID.hasPrefix("manual:") {
        manualState.sessionAssignments[sessionID] = record.workflowID
      }
      prioritySessionIDs.insert(sessionID)
      claimedSessionIDs.insert(sessionID)
      didChangeState = true
    }

    if didChangeState {
      persistManualState()
    }
  }

  private func advanceAutomatedReviews() {
    var didChangeState = false
    let eligibleBranchIDs = Set(
      AgentSessionWorkflowClassifier.workflows(from: detectedBranches, scope: .active)
        .flatMap(\.branches)
        .map(\.id)
    )

    for branch in detectedBranches where !branch.isCompleted {
      if var record = manualState.automatedReviews[branch.id] {
        guard record.phase == .reviewing,
          let reviewerSessionID = record.reviewerSessionID,
          let reviewer = assignment(withID: reviewerSessionID, in: branch),
          isReadyForHandoff(reviewer)
        else {
          continue
        }
        guard lastActivityAt(for: reviewer) ?? .distantPast >= record.reviewRequestSentAt,
          let feedback = lastAssistantMessage(for: reviewer)?.trimmingCharacters(
            in: .whitespacesAndNewlines
          ),
          !feedback.isEmpty,
          let implementer = assignment(withID: record.implementerSessionID, in: branch)
        else {
          continue
        }

        let verdict = reviewVerdict(in: feedback)
        let handoffPrompt = implementationHandoffPrompt(
          feedback: feedback,
          verdict: verdict,
          reviewerProvider: reviewer.provider
        )
        let delivered = sendAutomatedPrompt(handoffPrompt, to: implementer)
        guard delivered else {
          record.phase = .failed
          record.failureMessage = "Could not deliver review feedback to the implementation session."
          manualState.automatedReviews[branch.id] = record
          didChangeState = true
          continue
        }

        record.feedbackDeliveredAt = Date()
        record.verdict = verdict
        record.phase = verdict == "APPROVED" ? .approved : .feedbackDelivered
        manualState.automatedReviews[branch.id] = record
        didChangeState = true
        continue
      }

      guard eligibleBranchIDs.contains(branch.id),
        manualState.automatedReviews[branch.id] == nil,
        let implementer = branch.primaryImplementer,
        implementer.session.isActive
      else {
        continue
      }

      if status(for: implementer) == nil {
        startMonitoring(implementer)
        continue
      }
      guard isReadyForHandoff(implementer) else { continue }
      didChangeState = beginReview(for: branch, implementer: implementer) || didChangeState
    }

    if didChangeState {
      persistManualState()
    }
  }

  private func beginReview(
    for branch: DetectedBranchWorkflow,
    implementer: DetectedAgentSession
  ) -> Bool {
    guard manualState.automatedReviews[branch.id] == nil else { return false }
    let reviewerProvider: SessionProviderKind =
      implementer.provider == .codex ? .claude : .codex
    let baselineSessionIDs = Set(
      sessionObservations()
        .filter { $0.provider == reviewerProvider }
        .map(observationID)
    )
    let startedAt = Date()
    let prompt = reviewerPrompt(for: branch, implementer: implementer)
    let existingReviewer = branch.reviewerSessions.first {
      $0.provider == reviewerProvider
    }
    let reviewerSessionID: String?
    let reviewerPendingSessionID: UUID?
    let phase: AutomatedReviewPhase
    if let existingReviewer {
      guard sendAutomatedPrompt(prompt, to: existingReviewer) else { return false }
      reviewerSessionID = existingReviewer.id
      reviewerPendingSessionID = nil
      phase = .reviewing
    } else {
      guard
        let launch = startReviewer(for: branch, provider: reviewerProvider, prompt: prompt)
      else {
        return false
      }
      reviewerSessionID = nil
      reviewerPendingSessionID = launch.pendingSessionID
      phase = .reviewerLaunching
    }

    manualState.automatedReviews[branch.id] = AutomatedReviewRecord(
      branchID: branch.id,
      workflowID: workflowID(for: branch),
      repositoryPath: branch.repositoryPath,
      implementerSessionID: implementer.id,
      implementerProvider: implementer.provider,
      reviewerProvider: reviewerProvider,
      reviewerSessionID: reviewerSessionID,
      reviewerPendingSessionID: reviewerPendingSessionID,
      reviewerBaselineSessionIDs: baselineSessionIDs,
      startedAt: startedAt,
      reviewRequestSentAt: startedAt,
      feedbackDeliveredAt: nil,
      phase: phase,
      verdict: nil,
      failureMessage: nil
    )
    if phase == .reviewerLaunching {
      scheduleReviewerLaunchTimeout(branchID: branch.id, startedAt: startedAt)
    }
    return true
  }

  private func isReadyForHandoff(_ assignment: DetectedAgentSession) -> Bool {
    guard status(for: assignment) == .waitingForUser,
      let message = lastAssistantMessage(for: assignment)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    else {
      return false
    }
    return true
  }

  private func assignment(
    withID id: String,
    in branch: DetectedBranchWorkflow
  ) -> DetectedAgentSession? {
    (branch.implementerSessions + branch.reviewerSessions).first { $0.id == id }
  }

  private func sessionsViewModel(
    for provider: SessionProviderKind
  ) -> CLISessionsViewModel? {
    provider == .claude ? claudeSessionsViewModel : codexSessionsViewModel
  }

  private func status(for assignment: DetectedAgentSession) -> SessionStatus? {
    reviewAutomationHooks?.status(assignment)
      ?? sessionsViewModel(for: assignment.provider)?.sessionStatus(for: assignment.session.id)
  }

  private func lastAssistantMessage(for assignment: DetectedAgentSession) -> String? {
    reviewAutomationHooks?.lastAssistantMessage(assignment)
      ?? sessionsViewModel(for: assignment.provider)?.lastAssistantMessage(
        for: assignment.session.id
      )
  }

  private func lastActivityAt(for assignment: DetectedAgentSession) -> Date? {
    reviewAutomationHooks?.lastActivityAt(assignment)
      ?? sessionsViewModel(for: assignment.provider)?.monitorStates[assignment.session.id]?
      .lastActivityAt
  }

  private func startMonitoring(_ assignment: DetectedAgentSession) {
    if let reviewAutomationHooks {
      reviewAutomationHooks.startMonitoring(assignment)
    } else {
      sessionsViewModel(for: assignment.provider)?.startMonitoring(session: assignment.session)
    }
  }

  private func startReviewer(
    for branch: DetectedBranchWorkflow,
    provider: SessionProviderKind,
    prompt: String
  ) -> ReviewerLaunchResult? {
    if let reviewAutomationHooks {
      guard reviewAutomationHooks.startReviewer(branch, provider, prompt) else { return nil }
      return ReviewerLaunchResult(pendingSessionID: nil)
    }
    guard let reviewerViewModel = sessionsViewModel(for: provider) else { return nil }
    let worktree = reviewLaunchTarget(for: branch, in: reviewerViewModel)
    reviewerViewModel.addRepository(at: branch.repositoryPath)
    guard
      let pendingSessionID = reviewerViewModel.startAutomatedSessionInHub(
        worktree,
        initialPrompt: prompt
      )
    else {
      return nil
    }
    return ReviewerLaunchResult(pendingSessionID: pendingSessionID)
  }

  private func sendAutomatedPrompt(
    _ prompt: String,
    to assignment: DetectedAgentSession
  ) -> Bool {
    if let reviewAutomationHooks {
      return reviewAutomationHooks.sendPrompt(assignment, prompt)
    }
    return sessionsViewModel(for: assignment.provider)?
      .sendAutomatedPrompt(to: assignment.session, prompt: prompt) == true
  }

  private func reviewLaunchTarget(
    for branch: DetectedBranchWorkflow,
    in viewModel: CLISessionsViewModel
  ) -> WorktreeBranch {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(branch.repositoryPath)
    return viewModel.selectedRepositories
      .flatMap(\.worktrees)
      .first {
        WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalizedPath
      }
      ?? WorktreeBranch(
        name: branch.branchName ?? branch.repositoryName,
        path: normalizedPath,
        isWorktree: branch.branchName != nil
      )
  }

  private func reviewerPrompt(
    for branch: DetectedBranchWorkflow,
    implementer: DetectedAgentSession
  ) -> String {
    let ticket = branch.ticketKey ?? "unassigned workflow"
    let branchName = branch.branchName ?? "current branch"
    let implementationRequest = implementer.session.firstMessage?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let implementationSummary =
      lastAssistantMessage(for: implementer)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? implementer.session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
    let implementationRequestContext =
      implementationRequest?.isEmpty == false ? implementationRequest ?? "" : "Not recorded"
    let implementationSummaryContext =
      implementationSummary?.isEmpty == false
      ? implementationSummary ?? ""
      : "Not available yet. Review the working tree as it currently exists."
    let pullRequestContext: String
    if let pullRequest = branch.pullRequest {
      pullRequestContext = "#\(pullRequest.number) \(pullRequest.url)"
    } else if !branch.linkedPullRequests.isEmpty {
      pullRequestContext = branch.linkedPullRequests.map(\.url).joined(separator: ", ")
    } else {
      pullRequestContext = "None detected"
    }
    return """
      You are the independent read-only review agent for \(ticket).
      The implementation was produced by \(implementer.provider.rawValue) in session \(implementer.session.id).
      Repository: \(branch.repositoryPath)
      Branch: \(branchName)
      Pull request: \(pullRequestContext)
      Implementation request: \(implementationRequestContext)
      Latest implementation report: \(implementationSummaryContext)

      Review the current working tree and git diff. Inspect correctness, regressions, tests, security, and maintainability. Run read-only checks and tests when useful. Do not edit files, commit, push, or create a pull request.

      Finish with exactly one verdict line:
      AGENTHUB_REVIEW: APPROVED
      or
      AGENTHUB_REVIEW: CHANGES_REQUESTED

      Put concise, actionable findings after the verdict. Include file and line references when possible.
      """
  }

  private func reviewVerdict(in feedback: String) -> String {
    let normalized = feedback.uppercased()
    return normalized.contains("AGENTHUB_REVIEW: APPROVED")
      ? "APPROVED"
      : "CHANGES_REQUESTED"
  }

  private func implementationHandoffPrompt(
    feedback: String,
    verdict: String,
    reviewerProvider: SessionProviderKind
  ) -> String {
    """
    AgentHub received the independent \(reviewerProvider.rawValue) review.
    Verdict: \(verdict)

    \(feedback)

    If changes were requested, address every actionable finding, run the relevant tests, and finish with a concise implementation summary. Do not commit, push, or create a pull request without explicit human approval.
    """
  }

  private func applyManualWorkflowProjection() {
    let validTargetIDs = availableWorkflowIDs
    let validAssignments = manualState.sessionAssignments.filter {
      validTargetIDs.contains($0.value)
    }
    if validAssignments.count != manualState.sessionAssignments.count {
      manualState.sessionAssignments = validAssignments
      persistManualState()
    }

    var projectedBranches = applyingAutomatedReviewRoles(
      to: applyingManualRoleOverrides(to: classifiedBranches)
    )
    var movedSessions: [String: [DetectedAgentSession]] = [:]

    for index in projectedBranches.indices {
      let naturalWorkflowID = workflowID(for: projectedBranches[index])
      let implementers = projectedBranches[index].implementerSessions
      let reviewers = projectedBranches[index].reviewerSessions
      projectedBranches[index].implementerSessions = implementers.filter { assignment in
        guard let targetID = validAssignments[assignment.id], targetID != naturalWorkflowID else {
          return true
        }
        movedSessions[targetID, default: []].append(assignment)
        return false
      }
      projectedBranches[index].reviewerSessions = reviewers.filter { assignment in
        guard let targetID = validAssignments[assignment.id], targetID != naturalWorkflowID else {
          return true
        }
        movedSessions[targetID, default: []].append(assignment)
        return false
      }
    }

    projectedBranches.removeAll {
      $0.manualWorkflowID == nil
        && $0.implementerSessions.isEmpty
        && $0.reviewerSessions.isEmpty
    }

    for workflow in manualState.workflows {
      let assignments = movedSessions.removeValue(forKey: workflow.workflowID) ?? []
      projectedBranches.append(manualBranch(for: workflow, assignments: assignments))
    }

    for (targetWorkflowID, assignments) in movedSessions {
      guard
        let targetIndex = projectedBranches.indices.first(where: {
          workflowID(for: projectedBranches[$0]) == targetWorkflowID
        })
      else {
        continue
      }
      for assignment in assignments {
        append(assignment, to: &projectedBranches[targetIndex])
      }
    }

    detectedBranches = projectedBranches.map { branch in
      var branch = branch
      branch.automatedReview = manualState.automatedReviews[branch.id]
      branch.isArchived = manualState.archivedWorkflowIDs.contains(workflowID(for: branch))
      return branch
    }
  }

  private func applyingAutomatedReviewRoles(
    to branches: [DetectedBranchWorkflow]
  ) -> [DetectedBranchWorkflow] {
    let reviewerIDs = Set(manualState.automatedReviews.values.compactMap(\.reviewerSessionID))
    let implementerIDs = Set(manualState.automatedReviews.values.map(\.implementerSessionID))
    guard !reviewerIDs.isEmpty || !implementerIDs.isEmpty else { return branches }

    return branches.map { branch in
      var branch = branch
      let assignments = branch.implementerSessions + branch.reviewerSessions
      var seenIDs = Set<String>()
      branch.implementerSessions = []
      branch.reviewerSessions = []

      for assignment in assignments where seenIDs.insert(assignment.id).inserted {
        let adjusted: DetectedAgentSession
        if reviewerIDs.contains(assignment.id) {
          adjusted = DetectedAgentSession(
            session: assignment.session,
            provider: assignment.provider,
            role: .reviewer,
            roleConfidence: .high,
            roleReason: "Started by AgentHub as the independent reviewer"
          )
        } else if implementerIDs.contains(assignment.id) {
          adjusted = DetectedAgentSession(
            session: assignment.session,
            provider: assignment.provider,
            role: .implementer,
            roleConfidence: .high,
            roleReason: "Selected by AgentHub as the implementation session"
          )
        } else {
          adjusted = assignment
        }
        append(adjusted, to: &branch)
      }
      return branch
    }
  }

  private func applyingManualRoleOverrides(
    to branches: [DetectedBranchWorkflow]
  ) -> [DetectedBranchWorkflow] {
    guard !manualState.sessionRoleOverrides.isEmpty else { return branches }

    return branches.map { branch in
      var branch = branch
      let assignments = branch.implementerSessions + branch.reviewerSessions
      var seenIDs = Set<String>()
      branch.implementerSessions = []
      branch.reviewerSessions = []

      for assignment in assignments where seenIDs.insert(assignment.id).inserted {
        guard let role = manualState.sessionRoleOverrides[assignment.id] else {
          append(assignment, to: &branch)
          continue
        }
        append(
          DetectedAgentSession(
            session: assignment.session,
            provider: assignment.provider,
            role: role,
            roleConfidence: .high,
            roleReason: "Started manually as the \(role.rawValue)"
          ),
          to: &branch
        )
      }
      return branch
    }
  }

  private func manualBranch(
    for workflow: ManualWorkflowDefinition,
    assignments: [DetectedAgentSession]
  ) -> DetectedBranchWorkflow {
    var branch = DetectedBranchWorkflow(
      id: "\(workflow.workflowID)|branch",
      ticketKey: workflow.name,
      repositoryPath: workflow.repositoryPath,
      repositoryName: URL(fileURLWithPath: workflow.repositoryPath).lastPathComponent,
      branchName: workflow.branchName,
      implementerSessions: [],
      reviewerSessions: [],
      linkedPullRequests: [],
      pullRequest: nil,
      lastActivityAt: assignments.map(\.session.lastActivityAt).max() ?? workflow.createdAt,
      manualWorkflowID: workflow.workflowID
    )
    for assignment in assignments {
      append(assignment, to: &branch)
    }
    return branch
  }

  private func append(
    _ assignment: DetectedAgentSession,
    to branch: inout DetectedBranchWorkflow
  ) {
    if assignment.role == .reviewer {
      if !branch.reviewerSessions.contains(where: { $0.id == assignment.id }) {
        branch.reviewerSessions.append(assignment)
      }
    } else if !branch.implementerSessions.contains(where: { $0.id == assignment.id }) {
      branch.implementerSessions.append(assignment)
    }
  }

  private func workflowID(for branch: DetectedBranchWorkflow) -> String {
    branch.manualWorkflowID ?? branch.ticketKey ?? "unassigned:\(branch.repositoryPath)"
  }

  private func branches(
    _ branches: [DetectedBranchWorkflow],
    removingSessionID sessionID: String
  ) -> [DetectedBranchWorkflow] {
    branches.compactMap { branch in
      var branch = branch
      branch.implementerSessions.removeAll { $0.id == sessionID }
      branch.reviewerSessions.removeAll { $0.id == sessionID }
      guard
        branch.manualWorkflowID != nil
          || !branch.implementerSessions.isEmpty
          || !branch.reviewerSessions.isEmpty
      else {
        return nil
      }
      return branch
    }
  }

  private func observations(
    from viewModel: CLISessionsViewModel?,
    provider: SessionProviderKind
  ) -> [AgentSessionObservation] {
    guard let viewModel else { return [] }
    var seenSessionIDs = Set<String>()
    var result: [AgentSessionObservation] = []

    for repository in viewModel.selectedRepositories {
      for worktree in repository.worktrees {
        for session in worktree.sessions where seenSessionIDs.insert(session.id).inserted {
          let detectedLinks = AgentSessionWorkflowClassifier.pullRequestReferences(
            in: [session.firstMessage, session.lastMessage]
          )
          let linkedPullRequests = Array(
            Set(viewModel.pullRequestReferences(for: session.id) + detectedLinks)
          ).sorted { $0.number < $1.number }
          let repositoryPath = workflowRepositoryPath(
            session: session,
            selectedRepository: repository,
            worktree: worktree
          )
          result.append(
            AgentSessionObservation(
              session: session,
              provider: provider,
              repositoryPath: repositoryPath,
              branchName: session.branchName ?? (worktree.isWorktree ? worktree.name : nil),
              linkedPullRequests: linkedPullRequests
            )
          )
        }
      }
    }
    return result
  }

  private func workflowRepositoryPath(
    session: CLISession,
    selectedRepository: SelectedRepository,
    worktree: WorktreeBranch
  ) -> String {
    let selectedPath = WorktreeModuleResolver.normalizedDirectoryPath(selectedRepository.path)
    let gitMarker = URL(fileURLWithPath: selectedPath, isDirectory: true)
      .appendingPathComponent(".git").path
    if FileManager.default.fileExists(atPath: gitMarker) {
      return selectedPath
    }
    if worktree.isWorktree {
      return WorktreeModuleResolver.normalizedDirectoryPath(worktree.path)
    }
    return WorktreeModuleResolver.normalizedDirectoryPath(session.projectPath)
  }

  private func observationID(_ observation: AgentSessionObservation) -> String {
    "\(observation.provider.rawValue.lowercased()):\(observation.session.id)"
  }

  private func resolvingPullRequests(
    for branches: [DetectedBranchWorkflow],
    forceRefresh: Bool
  ) async -> [DetectedBranchWorkflow] {
    guard let gitHubService else { return branches }
    var resolved = branches
    let now = Date()
    var pending: [PullRequestLookup] = []
    var failedLookupCount = 0

    for index in resolved.indices {
      let branch = resolved[index]
      guard let lookupKey = pullRequestLookupKey(for: branch) else { continue }

      if !forceRefresh,
        let cached = pullRequestCache[lookupKey],
        now.timeIntervalSince(cached.fetchedAt) < 120
      {
        if cached.failed {
          failedLookupCount += 1
        }
        apply(cached.pullRequest, to: &resolved[index])
      } else {
        pending.append(
          PullRequestLookup(
            index: index,
            key: lookupKey,
            branch: branch
          )
        )
      }
    }

    let maximumConcurrentLookups = 6
    for startIndex in stride(from: 0, to: pending.count, by: maximumConcurrentLookups) {
      guard !Task.isCancelled else { return resolved }
      let endIndex = min(startIndex + maximumConcurrentLookups, pending.count)
      let batch = Array(pending[startIndex..<endIndex])
      let results = await withTaskGroup(
        of: PullRequestLookupResult.self,
        returning: [PullRequestLookupResult].self
      ) { group in
        for request in batch {
          group.addTask {
            let pullRequest: DetectedPullRequest?
            let errorMessage: String?
            do {
              let githubPullRequest: GitHubPullRequest?
              if let linked = request.branch.linkedPullRequests.last {
                githubPullRequest = try await gitHubService.getPullRequest(
                  number: linked.number,
                  at: request.branch.repositoryPath
                )
              } else {
                githubPullRequest = try await gitHubService.getCurrentBranchPR(
                  branchName: request.branch.branchName,
                  at: request.branch.repositoryPath
                )
              }
              pullRequest = githubPullRequest.map(DetectedPullRequest.init)
              errorMessage = nil
            } catch {
              pullRequest = nil
              errorMessage = error.localizedDescription
            }
            return PullRequestLookupResult(
              index: request.index,
              key: request.key,
              pullRequest: pullRequest,
              errorMessage: errorMessage
            )
          }
        }

        var batchResults: [PullRequestLookupResult] = []
        for await result in group {
          batchResults.append(result)
        }
        return batchResults
      }

      for result in results {
        if result.errorMessage != nil {
          failedLookupCount += 1
        }
        pullRequestCache[result.key] = CachedPullRequest(
          pullRequest: result.pullRequest,
          fetchedAt: now,
          failed: result.errorMessage != nil
        )
        apply(result.pullRequest, to: &resolved[result.index])
      }
    }
    pullRequestWarning =
      failedLookupCount > 0
      ? "PR status unavailable for \(failedLookupCount) \(failedLookupCount == 1 ? "branch" : "branches"). Check GitHub CLI authentication."
      : nil
    return resolved
  }

  private func apply(
    _ pullRequest: DetectedPullRequest?,
    to branch: inout DetectedBranchWorkflow
  ) {
    branch.pullRequest = pullRequest
    if branch.ticketKey == nil, let pullRequest {
      branch.ticketKey = AgentSessionWorkflowClassifier.ticketKey(
        in: [pullRequest.headBranch, pullRequest.title]
      )
    }
  }

  private func pullRequestLookupKey(for branch: DetectedBranchWorkflow) -> String? {
    if let linked = branch.linkedPullRequests.last {
      return "\(branch.repositoryPath)|pr:\(linked.number)"
    }
    guard let branchName = branch.branchName, !branchName.isEmpty else { return nil }
    return "\(branch.repositoryPath)|branch:\(branchName)"
  }

  private func mergeBranchesSharingPullRequest(
    _ branches: [DetectedBranchWorkflow]
  ) -> [DetectedBranchWorkflow] {
    let grouped = Dictionary(grouping: branches) { branch in
      if let pullRequest = branch.pullRequest {
        return "\(branch.repositoryPath)|pr:\(pullRequest.number)"
      }
      return "branch:\(branch.id)"
    }

    return grouped.values.map { matches in
      guard let first = matches.first, matches.count > 1 else {
        return matches[0]
      }
      let pullRequest = matches.compactMap(\.pullRequest).first
      let ticketKey =
        matches.compactMap(\.ticketKey).first
        ?? AgentSessionWorkflowClassifier.ticketKey(
          in: [pullRequest?.headBranch, pullRequest?.title]
        )
      let implementers = uniqueAssignments(matches.flatMap(\.implementerSessions))
      let reviewers = uniqueAssignments(matches.flatMap(\.reviewerSessions))
      let links = Array(Set(matches.flatMap(\.linkedPullRequests)))
        .sorted { $0.number < $1.number }

      return DetectedBranchWorkflow(
        id: pullRequest.map { "\(first.repositoryPath)|pr:\($0.number)" } ?? first.id,
        ticketKey: ticketKey,
        repositoryPath: first.repositoryPath,
        repositoryName: first.repositoryName,
        branchName: pullRequest?.headBranch ?? first.branchName,
        implementerSessions: implementers,
        reviewerSessions: reviewers,
        linkedPullRequests: links,
        pullRequest: pullRequest,
        lastActivityAt: matches.map(\.lastActivityAt).max() ?? first.lastActivityAt
      )
    }
    .sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  private func uniqueAssignments(
    _ assignments: [DetectedAgentSession]
  ) -> [DetectedAgentSession] {
    var seen = Set<String>()
    return
      assignments
      .sorted {
        if $0.session.isActive != $1.session.isActive {
          return $0.session.isActive
        }
        return $0.session.lastActivityAt > $1.session.lastActivityAt
      }
      .filter { seen.insert($0.id).inserted }
  }

  private func observationSort(
    _ lhs: AgentSessionObservation,
    _ rhs: AgentSessionObservation
  ) -> Bool {
    if lhs.provider.rawValue != rhs.provider.rawValue {
      return lhs.provider.rawValue < rhs.provider.rawValue
    }
    return lhs.session.id < rhs.session.id
  }

  private func analysisObservationSort(
    _ lhs: AgentSessionObservation,
    _ rhs: AgentSessionObservation
  ) -> Bool {
    if lhs.session.lastActivityAt != rhs.session.lastActivityAt {
      return lhs.session.lastActivityAt > rhs.session.lastActivityAt
    }
    return observationSort(lhs, rhs)
  }

  private func repairDetectedSelection() {
    let workflows = displayedWorkflows
    guard !workflows.isEmpty else {
      selectedWorkflowID = nil
      selectedDetectedBranchID = nil
      return
    }

    if !workflows.contains(where: { $0.id == selectedWorkflowID }) {
      selectedWorkflowID = workflows.first?.id
    }
    guard let workflow = selectedDetectedWorkflow else { return }
    if !workflow.branches.contains(where: { $0.id == selectedDetectedBranchID }) {
      selectedDetectedBranchID = workflow.branches.first?.id
    }
  }
}
