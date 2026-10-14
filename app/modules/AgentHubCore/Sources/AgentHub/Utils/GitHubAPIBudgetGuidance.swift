//
//  GitHubAPIBudgetGuidance.swift
//  AgentHub
//
//  GitHub's API quota (5,000 GraphQL points an hour) is per account and shared by
//  AgentHub and every agent session running `gh`. Parallel review agents that
//  re-run `gh pr view` / `gh api` exhaust it, which then breaks Reviews and PR
//  status everywhere. Appended to the prompts AgentHub sends to agents.
//

enum GitHubAPIBudgetGuidance {
  static let text = """
    GitHub API budget: the GitHub API quota is shared with other agents on this account, so use `gh` sparingly.
    - Fetch pull request data once and reuse it: one `gh pr view <url> --json` call with every field you need, and one `gh pr diff`. Do not re-run them to re-check the same thing.
    - Prefer local git for code and history (`git fetch`, `git diff`, `git log`, `git show`) over `gh api`.
    - Do not poll CI, checks, or reviews in a loop; check once when you need the result.
    - If `gh` reports a rate limit, stop calling it and continue with local git, or report what you could not verify.
    """
}
