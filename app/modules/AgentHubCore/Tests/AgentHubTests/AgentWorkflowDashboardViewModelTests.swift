import AgentWorkflowCore
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Agent workflow dashboard view model")
@MainActor
struct AgentWorkflowDashboardViewModelTests {
  @Test("Loading workflows requests the local session inventory")
  func loadingWorkflowsRequestsSessionInventory() async {
    var inventoryLoadCount = 0
    let viewModel = AgentWorkflowDashboardViewModel(
      sessionInventoryLoader: {
        inventoryLoadCount += 1
      },
      sessionObservationSource: { [] }
    )

    await viewModel.load()
    await viewModel.load()

    #expect(inventoryLoadCount == 1)
  }

  @Test("Loading selects the newest ticket and its first branch")
  func loadSelectsFirstWorkflow() async throws {
    let ticket = try TicketRun(
      ticketKey: "XFA-3299",
      summary: "MFA confirmation",
      coordinatorProvider: .codex
    )
    let branch = try BranchRun(
      ticketRunID: ticket.id,
      repositoryPath: "/repos/api",
      worktreePath: "/worktrees/xfa-3299",
      branchName: "XFA-3299-mfa",
      baseBranch: "main",
      implementerProvider: .codex,
      reviewerProvider: .claude
    )
    let runtime = MockAgentWorkflowRuntime(tickets: [ticket], branches: [ticket.id: [branch]])
    let viewModel = AgentWorkflowDashboardViewModel(runtime: runtime)

    await viewModel.load()

    #expect(viewModel.selectedTicketID == ticket.id)
    #expect(viewModel.selectedBranchID == branch.id)
    #expect(viewModel.branches == [branch])
  }

  @Test("Starting a Jira ticket normalizes the key and selects the new workflow")
  func startTicketSelectsNewWorkflow() async throws {
    let runtime = MockAgentWorkflowRuntime()
    let viewModel = AgentWorkflowDashboardViewModel(runtime: runtime)
    viewModel.ticketKey = " xfa-3299 "
    viewModel.coordinatorProvider = .claude

    await viewModel.startTicket()
    let requests = await runtime.startRequests

    #expect(requests == [StartRequest(key: "XFA-3299", provider: .claude)])
    #expect(viewModel.tickets.first?.ticketKey == "XFA-3299")
    #expect(viewModel.selectedTicketID == viewModel.tickets.first?.id)
    #expect(viewModel.ticketKey.isEmpty)
  }

  @Test("Session discovery analyzes ten most recent sessions per user action")
  func sessionDiscoveryUsesManualBatchesOfTen() async {
    let observations = (0..<25).map { index in
      workflowObservation(index: index)
    }
    let viewModel = AgentWorkflowDashboardViewModel {
      observations
    }

    await viewModel.refreshDetectedWorkflows()

    #expect(viewModel.analyzedSessionCount == 10)
    #expect(viewModel.totalSessionCount == 25)
    #expect(viewModel.remainingSessionCount == 15)
    #expect(viewModel.nextSessionBatchCount == 10)
    #expect(viewModel.detectedBranches.count == 10)
    #expect(Set(viewModel.detectedBranches.compactMap(\.ticketKey)) == sessionKeys(15..<25))

    await viewModel.analyzeNextSessionBatch()

    #expect(viewModel.analyzedSessionCount == 20)
    #expect(viewModel.remainingSessionCount == 5)
    #expect(viewModel.nextSessionBatchCount == 5)
    #expect(viewModel.detectedBranches.count == 20)

    await viewModel.analyzeNextSessionBatch()

    #expect(viewModel.analyzedSessionCount == 25)
    #expect(viewModel.remainingSessionCount == 0)
    #expect(!viewModel.canAnalyzeNextSessionBatch)
    #expect(viewModel.detectedBranches.count == 25)
  }

