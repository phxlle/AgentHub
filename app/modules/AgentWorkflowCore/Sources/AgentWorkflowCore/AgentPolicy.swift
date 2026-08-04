import Foundation

public struct AgentProviderID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let codex = AgentProviderID(rawValue: "codex")
  public static let claude = AgentProviderID(rawValue: "claude")
}

public enum AgentRole: String, Codable, CaseIterable, Sendable {
  case coordinator
  case implementer
  case reviewer
}

public enum AgentCapability: String, Codable, CaseIterable, Sendable {
  case readTicket
  case orchestrateWorkflow
  case readWorkspace
  case writeWorkspace
  case runTests
  case respondToReview
  case reviewDiff
}

public struct AgentRolePolicy: Equatable, Sendable {
  public let role: AgentRole
  public let capabilities: Set<AgentCapability>

  public init(role: AgentRole) {
    self.role = role
    switch role {
    case .coordinator:
      capabilities = [.readTicket, .orchestrateWorkflow]
    case .implementer:
      capabilities = [.readWorkspace, .writeWorkspace, .runTests, .respondToReview]
    case .reviewer:
      capabilities = [.readWorkspace, .reviewDiff]
    }
  }

  public func allows(_ capability: AgentCapability) -> Bool {
    capabilities.contains(capability)
  }
}

public struct AgentAssignment: Codable, Equatable, Sendable {
  public let role: AgentRole
  public let provider: AgentProviderID
  public var sessionID: String?

  public init(role: AgentRole, provider: AgentProviderID, sessionID: String? = nil) {
    self.role = role
    self.provider = provider
    self.sessionID = sessionID
  }

  public var policy: AgentRolePolicy {
    AgentRolePolicy(role: role)
  }
}
