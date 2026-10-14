//
//  GitHubPromptLibrary.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation
import Observation

struct GitHubPromptTemplate: Codable, Equatable, Identifiable, Sendable {
  let id: String
  var name: String
  var prompt: String
  let builtInKind: BuiltInKind?

  enum BuiltInKind: String, Codable, Sendable {
    case independentReview
    case fixCI
    case resolveComments
  }

  var isBuiltIn: Bool { builtInKind != nil }
}

struct GitHubPromptVariable: Identifiable, Sendable {
  let token: String
  let description: String

  var id: String { token }
}

struct GitHubPromptContext: Sendable {
  let pullRequest: GitHubProjectPullRequest
  let project: GitHubReviewProject
  let view: GitHubProjectView
  let provider: SessionProviderKind

  var values: [String: String] {
    [
      "pull_request_title": pullRequest.title,
      "pull_request_number": String(pullRequest.number),
      "pull_request_url": pullRequest.url,
      "repository": pullRequest.repositoryNameWithOwner,
      "repository_name": pullRequest.repositoryName,
      "author": pullRequest.authorLogin.map { "@\($0)" } ?? "Unknown",
      "project": project.displayName,
      "project_view": view.name,
      "project_filter": view.filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      "provider": provider.rawValue,
    ]
  }
}

@MainActor
@Observable
final class GitHubPromptLibrary {
  static let shared = GitHubPromptLibrary()

  private enum DefaultsKey {
    static let templates = "agenthub.reviews.prompt-templates.v1"
    static let sharedInstructions = "agenthub.reviews.shared-prompt-instructions.v1"
  }

  static let variables: [GitHubPromptVariable] = [
    .init(token: "{{pull_request_title}}", description: "Pull request title"),
    .init(token: "{{pull_request_number}}", description: "Pull request number"),
    .init(token: "{{pull_request_url}}", description: "Full pull request URL"),
    .init(token: "{{repository}}", description: "Owner and repository name"),
    .init(token: "{{repository_name}}", description: "Repository name"),
    .init(token: "{{author}}", description: "Pull request author"),
    .init(token: "{{project}}", description: "Selected GitHub Project"),
    .init(token: "{{project_view}}", description: "Selected Project view"),
    .init(token: "{{project_filter}}", description: "Filter from the selected view"),
    .init(token: "{{provider}}", description: "Codex or Claude"),
  ]

  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  var templates: [GitHubPromptTemplate] {
    didSet { persistTemplates() }
  }

  var sharedInstructions: String {
    didSet { defaults.set(sharedInstructions, forKey: DefaultsKey.sharedInstructions) }
  }

  init(userDefaults: UserDefaults = .standard) {
    defaults = userDefaults
    if let data = userDefaults.data(forKey: DefaultsKey.templates),
      let decoded = try? decoder.decode([GitHubPromptTemplate].self, from: data),
      !decoded.isEmpty
    {
      templates = Self.mergingMissingBuiltIns(into: decoded)
    } else {
      templates = Self.defaultTemplates
    }
    sharedInstructions =
      userDefaults.string(forKey: DefaultsKey.sharedInstructions)
      ?? Self.defaultSharedInstructions
    persistTemplates()
  }

  func addCustomTemplate() -> GitHubPromptTemplate {
    let template = GitHubPromptTemplate(
      id: UUID().uuidString,
      name: "Custom prompt",
      prompt: """
        Work on {{pull_request_title}} (#{{pull_request_number}}) in {{repository}}.
        Pull request: {{pull_request_url}}

        Describe the task and expected outcome here.
        """,
      builtInKind: nil
    )
    templates.append(template)
    return template
  }

  func deleteTemplate(id: String) {
    guard templates.first(where: { $0.id == id })?.isBuiltIn == false else { return }
    templates.removeAll { $0.id == id }
  }

  func restoreBuiltIn(id: String) {
    guard let index = templates.firstIndex(where: { $0.id == id }),
      let kind = templates[index].builtInKind,
      let original = Self.defaultTemplates.first(where: { $0.builtInKind == kind })
    else { return }
    templates[index] = original
  }