  @Test("Manual workflows persist moved sessions and can dismiss them")
  func manualWorkflowSessionManagementPersists() async {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let observations = [workflowObservation(index: 1), workflowObservation(index: 2)]
    let viewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }
    await viewModel.refreshDetectedWorkflows()

    let workflowID = viewModel.createManualWorkflow(
      name: "Manual investigation",
      repositoryPath: "/repos/project"
    )
    #expect(workflowID != nil)
    guard let workflowID else { return }

    await viewModel.moveSession("claude:session-1", to: workflowID)

    let manualWorkflow = viewModel.displayedWorkflows.first { $0.id == workflowID }
    let manualSessionIDs = Set(
      manualWorkflow?.branches.flatMap { $0.implementerSessions + $0.reviewerSessions }.map(\.id)
        ?? []
    )
    #expect(manualSessionIDs == Set(["claude:session-1"]))

    let restoredViewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }
    await restoredViewModel.refreshDetectedWorkflows()
    #expect(restoredViewModel.displayedWorkflows.contains { $0.id == workflowID })
    #expect(restoredViewModel.hasSessionWorkflowOverride("claude:session-1"))

    restoredViewModel.dismissSession("claude:session-1")

    #expect(restoredViewModel.analyzedSessionCount == 1)
    #expect(
      !restoredViewModel.detectedBranches
        .flatMap { $0.implementerSessions + $0.reviewerSessions }
        .contains { $0.id == "claude:session-1" }
    )
  }

  @Test("The session library exposes unanalyzed sessions and dropping one promotes it")
  func sessionLibraryCanAssignAnUnanalyzedSession() async {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let observations = (0..<25).map { workflowObservation(index: $0) }
    let viewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }

    await viewModel.refreshDetectedWorkflows()
    #expect(viewModel.sessionLibraryItems.count == 25)
    #expect(
      viewModel.sessionLibraryItems.first { $0.id == "codex:session-0" }?.isAnalyzed == false
    )

    let workflowID = viewModel.createManualWorkflow(
      name: "Manual investigation",
      repositoryPath: "/repos/project"
    )
    guard let workflowID else { return }

    await viewModel.moveSession("codex:session-0", to: workflowID)

    #expect(viewModel.analyzedSessionCount == 11)
    #expect(
      viewModel.sessionLibraryItems.first { $0.id == "codex:session-0" }?.workflowTitle
        == "Manual investigation"
    )
    #expect(
      viewModel.displayedWorkflows.first { $0.id == workflowID }?.branches
        .flatMap { $0.implementerSessions + $0.reviewerSessions }
        .contains { $0.id == "codex:session-0" } == true
    )
  }

  @Test("All sessions in a workflow can be closed together")
  func closeAllWorkflowSessions() async throws {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let observations = [workflowObservation(index: 1), workflowObservation(index: 2)]
    let viewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }
    await viewModel.refreshDetectedWorkflows()
    let workflowID = try #require(
      viewModel.createManualWorkflow(
        name: "Close together",
        repositoryPath: "/repos/project"
      )
    )
    await viewModel.moveSession("claude:session-1", to: workflowID)
    await viewModel.moveSession("codex:session-2", to: workflowID)

    viewModel.dismissSessions(["claude:session-1", "codex:session-2"])

    let workflow = try #require(viewModel.displayedWorkflows.first { $0.id == workflowID })
    #expect(
      workflow.branches.flatMap { $0.implementerSessions + $0.reviewerSessions }.isEmpty
    )
    #expect(viewModel.sessionLibraryItems.isEmpty)

    let restoredViewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }
    await restoredViewModel.refreshDetectedWorkflows()
    #expect(restoredViewModel.sessionLibraryItems.isEmpty)
  }

  @Test("A session started from a manual workflow is assigned when it appears")
  func startedSessionJoinsManualWorkflow() async {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var observations = [workflowObservation(index: 0)]
    let viewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }
    await viewModel.refreshDetectedWorkflows()
    guard
      let workflowID = viewModel.createManualWorkflow(
        name: "Manual investigation",
        repositoryPath: "/repos/project"
      )
    else {
      return
    }

    let launch = viewModel.prepareManualSessionLaunch(
      workflowID: workflowID,
      provider: .codex
    )
    #expect(launch?.workflowID == workflowID)

    observations.append(workflowObservation(index: 2, lastActivityAt: Date()))
    await viewModel.refreshDetectedWorkflows()

    #expect(viewModel.hasSessionWorkflowOverride("codex:session-2"))
    let manualWorkflow = viewModel.displayedWorkflows.first { $0.id == workflowID }
    #expect(
      manualWorkflow?.branches
        .flatMap { $0.implementerSessions + $0.reviewerSessions }
        .contains { $0.id == "codex:session-2" } == true
    )
  }

  @Test("A workflow can be archived, restored, and recovered after relaunch")
  func workflowArchivePersistsAndRestores() async throws {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let observations = [workflowObservation(index: 4)]
    let viewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }
    await viewModel.refreshDetectedWorkflows()
    let workflowID = try #require(viewModel.displayedWorkflows.first?.id)

    viewModel.archiveWorkflow(workflowID)

    #expect(viewModel.activeWorkflowCount == 0)
    #expect(viewModel.completedWorkflowCount == 1)
    viewModel.changeScope(.completed)
    #expect(viewModel.displayedWorkflows.first?.isArchived == true)

    let restoredViewModel = AgentWorkflowDashboardViewModel(userDefaults: defaults) {
      observations
    }
    await restoredViewModel.refreshDetectedWorkflows()
    restoredViewModel.changeScope(.completed)
    #expect(restoredViewModel.displayedWorkflows.first?.id == workflowID)
    #expect(restoredViewModel.displayedWorkflows.first?.isArchived == true)

    restoredViewModel.restoreWorkflow(workflowID)

    #expect(restoredViewModel.completedWorkflowCount == 0)
    #expect(restoredViewModel.activeWorkflowCount == 1)
  }

  @Test("A reviewer can be created explicitly only after an implementer exists")
  func explicitReviewerRequiresImplementerAndReceivesContext() async throws {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let observation = workflowObservation(index: 5)
    let recorder = AgentWorkflowReviewAutomationRecorder()
    recorder.messages["claude:session-5"] = "Implemented the requested workflow behavior."
    let viewModel = AgentWorkflowDashboardViewModel(
      userDefaults: defaults,
      reviewAutomationHooks: recorder.hooks
    ) {
      [observation]
    }
    await viewModel.refreshDetectedWorkflows()
    let emptyWorkflowID = try #require(
      viewModel.createManualWorkflow(
        name: "Empty workflow",
        repositoryPath: "/repos/project"
      )
    )
    let emptyBranchID = try #require(
      viewModel.displayedWorkflows.first { $0.id == emptyWorkflowID }?.branches.first?.id
    )

    #expect(!viewModel.createReviewAgent(for: emptyBranchID))
    #expect(recorder.reviewerLaunches.isEmpty)

    await viewModel.moveSession("claude:session-5", to: emptyWorkflowID)
    let implementationBranchID = try #require(
      viewModel.displayedWorkflows.first { $0.id == emptyWorkflowID }?.branches.first?.id
    )

    #expect(viewModel.createReviewAgent(for: implementationBranchID))
    let launch = try #require(recorder.reviewerLaunches.first)
    #expect(launch.provider == .codex)
    #expect(launch.prompt.contains("Empty workflow"))
    #expect(launch.prompt.contains("Repository: /repos/project"))
    #expect(launch.prompt.contains("session session-5"))
    #expect(launch.prompt.contains("Implementation request: Implement XFA-1005"))
    #expect(launch.prompt.contains("Implemented the requested workflow behavior."))
    #expect(launch.prompt.contains("Review the current working tree and git diff."))
    #expect(
      viewModel.detectedBranches.first { $0.id == implementationBranchID }?.automatedReview?.phase
        == .reviewerLaunching
    )
  }

  @Test("A completed Codex turn starts Claude review and returns its feedback")
  func completedImplementationStartsCrossProviderReview() async throws {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let branchName = "XFA-7000-cross-provider-review"
    let implementer = AgentSessionObservation(
      session: CLISession(
        id: "implementation-session",
        projectPath: "/repos/project",
        branchName: branchName,
        lastActivityAt: Date(),
        isActive: true,
        firstMessage: "Implement XFA-7000"
      ),
      provider: .codex,
      repositoryPath: "/repos/project",
      branchName: branchName,
      linkedPullRequests: []
    )
    var observations = [implementer]
    let recorder = AgentWorkflowReviewAutomationRecorder()
    recorder.statuses["codex:implementation-session"] = .waitingForUser
    recorder.messages["codex:implementation-session"] = "Implementation complete."
    recorder.activityDates["codex:implementation-session"] = Date()

    let viewModel = AgentWorkflowDashboardViewModel(
      userDefaults: defaults,
      reviewAutomationHooks: recorder.hooks
    ) {
      observations
    }

    await viewModel.refreshDetectedWorkflows()

    let launch = try #require(recorder.reviewerLaunches.first)
    #expect(launch.provider == .claude)
    #expect(launch.prompt.contains("independent read-only review agent"))
    #expect(launch.prompt.contains("AGENTHUB_REVIEW: CHANGES_REQUESTED"))
    #expect(viewModel.detectedBranches.first?.automatedReview?.phase == .reviewerLaunching)

    let reviewer = AgentSessionObservation(
      session: CLISession(
        id: "review-session",
        projectPath: "/repos/project",
        branchName: branchName,
        lastActivityAt: Date().addingTimeInterval(60),
        isActive: true,
        firstMessage: "Review XFA-7000 independently"
      ),
      provider: .claude,
      repositoryPath: "/repos/project",
      branchName: branchName,
      linkedPullRequests: []
    )
    observations.append(reviewer)
    recorder.statuses["claude:review-session"] = .waitingForUser
    recorder.messages["claude:review-session"] = """
      AGENTHUB_REVIEW: CHANGES_REQUESTED
      Fix the missing regression test.
      """
    recorder.activityDates["claude:review-session"] = Date().addingTimeInterval(60)

    await viewModel.refreshDetectedWorkflows()

    let handoff = try #require(recorder.sentPrompts.first)
    #expect(handoff.assignmentID == "codex:implementation-session")
    #expect(handoff.prompt.contains("Fix the missing regression test."))
    #expect(handoff.prompt.contains("Verdict: CHANGES_REQUESTED"))
    #expect(viewModel.detectedBranches.first?.automatedReview?.phase == .feedbackDelivered)
  }

  @Test("A reviewer launch times out and can be retried")
  func reviewerLaunchTimeoutCanRetry() async throws {
    let suiteName = "AgentWorkflowDashboardViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let branchName = "XFA-7001-review-timeout"
    let observation = AgentSessionObservation(
      session: CLISession(
        id: "implementation-session",
        projectPath: "/repos/project",
        branchName: branchName,
        lastActivityAt: Date(),
        isActive: true,
        firstMessage: "Implement XFA-7001"
      ),
      provider: .codex,
      repositoryPath: "/repos/project",
      branchName: branchName,
      linkedPullRequests: []
    )
    let recorder = AgentWorkflowReviewAutomationRecorder()
    recorder.statuses["codex:implementation-session"] = .waitingForUser
    recorder.messages["codex:implementation-session"] = "Implementation complete."
    recorder.activityDates["codex:implementation-session"] = Date()
    let viewModel = AgentWorkflowDashboardViewModel(
      userDefaults: defaults,
      reviewAutomationHooks: recorder.hooks,
      reviewerLaunchTimeout: 0.01
    ) {
      [observation]
    }

    await viewModel.refreshDetectedWorkflows()
    try await Task.sleep(for: .milliseconds(30))

    let failedBranch = try #require(viewModel.detectedBranches.first)
    #expect(failedBranch.automatedReview?.phase == .failed)
    #expect(failedBranch.automatedReview?.failureMessage != nil)
    #expect(recorder.reviewerLaunches.count == 1)

    viewModel.retryAutomatedReview(for: failedBranch.id)

    #expect(recorder.reviewerLaunches.count == 2)
    #expect(viewModel.detectedBranches.first?.automatedReview?.phase == .reviewerLaunching)
  }

  private func workflowObservation(
    index: Int,
    lastActivityAt: Date? = nil
  ) -> AgentSessionObservation {
    let ticketKey = "XFA-\(1_000 + index)"
    let branchName = "\(ticketKey)-batch-test"
    return AgentSessionObservation(
      session: CLISession(
        id: "session-\(index)",
        projectPath: "/repos/project",
        branchName: branchName,
        lastActivityAt: lastActivityAt ?? Date(timeIntervalSince1970: TimeInterval(index)),
        firstMessage: "Implement \(ticketKey)"
      ),
      provider: index.isMultiple(of: 2) ? .codex : .claude,
      repositoryPath: "/repos/project",
      branchName: branchName,
      linkedPullRequests: []
    )
  }

  private func sessionKeys(_ range: Range<Int>) -> Set<String> {
    Set(range.map { "XFA-\(1_000 + $0)" })
  }
}

