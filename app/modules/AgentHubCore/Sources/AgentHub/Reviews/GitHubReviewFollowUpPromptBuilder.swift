//
//  GitHubReviewFollowUpPromptBuilder.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation

enum GitHubReviewFollowUpPromptBuilder {
  static func pullAndReviewAgain(_ pullRequest: GitHubProjectPullRequest) -> String {
    """
    Continue the existing session for this pull request:
    Pull request: #\(pullRequest.number) \(pullRequest.title)
    Repository: \(pullRequest.repositoryNameWithOwner)
    URL: \(pullRequest.url)

    Fetch the latest remote head of this pull request into the current review checkout and review the complete current diff again. Re-check every previous finding against the latest head and clearly state which findings are resolved, still present, or newly introduced.

    Keep this review read-only. Do not edit implementation files, commit, push, merge, or publish a GitHub review unless the user explicitly asks. Return an updated review with severity and precise file and line references.
    """
  }

  static func custom(
    _ command: String,
    pullRequest: GitHubProjectPullRequest
  ) -> String? {
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { return nil }

    return """
      Continue the existing session for this pull request:
      Pull request: #\(pullRequest.number) \(pullRequest.title)
      Repository: \(pullRequest.repositoryNameWithOwner)
      URL: \(pullRequest.url)

      Follow-up command from the user:
      \(trimmedCommand)

      Use the latest remote pull request state when this command depends on current code, checks, comments, or review status.
      """
  }
}

enum GitHubReviewSessionCommandPolicy {
  static func canSend(isPending: Bool) -> Bool {
    !isPending
  }
}
