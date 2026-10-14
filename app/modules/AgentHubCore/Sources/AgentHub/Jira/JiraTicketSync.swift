//
//  JiraTicketSync.swift
//  AgentHub
//
//  The "Sync" rules: derive each ticket's status from its pull requests and open
//  agent sessions. Pure, so the rules are testable without Jira or GitHub.
//

import AgentHubGitHub
import Foundation

enum JiraSyncTarget: Equatable {
  case inProgress
  case uxReview
  case done
}

enum JiraTicketSync {
  /// - All (non-abandoned) PRs merged → done.
  /// - Every open PR approved → UX review.
  /// - A PR not approved yet, or an open session without a PR → in progress.
  /// - Otherwise, leave the ticket alone.
  static func target(
    pullRequests: [GitHubTicketPullRequest],
    hasOpenSession: Bool
  ) -> (target: JiraSyncTarget, reason: String)? {
    let relevant = pullRequests.filter { !$0.isAbandoned }
    if !relevant.isEmpty {
      let open = relevant.filter { !$0.isMerged }
      if open.isEmpty {
        return (.done, relevant.count == 1 ? "PR merged" : "all \(relevant.count) PRs merged")
      }
      if open.allSatisfy(\.isApproved) {
        return (.uxReview, open.count == 1 ? "PR approved" : "all \(open.count) open PRs approved")
      }
      let waiting = open.filter { !$0.isApproved }.count
      return (.inProgress, waiting == 1 ? "PR not approved yet" : "\(waiting) PRs not approved yet")
    }
    return hasOpenSession ? (.inProgress, "agent session open, no PR yet") : nil
  }

  /// Workflow status names for each target, picked from the statuses Jira uses.
  static func statusName(
    for target: JiraSyncTarget,
    among statuses: [(name: String, category: String?)]
  ) -> String? {
    func first(_ predicate: ((name: String, category: String?)) -> Bool) -> String? {
      statuses.first(where: predicate)?.name
    }
    switch target {
    case .done:
      return first { $0.name.caseInsensitiveCompare("Done") == .orderedSame }
        ?? first { $0.category == "done" && !$0.name.lowercased().contains("won") }
    case .uxReview:
      return first { $0.name.lowercased().contains("ux review") }
    case .inProgress:
      return first { $0.name.caseInsensitiveCompare("In Progress") == .orderedSame }
        ?? first { $0.category == "indeterminate" && !$0.name.lowercased().contains("review") }
    }
  }
}
