//
//  GitHubAuthenticationRecoveryLauncher.swift
//  AgentHub
//

import AppKit
import Foundation

@MainActor
enum GitHubAuthenticationRecoveryLauncher {
  static func perform(_ action: GitHubReviewRecoveryIssue.Action) -> Error? {
    switch action {
    case .reconnectWithProjectAccess:
      return TerminalLauncher.launchTerminalCommand(
        executableName: "gh",
        arguments: [
          "auth", "refresh", "--hostname", "github.com", "--scopes", "read:project",
        ],
        scriptPrefix: "github_project_access"
      )
    case .signIn:
      return TerminalLauncher.launchTerminalCommand(
        executableName: "gh",
        arguments: [
          "auth", "login", "--hostname", "github.com", "--web", "--scopes", "read:project",
        ],
        scriptPrefix: "github_reconnect"
      )
    case .installCLI:
      guard let url = URL(string: "https://cli.github.com") else { return nil }
      if NSWorkspace.shared.open(url) { return nil }
      return NSError(
        domain: "GitHubAuthenticationRecoveryLauncher",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not open the GitHub CLI website."]
      )
    case .retry:
      return nil
    }
  }
}