@MainActor
private final class AgentWorkflowReviewAutomationRecorder {
  struct ReviewerLaunch {
    let provider: SessionProviderKind
    let prompt: String
  }

  struct SentPrompt {
    let assignmentID: String
    let prompt: String
  }

  var statuses: [String: SessionStatus] = [:]
  var messages: [String: String] = [:]
  var activityDates: [String: Date] = [:]
  var reviewerLaunches: [ReviewerLaunch] = []
  var sentPrompts: [SentPrompt] = []

  var hooks: AgentWorkflowReviewAutomationHooks {
    AgentWorkflowReviewAutomationHooks(
      status: { [unowned self] assignment in statuses[assignment.id] },
      lastAssistantMessage: { [unowned self] assignment in messages[assignment.id] },
      lastActivityAt: { [unowned self] assignment in activityDates[assignment.id] },
      startMonitoring: { _ in },
      startReviewer: { [unowned self] _, provider, prompt in
        reviewerLaunches.append(ReviewerLaunch(provider: provider, prompt: prompt))
        return true
      },
      sendPrompt: { [unowned self] assignment, prompt in
        sentPrompts.append(SentPrompt(assignmentID: assignment.id, prompt: prompt))
        return true
      }
    )
  }
}

private struct StartRequest: Equatable, Sendable {
  let key: String
  let provider: SessionProviderKind
}

private actor MockAgentWorkflowRuntime: AgentWorkflowRuntimeProtocol {
  private let storedTickets: [TicketRun]
  private let storedBranches: [UUID: [BranchRun]]
  private(set) var startRequests: [StartRequest] = []

  init(
    tickets: [TicketRun] = [],
    branches: [UUID: [BranchRun]] = [:]
  ) {
    storedTickets = tickets
    storedBranches = branches
  }

  func startTicketFromJira(
    key: String,
    coordinatorProvider: SessionProviderKind
  ) async throws -> TicketRun {
    startRequests.append(StartRequest(key: key, provider: coordinatorProvider))
    return try TicketRun(
      ticketKey: key,
      summary: "Loaded from Jira",
      coordinatorProvider: coordinatorProvider == .codex ? .codex : .claude
    )
  }

  func tickets() async throws -> [TicketRun] {
    storedTickets
  }

  func branches(ticketRunID: UUID) async throws -> [BranchRun] {
    storedBranches[ticketRunID, default: []]
  }
}
