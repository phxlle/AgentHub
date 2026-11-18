import Foundation
import Testing

@testable import AgentHubCore

@Suite("Jira ticket cleanup plan")
struct JiraTicketCleanupTests {
  private static let repo = "/tmp/xfa-api"
  private static let ticketWorktree = WorktreeBranch(
    name: "xfa-12-fix-login", path: "/tmp/xfa-api-xfa-12", isWorktree: true)
  private static let otherWorktree = WorktreeBranch(
    name: "xfa-99-other", path: "/tmp/xfa-api-xfa-99", isWorktree: true)
  private static let main = WorktreeBranch(name: "main", path: repo, isWorktree: false)

  private static func repositories(_ worktrees: [WorktreeBranch]) -> [SessionProviderKind: [SelectedRepository]] {
    [.claude: [SelectedRepository(path: repo, name: "xfa-api", worktrees: worktrees)]]
  }

  private static func link(
    _ id: String, path: String, branch: String?, monitored: Bool = true, provider: SessionProviderKind = .claude
  ) -> JiraLinkedSession {
    let session = CLISession(id: id, projectPath: path, branchName: branch)
    return JiraLinkedSession(
      provider: provider, itemID: id, title: id, branchName: branch, lastActivityAt: Date(),
      isPending: false, isMonitored: monitored, session: session)
  }

  @Test("A worktree named after the ticket is deleted, even without sessions")
  func worktreeByBranchName() {
    let plan = JiraTicketCleanup.plan(
      ticketKey: "XFA-12", linkedSessions: [],
      repositories: Self.repositories([Self.main, Self.ticketWorktree, Self.otherWorktree]))

    #expect(plan.worktrees.map(\.worktree.path) == [Self.ticketWorktree.path])
    #expect(plan.sessions.isEmpty)
  }

  @Test("A session in the ticket's worktree points at that worktree once; nested paths resolve to the root")
  func sessionInsideWorktree() {
    let links = [
      Self.link("a", path: Self.ticketWorktree.path, branch: "xfa-12-fix-login"),
      Self.link("b", path: Self.ticketWorktree.path + "/ios", branch: "xfa-12-fix-login"),
    ]
    let plan = JiraTicketCleanup.plan(
      ticketKey: "xfa-12", linkedSessions: links,
      repositories: Self.repositories([Self.main, Self.ticketWorktree]))

    #expect(plan.worktrees.map(\.worktree.path) == [Self.ticketWorktree.path])
    #expect(plan.sessions.isEmpty)
  }

  @Test("A session in the main checkout is archived, the checkout is never deleted")
  func sessionInMainRepo() {
    let links = [
      Self.link("a", path: Self.repo, branch: "xfa-12-fix-login"),
      Self.link("b", path: Self.repo, branch: "xfa-12-fix-login", monitored: false),
    ]
    let plan = JiraTicketCleanup.plan(
      ticketKey: "XFA-12", linkedSessions: links, repositories: Self.repositories([Self.main]))

    #expect(plan.worktrees.isEmpty)
    #expect(plan.sessions == [.init(provider: .claude, sessionID: "a")])
  }

  @Test("A session linked only by its prompt does not take another ticket's worktree down")
  func promptLinkedSessionInSharedWorktree() {
    let links = [Self.link("a", path: Self.otherWorktree.path, branch: "xfa-99-other")]
    let plan = JiraTicketCleanup.plan(
      ticketKey: "XFA-12", linkedSessions: links,
      repositories: Self.repositories([Self.main, Self.otherWorktree]))

    #expect(plan.worktrees.isEmpty)
    #expect(plan.sessions == [.init(provider: .claude, sessionID: "a")])
  }

  @Test("Pending sessions and unknown providers are skipped")
  func pendingSkipped() {
    let pending = JiraLinkedSession(
      provider: .codex, itemID: "p", title: "Starting", branchName: nil, lastActivityAt: Date(),
      isPending: true, isMonitored: true, session: nil)
    let plan = JiraTicketCleanup.plan(
      ticketKey: "XFA-12", linkedSessions: [pending], repositories: Self.repositories([Self.main]))

    #expect(plan.isEmpty)
  }
}
