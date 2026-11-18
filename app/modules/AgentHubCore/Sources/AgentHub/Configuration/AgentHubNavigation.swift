//
//  AgentHubNavigation.swift
//  AgentHub
//
//  Cross-workspace jumps: session → review, session → Jira ticket, ticket → session.
//

import Foundation

extension AgentHubProvider {
  /// Opens Reviews with the pull request a session is linked to selected.
  public func showReview(owner: String, repository: String, number: Int) {
    gitHubReviewsViewModel.focusPullRequest(owner: owner, repository: repository, number: number)
    AgentHubAppCommand.selectWorkspace(.reviews)
  }

  /// Opens the Sprint board with the ticket's detail panel open.
  public func showJiraTicket(_ key: String) {
    jiraSprintViewModel.openTicket(key)
    AgentHubAppCommand.selectWorkspace(.sprint)
  }

  /// Opens a linked session in Sessions, starting to monitor it when needed.
  func showSession(_ link: JiraLinkedSession) {
    let sessionsViewModel =
      link.provider == .claude ? claudeSessionsViewModel : codexSessionsViewModel
    if let session = link.session {
      if !sessionsViewModel.isMonitoring(sessionId: session.id) {
        sessionsViewModel.startMonitoring(session: session)
      }
      globalSessionSelectionRouter.select(
        providerKind: link.provider,
        sessionId: session.id,
        projectPath: session.projectPath,
        itemId: link.itemID,
        session: session
      )
    }
    AgentHubAppCommand.selectWorkspace(.sessions)
  }

  /// Sessions linked to each Jira ticket key, across Claude and Codex.
  func jiraLinkedSessions() -> [String: [JiraLinkedSession]] {
    jiraSprintViewModel.sessionLinker.links(
      from: [claudeSessionsViewModel, codexSessionsViewModel],
      knownProjectKeys: jiraSprintViewModel.knownProjectKeys
    )
  }

  /// A ticket reached Done, so its local work is finished: delete the worktrees
  /// named after it and stop monitoring the sessions that worked on it. Git
  /// refuses to remove a worktree with uncommitted changes; that failure is
  /// reported on the board instead of forced.
  func cleanUpLocalWork(forDoneTicket key: String) async {
    let plan = JiraTicketCleanup.plan(
      ticketKey: key,
      linkedSessions: jiraLinkedSessions()[key.uppercased()] ?? [],
      repositories: [
        .claude: claudeSessionsViewModel.selectedRepositories,
        .codex: codexSessionsViewModel.selectedRepositories,
      ]
    )
    guard !plan.isEmpty else { return }
    let viewModels: [SessionProviderKind: CLISessionsViewModel] = [
      .claude: claudeSessionsViewModel, .codex: codexSessionsViewModel,
    ]
    var removed = 0
    var failures: [String] = []
    for item in plan.worktrees {
      guard let viewModel = viewModels[item.provider] else { continue }
      if await viewModel.deleteWorktree(item.worktree) {
        removed += 1
        for other in viewModels.values {
          other.archiveMonitoredSessions(inWorktreePath: item.worktree.path)
          other.forgetOwnedWorktreePath(item.worktree.path)
        }
      } else {
        failures.append(
          "\(item.worktree.name): "
            + (viewModel.worktreeDeletionError?.message ?? "worktree could not be deleted"))
        viewModel.clearWorktreeDeletionError()
      }
    }
    for item in plan.sessions {
      viewModels[item.provider]?.stopMonitoring(sessionId: item.sessionID)
    }
    jiraSprintViewModel.reportCleanup(
      ticketKey: key, removedWorktrees: removed, archivedSessions: plan.sessions.count, failures: failures)
  }
}
