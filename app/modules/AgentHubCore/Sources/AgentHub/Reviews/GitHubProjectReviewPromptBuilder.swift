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
    let template = GitHubPromptLibrary.defaultTemplates[0]
    var result = template.prompt
    let context = GitHubPromptContext(
      pullRequest: pullRequest,
      project: project,
      view: view,
      provider: .codex
    )
    for (name, value) in context.values {
      result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
