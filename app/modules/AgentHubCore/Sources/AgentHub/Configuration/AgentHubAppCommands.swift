//
//  AgentHubAppCommands.swift
//  AgentHub
//
//  Shared app commands that bridge the macOS menu bar and workspace views.
//

import Foundation

public enum AgentHubWorkspaceSection: String, CaseIterable, Identifiable, Sendable {
  case workflows = "Workflows"
  case reviews = "Reviews"
  case sessions = "Sessions"
  case sprint = "Sprint"

  public var id: Self { self }
}

public enum AgentHubAppCommand {
  public static let selectWorkspaceNotification = Notification.Name(
    "com.agenthub.command.select-workspace"
  )
  public static let archiveCurrentSessionNotification = Notification.Name(
    "com.agenthub.command.archive-current-session"
  )
  public static let resumeSessionByIDNotification = Notification.Name(
    "com.agenthub.command.resume-session-by-id"
  )

  @MainActor
  public static func resumeSessionByID() {
    NotificationCenter.default.post(name: resumeSessionByIDNotification, object: nil)
  }

  @MainActor
  public static func selectWorkspace(_ section: AgentHubWorkspaceSection) {
    NotificationCenter.default.post(
      name: selectWorkspaceNotification,
      object: section.rawValue
    )
  }

  public static func workspaceSection(from notification: Notification)
    -> AgentHubWorkspaceSection?
  {
    guard let rawValue = notification.object as? String else { return nil }
    return AgentHubWorkspaceSection(rawValue: rawValue)
  }

  @MainActor
  public static func archiveCurrentSession() {
    NotificationCenter.default.post(
      name: archiveCurrentSessionNotification,
      object: nil
    )
  }
}
