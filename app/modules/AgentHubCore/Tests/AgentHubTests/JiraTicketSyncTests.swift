import AgentHubGitHub
import AgentWorkflowJiraCLI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Jira ticket sync rules")
struct JiraTicketSyncTests {
  private func pr(_ state: String, approved: Bool) -> GitHubTicketPullRequest {
    GitHubTicketPullRequest(
      pullRequest: GitHubProjectPullRequest(
        id: UUID().uuidString, number: 1, title: "t", url: UUID().uuidString, repositoryName: "r",
        repositoryNameWithOwner: "o/r", authorLogin: nil, updatedAt: nil, isDraft: false,
        state: state, projectStatus: nil, projectPriority: nil),
      isApproved: approved)
  }

  @Test("All merged → done; all open approved → UX review; otherwise in progress")
  func rules() {
    #expect(JiraTicketSync.target(pullRequests: [pr("merged", approved: false), pr("MERGED", approved: true)], hasOpenSession: false)?.target == .done)
    #expect(JiraTicketSync.target(pullRequests: [pr("open", approved: true), pr("merged", approved: true)], hasOpenSession: false)?.target == .uxReview)
    #expect(JiraTicketSync.target(pullRequests: [pr("open", approved: true), pr("open", approved: false)], hasOpenSession: false)?.target == .inProgress)
    #expect(JiraTicketSync.target(pullRequests: [], hasOpenSession: true)?.target == .inProgress)
    #expect(JiraTicketSync.target(pullRequests: [], hasOpenSession: false) == nil)
  }

  @Test("Closed, unmerged pull requests are ignored")
  func abandonedPullRequests() {
    #expect(JiraTicketSync.target(pullRequests: [pr("closed", approved: false)], hasOpenSession: false) == nil)
    #expect(JiraTicketSync.target(pullRequests: [pr("closed", approved: false), pr("merged", approved: false)], hasOpenSession: false)?.target == .done)
  }

  @Test("Status names come from the workflow, skipping Won't fix")
  func statusNames() {
    let statuses: [(name: String, category: String?)] = [
      ("To Do", "new"), ("In Progress", "indeterminate"), ("UX Review needed", "indeterminate"),
      ("Won't fix", "done"), ("Done", "done"),
    ]
    #expect(JiraTicketSync.statusName(for: .done, among: statuses) == "Done")
    #expect(JiraTicketSync.statusName(for: .uxReview, among: statuses) == "UX Review needed")
    #expect(JiraTicketSync.statusName(for: .inProgress, among: statuses) == "In Progress")
    #expect(JiraTicketSync.statusName(for: .uxReview, among: [("To Do", "new")]) == nil)
  }

  @Test("Sessions link to pull requests whose title carries their ticket key")
  func reviewsLinkTicketSessions() {
    let session = CLISession(
      id: "s1", projectPath: "/tmp/r", branchName: "codex/xfa-9-login", lastActivityAt: .now)
    let pullRequest = GitHubProjectPullRequest(
      id: "pr", number: 7, title: "XFA-9: fix login", url: "https://github.com/o/r/pull/7",
      repositoryName: "r", repositoryNameWithOwner: "o/r", authorLogin: "me", updatedAt: nil,
      isDraft: false, state: "open", projectStatus: nil, projectPriority: nil)
    let inventory = GitHubReviewSessionInventory(
      provider: .codex, sessions: [session], pendingSessions: [], resolvedPendingSessionIDs: [:],
      customNames: [:], statuses: [:], ticketKeysBySessionID: ["s1": ["XFA-9"]])
    let other = GitHubReviewSessionInventory(
      provider: .codex, sessions: [session], pendingSessions: [], resolvedPendingSessionIDs: [:],
      customNames: [:], statuses: [:], ticketKeysBySessionID: ["s1": ["XFA-90"]])

    #expect(GitHubReviewSessionLinker.links(for: pullRequest, launches: [], inventories: [inventory]).map(\.session.id) == ["s1"])
    #expect(GitHubReviewSessionLinker.links(for: pullRequest, launches: [], inventories: [other]).isEmpty)
    #expect(GitHubReviewSessionLinker.ticketKeys(inTitle: "xfa-1 and XFA-22: x") == ["XFA-22"])
  }

  @Test("A ticket session only links to PRs in its own repository")
  func ticketSessionsStayInTheirRepository() {
    let orgSession = CLISession(
      id: "org", projectPath: "/Users/me/Github/xfa-organizations-service", branchName: "xfa-3119-x",
      lastActivityAt: .now)
    let worktreeSession = CLISession(
      id: "wt", projectPath: "/Users/me/Github/xfa-web-flow-xfa-3119", branchName: "xfa-3119-y",
      lastActivityAt: .now)
    func pr(_ repo: String) -> GitHubProjectPullRequest {
      GitHubProjectPullRequest(
        id: repo, number: 1, title: "XFA-3119: change", url: "https://github.com/o/\(repo)/pull/1",
        repositoryName: repo, repositoryNameWithOwner: "o/\(repo)", authorLogin: nil, updatedAt: nil,
        isDraft: false, state: "open", projectStatus: nil, projectPriority: nil)
    }
    let inventory = GitHubReviewSessionInventory(
      provider: .codex, sessions: [orgSession, worktreeSession], pendingSessions: [],
      resolvedPendingSessionIDs: [:], customNames: [:], statuses: [:],
      ticketKeysBySessionID: ["org": ["XFA-3119"], "wt": ["XFA-3119"]])

    #expect(
      GitHubReviewSessionLinker.links(for: pr("xfa-web-flow"), launches: [], inventories: [inventory])
        .map(\.session.id) == ["wt"])
    #expect(
      GitHubReviewSessionLinker.links(for: pr("xfa-organizations-service"), launches: [], inventories: [inventory])
        .map(\.session.id) == ["org"])
    #expect(!GitHubReviewSessionLinker.sessionPath("/Users/me/Github/xfa-web", belongsTo: "xfa-web-flow"))
  }
}
