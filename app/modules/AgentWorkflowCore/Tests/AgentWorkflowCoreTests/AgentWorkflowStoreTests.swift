import Foundation
import Testing

@testable import AgentWorkflowCore

@Suite("Agent workflow persistence")
struct AgentWorkflowStoreTests {
  @Test("Ticket, branch roles, events, and state survive a store restart")
  func persistenceRoundTrip() async throws {
    let path = temporaryDatabasePath()
    let firstStore = try AgentWorkflowStore(path: path)
    let ticket = try await firstStore.createTicketRun(
      ticketKey: "xfa-3299",
      summary: "MFA confirmation",
      coordinatorProvider: .codex
    )
    let branch = try await firstStore.createBranchRun(
      ticketRunID: ticket.id,
      repositoryPath: "/repos/api",
      worktreePath: "/worktrees/api-XFA-3299",
      branchName: "XFA-3299-mfa",
      baseBranch: "main",
      implementerProvider: .codex,
      reviewerProvider: .claude
    )
    _ = try await firstStore.apply(.startImplementation, to: branch.id)

    let secondStore = try AgentWorkflowStore(path: path)
    let restoredTickets = try await secondStore.ticketRuns()
    let restoredBranches = try await secondStore.branchRuns(ticketRunID: ticket.id)
    let events = try await secondStore.events(ticketRunID: ticket.id)

    #expect(restoredTickets.map(\.ticketKey) == ["XFA-3299"])
    #expect(restoredBranches.first?.status == BranchRunStatus.implementing)
    #expect(restoredBranches.first?.implementer.provider == AgentProviderID.codex)
    #expect(restoredBranches.first?.reviewer.provider == AgentProviderID.claude)
    #expect(events.map(\.kind) == ["ticket.created", "branch.created", "implementation.started"])
  }

  @Test("Database rejects a second workflow for the same ticket branch")
  func uniqueBranchLease() async throws {
    let store = try AgentWorkflowStore(path: temporaryDatabasePath())
    let ticket = try await store.createTicketRun(
      ticketKey: "XFA-3299",
      coordinatorProvider: .codex
    )
    _ = try await createBranch(in: store, ticketRunID: ticket.id)

    await #expect(throws: (any Error).self) {
      _ = try await createBranch(in: store, ticketRunID: ticket.id)
    }
  }

  @Test("Approval is diff-bound and cannot be requested before review passes")
  func approvalGate() async throws {
    let store = try AgentWorkflowStore(path: temporaryDatabasePath())
    let ticket = try await store.createTicketRun(
      ticketKey: "XFA-3299",
      coordinatorProvider: .codex
    )
    let branch = try await createBranch(in: store, ticketRunID: ticket.id)

    await #expect(throws: AgentWorkflowError.self) {
      _ = try await store.requestApproval(branchRunID: branch.id, action: .commit)
    }

    _ = try await store.apply(.startImplementation, to: branch.id)
    _ = try await store.apply(.beginTesting, to: branch.id)
    _ = try await store.apply(.testsPassed(diffHash: "diff-1"), to: branch.id)
    _ = try await store.apply(.beginReview, to: branch.id)
    _ = try await store.apply(.reviewCompleted(.approved), to: branch.id)
    let request = try await store.requestApproval(branchRunID: branch.id, action: .commit)
    let decision = try await store.decideApproval(id: request.id, approved: true)

    #expect(request.diffHash == "diff-1")
    #expect(decision.status == .approved)
  }

  private func createBranch(
    in store: AgentWorkflowStore,
    ticketRunID: UUID
  ) async throws -> BranchRun {
    try await store.createBranchRun(
      ticketRunID: ticketRunID,
      repositoryPath: "/repos/api",
      worktreePath: "/worktrees/api-XFA-3299",
      branchName: "XFA-3299-mfa",
      baseBranch: "main",
      implementerProvider: .codex,
      reviewerProvider: .claude
    )
  }
}

private func temporaryDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("agent_workflow_\(UUID().uuidString).sqlite")
    .path
}
