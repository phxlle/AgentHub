import Foundation

public enum BranchWorkflowCommand: Equatable, Sendable {
  case startImplementation
  case beginTesting
  case testsPassed(diffHash: String)
  case testsFailed(reason: String)
  case beginReview
  case reviewCompleted(ReviewVerdict)
  case fail(reason: String)
  case cancel

  var eventKind: String {
    switch self {
    case .startImplementation: "implementation.started"
    case .beginTesting: "tests.started"
    case .testsPassed: "tests.passed"
    case .testsFailed: "tests.failed"
    case .beginReview: "review.started"
    case .reviewCompleted(.approved): "review.approved"
    case .reviewCompleted(.changesRequested): "review.changes_requested"
    case .fail: "workflow.failed"
    case .cancel: "workflow.cancelled"
    }
  }

  var eventMessage: String? {
    switch self {
    case .testsPassed(let diffHash): diffHash
    case .testsFailed(let reason), .fail(let reason): reason
    default: nil
    }
  }
}

public enum BranchWorkflowStateMachine {
  public static func apply(
    _ command: BranchWorkflowCommand,
    to branchRun: inout BranchRun,
    at date: Date = Date()
  ) throws {
    switch command {
    case .startImplementation:
      try require(
        branchRun.status == .queued || branchRun.status == .changesRequested, command, branchRun)
      branchRun.status = .implementing

    case .beginTesting:
      try require(branchRun.status == .implementing, command, branchRun)
      branchRun.status = .testing

    case .testsPassed(let diffHash):
      try require(branchRun.status == .testing, command, branchRun)
      let normalizedHash = diffHash.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedHash.isEmpty else {
        throw AgentWorkflowError.invalidDiffHash
      }
      branchRun.currentDiffHash = normalizedHash
      branchRun.status = .awaitingReview

    case .testsFailed:
      try require(branchRun.status == .testing, command, branchRun)
      branchRun.status = .changesRequested

    case .beginReview:
      try require(branchRun.status == .awaitingReview, command, branchRun)
      guard branchRun.reviewCycle < 2 else {
        throw AgentWorkflowError.reviewLimitReached
      }
      branchRun.reviewCycle += 1
      branchRun.status = .reviewing

    case .reviewCompleted(.approved):
      try require(branchRun.status == .reviewing, command, branchRun)
      branchRun.status = .awaitingApproval

    case .reviewCompleted(.changesRequested):
      try require(branchRun.status == .reviewing, command, branchRun)
      branchRun.status =
        branchRun.reviewCycle >= 2
        ? .awaitingHumanIntervention
        : .changesRequested

    case .fail:
      guard !branchRun.status.isTerminal else {
        throw AgentWorkflowError.invalidTransition(
          from: branchRun.status,
          command: command.eventKind
        )
      }
      branchRun.status = .failed

    case .cancel:
      guard !branchRun.status.isTerminal else {
        throw AgentWorkflowError.invalidTransition(
          from: branchRun.status,
          command: command.eventKind
        )
      }
      branchRun.status = .cancelled
    }

    branchRun.updatedAt = date
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ command: BranchWorkflowCommand,
    _ branchRun: BranchRun
  ) throws {
    guard condition() else {
      throw AgentWorkflowError.invalidTransition(
        from: branchRun.status,
        command: command.eventKind
      )
    }
  }
}