  /// A one-off template for a message the user writes themselves. With context,
  /// the agent is told which pull request the question is about.
  static func customMessageTemplate(
    message: String,
    includePullRequestContext: Bool
  ) -> GitHubPromptTemplate {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt =
      includePullRequestContext
      ? "Context: pull request #{{pull_request_number}} \"{{pull_request_title}}\" ({{pull_request_url}}) in {{repository}}.\n\n\(trimmed)"
      : trimmed
    return GitHubPromptTemplate(
      id: "custom-\(UUID().uuidString)",
      name: "Own message",
      prompt: prompt,
      builtInKind: nil
    )
  }

  func renderedPrompt(
    template: GitHubPromptTemplate,
    context: GitHubPromptContext
  ) -> String {
    var result = template.prompt
    for (name, value) in context.values {
      result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
    }

    // Always appended, also to saved/edited templates: parallel review agents
    // share one GitHub API quota.
    result += "\n\n\(GitHubAPIBudgetGuidance.text)"

    let trimmedSharedInstructions = sharedInstructions.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if !trimmedSharedInstructions.isEmpty {
      result += "\n\nShared AgentHub instructions:\n\(trimmedSharedInstructions)"
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func persistTemplates() {
    guard let data = try? encoder.encode(templates) else { return }
    defaults.set(data, forKey: DefaultsKey.templates)
  }

  private static func mergingMissingBuiltIns(
    into templates: [GitHubPromptTemplate]
  ) -> [GitHubPromptTemplate] {
    let kinds = Set(templates.compactMap(\.builtInKind))
    let missing = defaultTemplates.filter { template in
      guard let kind = template.builtInKind else { return false }
      return !kinds.contains(kind)
    }
    return templates + missing
  }

  static let defaultSharedInstructions = """
    Follow all repository and machine-level agent instructions. Keep the configured work log, including Obsidian status notes when configured, up to date at task start, important decisions, validation, and completion.
    """

  static let defaultTemplates: [GitHubPromptTemplate] = [
    GitHubPromptTemplate(
      id: "independent-review",
      name: "Independent review",
      prompt: """
        Perform an independent code review of this pull request:
        - Pull request: {{pull_request_title}} (#{{pull_request_number}})
        - URL: {{pull_request_url}}
        - Repository: {{repository}}
        - Author: {{author}}
        - GitHub Project: {{project}}
        - Project view: {{project_view}}
        - Project filter: {{project_filter}}

        Use `gh pr view {{pull_request_url}}` and `gh pr diff {{pull_request_url}}` to inspect the exact pull request and its current head. Read the repository instructions before reviewing. Run relevant read-only checks or tests when they materially improve confidence.

        Do not edit files, commit, push, approve, request changes, or post comments to GitHub. Return only a review report for the user. Put actionable findings first, ordered by severity, with file and line references. Explain the impact and a concrete remediation. If there are no findings, say so explicitly and mention any residual test or coverage risk.
        """,
      builtInKind: .independentReview
    ),
    GitHubPromptTemplate(
      id: "fix-ci",
      name: "Fix CI issues",
      prompt: """
        Fix the failing CI for {{pull_request_title}} (#{{pull_request_number}}) in {{repository}}.
        Pull request: {{pull_request_url}}

        Use `gh pr view {{pull_request_url}}` and `gh pr checks {{pull_request_url}}` to inspect the current head and failing checks. Read the failing GitHub Actions logs and repository instructions before editing. Verify that the active checkout or worktree is on the pull request head branch before changing files. Implement the smallest correct fix and run the relevant local validation.

        Do not merge or approve the pull request. Do not push unless the user or active workflow policy explicitly authorizes it. Report the root cause, changed files, validation results, and anything still failing.
        """,
      builtInKind: .fixCI
    ),
    GitHubPromptTemplate(
      id: "resolve-comments",
      name: "Resolve review comments",
      prompt: """
        Resolve the actionable review comments for {{pull_request_title}} (#{{pull_request_number}}) in {{repository}}.
        Pull request: {{pull_request_url}}

        Inspect the latest review state and unresolved threads with `gh`. Read the repository instructions, verify that the active checkout or worktree is on the pull request head branch, and understand each comment before editing. Implement the requested changes where they are correct, run relevant validation, and explain clearly when a comment should not be applied.

        Resolve a GitHub review thread only after its request is fully addressed and verified. Do not dismiss unaddressed feedback, merge the pull request, or push unless the user or active workflow policy explicitly authorizes it. Summarize every handled thread, code change, and validation result.
        """,
      builtInKind: .resolveComments
    ),
  ]
}
