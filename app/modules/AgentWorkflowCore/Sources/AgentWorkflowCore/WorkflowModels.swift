import Foundation

public enum TicketRunStatus: String, Codable, CaseIterable, Sendable {
  case active
  case awaitingHumanInput
  case completed
  case failed
  case cancelled
}

public struct TicketRun: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let ticketKey: String
  public var summary: String?
  public var coordinator: AgentAssignment
  public var status: TicketRunStatus
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    ticketKey: String,
    summary: String? = nil,
    coordinatorProvider: AgentProviderID,
    status: TicketRunStatus = .active,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) throws {
    let normalizedKey = ticketKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalizedKey.isEmpty else {
      throw AgentWorkflowError.invalidTicketKey
    }

    self.id = id
    self.ticketKey = normalizedKey
    self.summary = summary
    coordinator = AgentAssignment(role: .coordinator, provider: coordinatorProvider)
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum BranchRunStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case implementing
  case testing
  case awaitingReview
  case reviewing
  case changesRequested
  case awaitingHumanIntervention
  case awaitingApproval
  case completed
  case failed
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled:
      true
    default:
      false
    }
  }
}

public struct BranchRun: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let ticketRunID: UUID
  public let repositoryPath: String
  public let worktreePath: String
  public let branchName: String
  public let baseBranch: String
  public var implementer: AgentAssignment
  public var reviewer: AgentAssignment
  public var status: BranchRunStatus
  public var reviewCycle: Int
  public var currentDiffHash: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    ticketRunID: UUID,
    repositoryPath: String,
    worktreePath: String,
    branchName: String,
    baseBranch: String,
    implementerProvider: AgentProviderID,
    reviewerProvider: AgentProviderID,
    status: BranchRunStatus = .queued,
    reviewCycle: Int = 0,
    currentDiffHash: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) throws {
    guard !repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentWorkflowError.invalidRepositoryPath
    }
    guard !worktreePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentWorkflowError.invalidWorktreePath
    }
    guard !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentWorkflowError.invalidBranchName
    }
    guard !baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentWorkflowError.invalidBaseBranch
    }
    guard (0...2).contains(reviewCycle) else {
      throw AgentWorkflowError.invalidReviewCycle(reviewCycle)
    }

    self.id = id
    self.ticketRunID = ticketRunID
    self.repositoryPath = repositoryPath
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.baseBranch = baseBranch
    implementer = AgentAssignment(role: .implementer, provider: implementerProvider)
    reviewer = AgentAssignment(role: .reviewer, provider: reviewerProvider)
    self.status = status
    self.reviewCycle = reviewCycle
    self.currentDiffHash = currentDiffHash
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum ReviewVerdict: String, Codable, CaseIterable, Sendable {
  case approved
  case changesRequested
}

public enum ApprovalAction: String, Codable, CaseIterable, Sendable {
  case commit
  case push
  case createDraftPullRequest
}

public enum ApprovalStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case approved
  case rejected
  case invalidated
  case executed
}

public struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let branchRunID: UUID
  public let action: ApprovalAction
  public let diffHash: String
  public var status: ApprovalStatus
  public let requestedAt: Date
  public var decidedAt: Date?

  public init(
    id: UUID = UUID(),
    branchRunID: UUID,
    action: ApprovalAction,
    diffHash: String,
    status: ApprovalStatus = .pending,
    requestedAt: Date = Date(),
    decidedAt: Date? = nil
  ) {
    self.id = id
    self.branchRunID = branchRunID
    self.action = action
    self.diffHash = diffHash
    self.status = status
    self.requestedAt = requestedAt
    self.decidedAt = decidedAt
  }
}

public struct WorkflowEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let ticketRunID: UUID
  public let branchRunID: UUID?
  public let kind: String
  public let message: String?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    ticketRunID: UUID,
    branchRunID: UUID? = nil,
    kind: String,
    message: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.ticketRunID = ticketRunID
    self.branchRunID = branchRunID
    self.kind = kind
    self.message = message
    self.createdAt = createdAt
  }
}

public enum AgentWorkflowError: Error, Equatable, Sendable {
  case invalidTicketKey
  case invalidRepositoryPath
  case invalidWorktreePath
  case invalidBranchName
  case invalidBaseBranch
  case invalidReviewCycle(Int)
  case invalidDiffHash
  case ticketRunNotFound(UUID)
  case branchRunNotFound(UUID)
  case approvalRequestNotFound(UUID)
  case invalidTransition(from: BranchRunStatus, command: String)
  case reviewLimitReached
  case approvalNotAllowed(BranchRunStatus)
  case approvalAlreadyDecided(ApprovalStatus)
  case diffChanged
  case corruptPersistenceRecord(String)
}
