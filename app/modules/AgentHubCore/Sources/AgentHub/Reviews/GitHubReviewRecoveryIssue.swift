//
//  GitHubReviewRecoveryIssue.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation

struct GitHubReviewRecoveryIssue: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case projectPermissionRequired
    case authenticationRequired
    case cliNotInstalled
    case rateLimited
    case requestFailed
  }

  enum Action: Equatable, Sendable {
    case reconnectWithProjectAccess
    case signIn
    case installCLI
    case retry
  }

  let kind: Kind
  let title: String
  let message: String
  let technicalDetails: String?
  let primaryAction: Action
  let secondaryAction: Action?

  static func classify(_ error: Error) -> GitHubReviewRecoveryIssue {
    // Checked first: a quota error is not a login problem, even though gh
    // reports both as a failed command.
    if indicatesRateLimit(error.localizedDescription) {
      return rateLimited(resetAt: nil, details: error.localizedDescription)
    }

    if let githubError = error as? GitHubCLIError {
      switch githubError {
      case .cliNotInstalled:
        return GitHubReviewRecoveryIssue(
          kind: .cliNotInstalled,
          title: "GitHub CLI is missing",
          message: "Install GitHub CLI, then return here to connect your account.",
          technicalDetails: nil,
          primaryAction: .installCLI,
          secondaryAction: .retry
        )
      case .notAuthenticated:
        return authenticationIssue(details: githubError.localizedDescription)
      case .commandFailed(let message):
        if requiresProjectPermission(message) {
          return projectPermissionIssue(details: message)
        }
        if indicatesAuthenticationFailure(message) {
          return authenticationIssue(details: message)
        }
      case .notAGitRepository, .noRemoteRepository, .parseError, .timeout:
        break
      }
    }

    let details = conciseDetails(error.localizedDescription)
    return GitHubReviewRecoveryIssue(
      kind: .requestFailed,
      title: "GitHub reviews could not be loaded",
      message: "Check your connection or GitHub login, then try loading the review queue again.",
      technicalDetails: details,
      primaryAction: .retry,
      secondaryAction: .signIn
    )
  }

  /// GitHub's API quota (5,000 points an hour) is shared by AgentHub and every
  /// agent that runs `gh` with this account.
  static func rateLimited(
    resetAt: Date?,
    details: String?,
    now: Date = .now
  ) -> GitHubReviewRecoveryIssue {
    var message =
      "GitHub's hourly API quota for your account is used up. It is shared by AgentHub and every agent session that runs gh, so many parallel reviews can exhaust it."
    if let resetAt {
      let minutes = max(0, Int(resetAt.timeIntervalSince(now) / 60.0) + 1)
      message += " It resets at \(resetAt.formatted(date: .omitted, time: .shortened)) (in about \(minutes) min)."
    } else {
      message += " It resets within the hour."
    }
    return GitHubReviewRecoveryIssue(
      kind: .rateLimited,
      title: "GitHub API rate limit reached",
      message: message,
      technicalDetails: details.map(conciseDetails),
      primaryAction: .retry,
      secondaryAction: nil
    )
  }

  static func indicatesRateLimit(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("rate limit") || normalized.contains("ratelimited")
  }

  var primaryActionTitle: String {
    title(for: primaryAction)
  }

  var secondaryActionTitle: String? {
    secondaryAction.map(title(for:))
  }

  private static func projectPermissionIssue(details: String) -> GitHubReviewRecoveryIssue {
    GitHubReviewRecoveryIssue(
      kind: .projectPermissionRequired,
      title: "GitHub Project access is required",
      message:
        "AgentHub is connected to GitHub, but the current login cannot read Projects. Reconnect to add the read:project permission.",
      technicalDetails: conciseDetails(details),
      primaryAction: .reconnectWithProjectAccess,
      secondaryAction: .retry
    )
  }

  private static func authenticationIssue(details: String?) -> GitHubReviewRecoveryIssue {
    GitHubReviewRecoveryIssue(
      kind: .authenticationRequired,
      title: "Reconnect GitHub",
      message:
        "Your GitHub CLI login is missing or no longer valid. Sign in again to load reviews.",
      technicalDetails: details.map(conciseDetails),
      primaryAction: .signIn,
      secondaryAction: .retry
    )
  }

  private static func requiresProjectPermission(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("read:project")
      && (normalized.contains("required scope")
        || normalized.contains("required scopes")
        || normalized.contains("token has not been granted"))
  }

  private static func indicatesAuthenticationFailure(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("bad credentials")
      || normalized.contains("authentication failed")
      || normalized.contains("token expired")
      || normalized.contains("requires authentication")
  }

  private static func conciseDetails(_ details: String) -> String {
    let normalized =
      details
      .replacingOccurrences(of: "GitHub CLI command failed: ", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > 700 else { return normalized }
    let endIndex = normalized.index(normalized.startIndex, offsetBy: 700)
    return String(normalized[..<endIndex]) + "…"
  }

  private func title(for action: Action) -> String {
    switch action {
    case .reconnectWithProjectAccess:
      return "Reconnect GitHub"
    case .signIn:
      return "Sign in to GitHub"
    case .installCLI:
      return "Install GitHub CLI"
    case .retry:
      return "Try again"
    }
  }
}
