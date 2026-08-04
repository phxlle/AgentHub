import Foundation
import Testing

@testable import AgentWorkflowCore

@Suite("Branch workflow state machine")
struct BranchWorkflowStateMachineTests {
  @Test("Happy path reaches human approval after tests and independent review")
  func happyPath() throws {
    var branchRun = try makeBranchRun()

    try BranchWorkflowStateMachine.apply(.startImplementation, to: &branchRun)
    try BranchWorkflowStateMachine.apply(.beginTesting, to: &branchRun)
    try BranchWorkflowStateMachine.apply(.testsPassed(diffHash: "diff-1"), to: &branchRun)
    try BranchWorkflowStateMachine.apply(.beginReview, to: &branchRun)
    try BranchWorkflowStateMachine.apply(.reviewCompleted(.approved), to: &branchRun)

    #expect(branchRun.status == BranchRunStatus.awaitingApproval)
    #expect(branchRun.reviewCycle == 1)
    #expect(branchRun.currentDiffHash == "diff-1")
  }

  @Test("A second changes-requested verdict escalates to a human")
  func twoReviewLimit() throws {
    var branchRun = try makeBranchRun()

    try runImplementationAndReview(on: &branchRun, diffHash: "diff-1")
    try BranchWorkflowStateMachine.apply(.reviewCompleted(.changesRequested), to: &branchRun)
    #expect(branchRun.status == BranchRunStatus.changesRequested)
    #expect(branchRun.reviewCycle == 1)

    try runImplementationAndReview(on: &branchRun, diffHash: "diff-2")
    try BranchWorkflowStateMachine.apply(.reviewCompleted(.changesRequested), to: &branchRun)

    #expect(branchRun.status == BranchRunStatus.awaitingHumanIntervention)
    #expect(branchRun.reviewCycle == 2)
  }

  @Test("Review cannot start before tests bind it to a diff")
  func reviewRequiresTestedDiff() throws {
    var branchRun = try makeBranchRun()

    #expect(throws: AgentWorkflowError.self) {
      try BranchWorkflowStateMachine.apply(.beginReview, to: &branchRun)
    }
  }

  private func runImplementationAndReview(
    on branchRun: inout BranchRun,
    diffHash: String
  ) throws {
    try BranchWorkflowStateMachine.apply(.startImplementation, to: &branchRun)
    try BranchWorkflowStateMachine.apply(.beginTesting, to: &branchRun)
    try BranchWorkflowStateMachine.apply(.testsPassed(diffHash: diffHash), to: &branchRun)
    try BranchWorkflowStateMachine.apply(.beginReview, to: &branchRun)
  }
}
