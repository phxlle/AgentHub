import AgentHubSessionGraph
import AgentWorkflowCore
import AgentWorkflowJiraCLI
import Foundation

public protocol AgentWorkflowRuntimeProtocol: Sendable {
  func startTicketFromJira(
    key: String,
    coordinatorProvider: SessionProviderKind
  ) async throws -> TicketRun
  func tickets() async throws -> [TicketRun]
  func branches(ticketRunID: UUID) async throws -> [BranchRun]
}

/// Thin AgentHub integration boundary around the provider-neutral workflow store.
/// Provider launchers and UI models depend on this runtime, never on database details.
public actor AgentWorkflowRuntime: AgentWorkflowRuntimeProtocol {
  private let store: any AgentWorkflowStoreProtocol
  private let jiraReader: any JiraTicketReading

  public init(
    store: any AgentWorkflowStoreProtocol,
    jiraReader: any JiraTicketReading = ACLITicketReader()
  ) {
    self.store = store
    self.jiraReader = jiraReader
  }

  public init() throws {
    store = try AgentWorkflowStore()
    jiraReader = ACLITicketReader()
  }

  public func startTicket(
    key: String,
    summary: String? = nil,
    coordinatorProvider: SessionProviderKind
  ) async throws -> TicketRun {
    try await store.createTicketRun(
      ticketKey: key,
      summary: summary,
      coordinatorProvider: coordinatorProvider.workflowProviderID
    )
  }

  public func tickets() async throws -> [TicketRun] {
    try await store.ticketRuns()
  }

  public func startTicketFromJira(
    key: String,
    coordinatorProvider: SessionProviderKind
  ) async throws -> TicketRun {
    let snapshot = try await jiraReader.ticket(key: key)
    return try await startTicket(
      key: snapshot.key,
      summary: snapshot.summary,
      coordinatorProvider: coordinatorProvider
    )
  }

  public func branches(ticketRunID: UUID) async throws -> [BranchRun] {
    try await store.branchRuns(ticketRunID: ticketRunID)
  }
}

extension SessionProviderKind {
  fileprivate var workflowProviderID: AgentProviderID {
    switch self {
    case .codex: .codex
    case .claude: .claude
    }
  }
}
