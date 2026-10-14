import AgentHubSessionGraph
import Foundation

enum AutomatedReviewPhase: String, Codable, Sendable {
  case reviewerLaunching
  case reviewing
  case feedbackDelivered
  case approved
  case needsHumanIntervention
  case failed
}

struct AutomatedReviewRecord: Codable, Sendable, Equatable {
  let branchID: String
  let workflowID: String
  let repositoryPath: String
  let implementerSessionID: String
  let implementerProvider: SessionProviderKind
  let reviewerProvider: SessionProviderKind
  var reviewerSessionID: String?
  var reviewerPendingSessionID: UUID?
  let reviewerBaselineSessionIDs: Set<String>
  let startedAt: Date
  var reviewRequestSentAt: Date
  var feedbackDeliveredAt: Date?
  var phase: AutomatedReviewPhase
  var verdict: String?
  var failureMessage: String?
}

struct ManualWorkflowDefinition: Codable, Identifiable, Sendable, Equatable {
  let id: UUID
  var name: String
  var repositoryPath: String
  var branchName: String?
  let createdAt: Date

  var workflowID: String {
    "manual:\(id.uuidString)"
  }
}

struct ManualWorkflowDashboardState: Codable, Sendable, Equatable {
  var workflows: [ManualWorkflowDefinition] = []
  var sessionAssignments: [String: String] = [:]
  var sessionRoleOverrides: [String: DetectedAgentRole] = [:]
  var dismissedSessionIDs: Set<String> = []
  var automatedReviews: [String: AutomatedReviewRecord] = [:]
  var archivedWorkflowIDs: Set<String> = []

  private enum CodingKeys: String, CodingKey {
    case workflows
    case sessionAssignments
    case sessionRoleOverrides
    case dismissedSessionIDs
    case automatedReviews
    case archivedWorkflowIDs
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workflows =
      try container.decodeIfPresent([ManualWorkflowDefinition].self, forKey: .workflows)
      ?? []
    sessionAssignments =
      try container.decodeIfPresent([String: String].self, forKey: .sessionAssignments) ?? [:]
    sessionRoleOverrides =
      try container.decodeIfPresent([String: DetectedAgentRole].self, forKey: .sessionRoleOverrides)
      ?? [:]
    dismissedSessionIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .dismissedSessionIDs) ?? []
    automatedReviews =
      try container.decodeIfPresent([String: AutomatedReviewRecord].self, forKey: .automatedReviews)
      ?? [:]
    archivedWorkflowIDs =
      try container.decodeIfPresent(Set<String>.self, forKey: .archivedWorkflowIDs) ?? []
  }
}

struct ManualWorkflowDashboardStateStore {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> ManualWorkflowDashboardState {
    guard let data = defaults.data(forKey: AgentHubDefaults.manualWorkflowDashboardState),
      let state = try? JSONDecoder().decode(ManualWorkflowDashboardState.self, from: data)
    else {
      return ManualWorkflowDashboardState()
    }
    return state
  }

  func save(_ state: ManualWorkflowDashboardState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: AgentHubDefaults.manualWorkflowDashboardState)
  }
}
