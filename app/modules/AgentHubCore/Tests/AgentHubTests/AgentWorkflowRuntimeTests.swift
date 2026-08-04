import AgentWorkflowCore
import AgentWorkflowJiraCLI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Agent workflow runtime")
struct AgentWorkflowRuntimeTests {
  @Test("Starting a ticket maps the AgentHub provider into the workflow domain")
  func startTicketMapsProvider() async throws {
    let store = MockAgentWorkflowStore()
    let runtime = AgentWorkflowRuntime(store: store)

    let ticket = try await runtime.startTicket(
      key: "xfa-3299",
      summary: "MFA confirmation",
      coordinatorProvider: .codex
    )
    let createdTicketKeys = await store.createdTicketKeys

    #expect(ticket.ticketKey == "XFA-3299")
    #expect(ticket.coordinator.provider == AgentProviderID.codex)
    #expect(createdTicketKeys == ["xfa-3299"])
  }

  @Test("Starting from Jira uses the read-only ticket snapshot")
  func startTicketFromJira() async throws {
    let store = MockAgentWorkflowStore()
    let jiraReader = MockJiraTicketReader(
      snapshot: JiraTicketSnapshot(
        key: "XFA-3299",
        summary: "MFA confirmation"
      ))
    let runtime = AgentWorkflowRuntime(store: store, jiraReader: jiraReader)

    let ticket = try await runtime.startTicketFromJira(
      key: "XFA-3299",
      coordinatorProvider: .codex
    )
    let requestedKeys = await jiraReader.requestedKeys

    #expect(ticket.ticketKey == "XFA-3299")
    #expect(ticket.summary == "MFA confirmation")
    #expect(requestedKeys == ["XFA-3299"])
  }
}

private actor MockJiraTicketReader: JiraTicketReading {
  private(set) var requestedKeys: [String] = []
  private let snapshot: JiraTicketSnapshot

  init(snapshot: JiraTicketSnapshot) {
    self.snapshot = snapshot
  }

  func ticket(key: String) async throws -> JiraTicketSnapshot {
    requestedKeys.append(key)
    return snapshot
  }
}

private actor MockAgentWorkflowStore: AgentWorkflowStoreProtocol {
  private(set) var createdTicketKeys: [String] = []

  func createTicketRun(
    ticketKey: String,
    summary: String?,
    coordinatorProvider: AgentProviderID
  ) async throws -> TicketRun {
    createdTicketKeys.append(ticketKey)
    return try TicketRun(
      ticketKey: ticketKey,
      summary: summary,
      coordinatorProvider: coordinatorProvider
    )
  }

  func ticketRuns() async throws -> [TicketRun] { [] }

  func createBranchRun(
    ticketRunID: UUID,
    repositoryPath: String,
    worktreePath: String,
    branchName: String,
    baseBranch: String,
    implementerProvider: AgentProviderID,
    reviewerProvider: AgentProviderID
  ) async throws -> BranchRun {
    try BranchRun(
      ticketRunID: ticketRunID,
      repositoryPath: repositoryPath,
      worktreePath: worktreePath,
      branchName: branchName,
      baseBranch: baseBranch,
      implementerProvider: implementerProvider,
      reviewerProvider: reviewerProvider
    )
  }

  func branchRuns(ticketRunID: UUID) async throws -> [BranchRun] { [] }
  func branchRun(id: UUID) async throws -> BranchRun? { nil }

  func apply(
    _ command: BranchWorkflowCommand,
    to branchRunID: UUID,
    at date: Date
  ) async throws -> BranchRun {
    throw AgentWorkflowError.branchRunNotFound(branchRunID)
  }

  func requestApproval(
    branchRunID: UUID,
    action: ApprovalAction,
    at date: Date
  ) async throws -> ApprovalRequest {
    throw AgentWorkflowError.branchRunNotFound(branchRunID)
  }

  func decideApproval(
    id: UUID,
    approved: Bool,
    at date: Date
  ) async throws -> ApprovalRequest {
    throw AgentWorkflowError.approvalRequestNotFound(id)
  }

  func approvalRequests(branchRunID: UUID) async throws -> [ApprovalRequest] { [] }
  func events(ticketRunID: UUID) async throws -> [WorkflowEvent] { [] }
}
