//
//  JiraTicketCleanup.swift
//  AgentHub
//
//  When a ticket reaches Done, the local work for it is finished too: the
//  worktrees named after it (and the sessions inside them) go, and sessions
//  that worked on it elsewhere stop being monitored. Pure, so the plan is
//  testable without git or view models.
//

import Foundation

struct JiraTicketCleanupPlan: Equatable {
  struct WorktreeItem: Equatable {
    let provider: SessionProviderKind
    let worktree: WorktreeBranch
  }

  struct SessionItem: Equatable {
    let provider: SessionProviderKind
    let sessionID: String
  }

  /// Linked worktrees to delete. Deleting one also archives its sessions.
  var worktrees: [WorktreeItem] = []
  /// Monitored sessions on the ticket that live outside any linked worktree.
  var sessions: [SessionItem] = []

  var isEmpty: Bool { worktrees.isEmpty && sessions.isEmpty }
}

enum JiraTicketCleanup {
  /// - Sessions linked to the ticket inside a worktree → that worktree is deleted.
  /// - Worktrees whose branch is named after the ticket → deleted, sessions or not.
  /// - Other monitored sessions linked to the ticket → archived.
  static func plan(
    ticketKey: String,
    linkedSessions: [JiraLinkedSession],
    repositories: [SessionProviderKind: [SelectedRepository]]
  ) -> JiraTicketCleanupPlan {
    let key = ticketKey.uppercased()
    let projectKeys = Set(key.split(separator: "-").first.map { [String($0)] } ?? [])
    var plan = JiraTicketCleanupPlan()
    var worktreePaths: Set<String> = []

    func addWorktree(_ worktree: WorktreeBranch, provider: SessionProviderKind) {
      guard worktree.isWorktree else { return }
      let path = WorktreeModuleResolver.normalizedDirectoryPath(worktree.path)
      guard worktreePaths.insert(path).inserted else { return }
      plan.worktrees.append(.init(provider: provider, worktree: worktree))
    }

    for (provider, repos) in repositories.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      for worktree in repos.flatMap(\.worktrees) where worktree.isWorktree {
        let keys = JiraTicketKeyDetector.keys(
          branchName: worktree.name, customName: nil, prompt: nil, knownProjectKeys: projectKeys)
        if keys.contains(key) { addWorktree(worktree, provider: provider) }
      }
    }

    for link in linkedSessions {
      guard let session = link.session else { continue }  // still launching
      let repos = repositories[link.provider] ?? []
      let match = WorktreeModuleResolver.bestMatch(for: session.projectPath, repositories: repos)
      // A worktree goes with the ticket only when its branch is the ticket's; a
      // session linked by its prompt alone must not take a shared worktree down.
      if let match, match.worktree.isWorktree,
        JiraTicketKeyDetector.keys(
          branchName: session.branchName ?? match.worktree.name, customName: nil, prompt: nil,
          knownProjectKeys: projectKeys
        ).contains(key)
      {
        addWorktree(match.worktree, provider: link.provider)
      } else if link.isMonitored {
        plan.sessions.append(.init(provider: link.provider, sessionID: session.id))
      }
    }
    return plan
  }
}
