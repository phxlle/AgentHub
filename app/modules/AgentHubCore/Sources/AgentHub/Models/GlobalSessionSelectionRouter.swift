//
//  GlobalSessionSelectionRouter.swift
//  AgentHub
//

import Foundation

// MARK: - GlobalSessionSelectionRequest

public struct GlobalSessionSelectionRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let providerKind: SessionProviderKind
  public let sessionId: String
  public let itemId: String
  public let projectPath: String
  public let session: CLISession?

  public init(
    id: UUID = UUID(),
    providerKind: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    itemId: String? = nil,
    session: CLISession? = nil
  ) {
    self.id = id
    self.providerKind = providerKind
    self.sessionId = sessionId
    self.itemId = itemId ?? Self.itemId(providerKind: providerKind, sessionId: sessionId)
    self.projectPath = projectPath
    self.session = session
  }

  public static func itemId(providerKind: SessionProviderKind, sessionId: String) -> String {
    "\(providerKind.rawValue.lowercased())-\(sessionId)"
  }
}

public struct WorkflowSessionComparisonTarget: Codable, Equatable, Sendable {
  public let providerKind: SessionProviderKind
  public let session: CLISession

  public init(providerKind: SessionProviderKind, session: CLISession) {
    self.providerKind = providerKind
    self.session = session
  }

  public var itemID: String {
    GlobalSessionSelectionRequest.itemId(
      providerKind: providerKind,
      sessionId: session.id
    )
  }
}

public struct WorkflowSessionComparisonRequest: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let workflowID: String
  public let title: String
  public let implementation: WorkflowSessionComparisonTarget
  public let review: WorkflowSessionComparisonTarget

  public init(
    id: UUID = UUID(),
    workflowID: String,
    title: String,
    implementation: WorkflowSessionComparisonTarget,
    review: WorkflowSessionComparisonTarget
  ) {
    self.id = id
    self.workflowID = workflowID
    self.title = title
    self.implementation = implementation
    self.review = review
  }
}

// MARK: - GlobalSessionSelectionRouter

@MainActor
@Observable
public final class GlobalSessionSelectionRouter {
  public private(set) var selectionRequest: GlobalSessionSelectionRequest?
  public private(set) var comparisonRequest: WorkflowSessionComparisonRequest?
  public private(set) var activeComparison: WorkflowSessionComparisonRequest?

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    activeComparison = Self.loadActiveComparison(from: defaults)
  }

  public func select(
    providerKind: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    itemId: String? = nil,
    session: CLISession? = nil
  ) {
    selectionRequest = GlobalSessionSelectionRequest(
      providerKind: providerKind,
      sessionId: sessionId,
      projectPath: projectPath,
      itemId: itemId,
      session: session
    )
  }

  public func compare(_ request: WorkflowSessionComparisonRequest) {
    selectionRequest = nil
    comparisonRequest = request
    setActiveComparison(request)
  }

  public func markConsumed(_ request: GlobalSessionSelectionRequest) {
    guard selectionRequest?.id == request.id else { return }
    selectionRequest = nil
  }

  public func markConsumed(_ request: WorkflowSessionComparisonRequest) {
    guard comparisonRequest?.id == request.id else { return }
    comparisonRequest = nil
  }

  public func closeComparison(_ request: WorkflowSessionComparisonRequest? = nil) {
    if let request, activeComparison?.id != request.id {
      return
    }
    comparisonRequest = nil
    setActiveComparison(nil)
  }

  private func setActiveComparison(_ comparison: WorkflowSessionComparisonRequest?) {
    activeComparison = comparison
    guard let comparison else {
      defaults.removeObject(forKey: AgentHubDefaults.activeWorkflowSessionComparison)
      return
    }
    guard let data = try? JSONEncoder().encode(comparison) else { return }
    defaults.set(data, forKey: AgentHubDefaults.activeWorkflowSessionComparison)
  }

  private static func loadActiveComparison(
    from defaults: UserDefaults
  ) -> WorkflowSessionComparisonRequest? {
    guard let data = defaults.data(forKey: AgentHubDefaults.activeWorkflowSessionComparison) else {
      return nil
    }
    return try? JSONDecoder().decode(WorkflowSessionComparisonRequest.self, from: data)
  }
}
