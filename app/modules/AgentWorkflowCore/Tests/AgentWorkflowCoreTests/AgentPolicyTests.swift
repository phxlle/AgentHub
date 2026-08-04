import Foundation
import Testing

@testable import AgentWorkflowCore

@Suite("Agent role policies")
struct AgentPolicyTests {
  @Test("Coordinator can read Jira context but cannot read or write a workspace")
  func coordinatorPolicy() {
    let policy = AgentRolePolicy(role: .coordinator)

    #expect(policy.allows(.readTicket))
    #expect(policy.allows(.orchestrateWorkflow))
    #expect(!policy.allows(.readWorkspace))
    #expect(!policy.allows(.writeWorkspace))
  }

  @Test("Reviewer can inspect a diff but cannot write or run tests")
  func reviewerPolicy() {
    let policy = AgentRolePolicy(role: .reviewer)

    #expect(policy.allows(.readWorkspace))
    #expect(policy.allows(.reviewDiff))
    #expect(!policy.allows(.writeWorkspace))
    #expect(!policy.allows(.runTests))
  }

  @Test("Branch run always creates exactly one implementer and one reviewer")
  func fixedBranchRoles() throws {
    let branchRun = try makeBranchRun()

    #expect(branchRun.implementer.role == AgentRole.implementer)
    #expect(branchRun.reviewer.role == AgentRole.reviewer)
    #expect(branchRun.implementer.provider == AgentProviderID.codex)
    #expect(branchRun.reviewer.provider == AgentProviderID.claude)
  }
}

func makeBranchRun(ticketRunID: UUID = UUID()) throws -> BranchRun {
  try BranchRun(
    ticketRunID: ticketRunID,
    repositoryPath: "/repos/api",
    worktreePath: "/worktrees/api-XFA-3299",
    branchName: "XFA-3299-mfa",
    baseBranch: "main",
    implementerProvider: .codex,
    reviewerProvider: .claude
  )
}
