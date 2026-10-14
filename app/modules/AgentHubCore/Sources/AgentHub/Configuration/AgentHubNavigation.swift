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
}
