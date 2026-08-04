//
//  GitHubProjectReviewPromptBuilder.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation

enum GitHubProjectReviewPromptBuilder {
  static func prompt(
    pullRequest: GitHubProjectPullRequest,
    project: GitHubReviewProject,
    view: GitHubProjectView
  ) -> String {
    let projectFilter = view.filter?.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = [
      "Perform an independent code review of this pull request:",
      "- Pull request: \(pullRequest.title) (#\(pullRequest.number))",
      "- URL: \(pullRequest.url)",
      "- Repository: \(pullRequest.repositoryNameWithOwner)",
      "- GitHub Project: \(project.displayName)",
      "- Project view: \(view.name)",
    ]
    if let projectFilter, !projectFilter.isEmpty {
      lines.append("- Project filter: \(projectFilter)")
    }
    lines += [
      "",
      "Use `gh pr view \(pullRequest.url)` and `gh pr diff \(pullRequest.url)` to inspect the exact pull request and its current head. Read the repository instructions before reviewing. Run relevant read-only checks or tests when they materially improve confidence.",
      "",
      "Do not edit files, commit, push, approve, request changes, or post comments to GitHub. Return only a review report for the user. Put actionable findings first, ordered by severity, with file and line references. Explain the impact and a concrete remediation. If there are no findings, say so explicitly and mention any residual test or coverage risk.",
    ]
    return lines.joined(separator: "\n")
  }
}
