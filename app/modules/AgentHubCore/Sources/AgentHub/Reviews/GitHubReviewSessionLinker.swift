//
//  GitHubReviewSessionLinker.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation

struct GitHubReviewSessionLaunch: Equatable, Sendable {
  let pullRequestID: String
  let provider: SessionProviderKind
  let pendingID: UUID
  let projectPath: String
  let launchedAt: Date
}

struct GitHubReviewSessionInventory {
  let provider: SessionProviderKind
  let sessions: [CLISession]
  let pendingSessions: [PendingHubSession]
  let resolvedPendingSessionIDs: [UUID: String]
  let customNames: [String: String]
  let statuses: [String: SessionStatus]
}

struct GitHubReviewSessionLink: Identifiable, Equatable {
  let provider: SessionProviderKind
  let session: CLISession
  let itemID: String
  let isPending: Bool
  let displayName: String
  let status: SessionStatus?

  var id: String { itemID }

  var statusText: String {
    if isPending {
      return "Starting"
    }
    if let status {
      return status.displayName
    }
    return session.isActive ? "Active" : "Available"
  }
}

enum GitHubReviewSessionLinker {
  static func links(
    for pullRequest: GitHubProjectPullRequest,
    launches: [GitHubReviewSessionLaunch],
    inventories: [GitHubReviewSessionInventory]
  ) -> [GitHubReviewSessionLink] {
    var candidates: [String: GitHubReviewSessionLink] = [:]

    for inventory in inventories {
      let providerLaunches = launches.filter {
        $0.pullRequestID == pullRequest.id && $0.provider == inventory.provider
      }
      for launch in providerLaunches {
        if let sessionID = inventory.resolvedPendingSessionIDs[launch.pendingID],
          let session = inventory.sessions.first(where: { $0.id == sessionID })
        {
          insert(
            link(for: session, inventory: inventory),
            into: &candidates
          )
        } else if let pending = inventory.pendingSessions.first(where: {
          $0.id == launch.pendingID
        }) {
          let session = pending.placeholderSession
          insert(
            GitHubReviewSessionLink(
              provider: inventory.provider,
              session: session,
              itemID: SidebarSessionItemID.pending(
                provider: inventory.provider,
                pendingId: pending.id
              ),
              isPending: true,
              displayName: "Starting review",
              status: nil
            ),
            into: &candidates
          )
        }
      }

      for session in inventory.sessions where isReviewSession(session, for: pullRequest) {
        insert(
          link(for: session, inventory: inventory),
          into: &candidates
        )
      }
    }

    var latestByProvider: [SessionProviderKind: GitHubReviewSessionLink] = [:]
    for candidate in candidates.values {
      if let current = latestByProvider[candidate.provider],
        current.session.lastActivityAt >= candidate.session.lastActivityAt
      {
        continue
      }
      latestByProvider[candidate.provider] = candidate
    }

    return latestByProvider.values.sorted {
      if $0.session.lastActivityAt == $1.session.lastActivityAt {
        return $0.provider.rawValue < $1.provider.rawValue
      }
      return $0.session.lastActivityAt > $1.session.lastActivityAt
    }
  }

  private static func insert(
    _ link: GitHubReviewSessionLink,
    into candidates: inout [String: GitHubReviewSessionLink]
  ) {
    if let existing = candidates[link.id],
      existing.session.lastActivityAt >= link.session.lastActivityAt
    {
      return
    }
    candidates[link.id] = link
  }

  private static func link(
    for session: CLISession,
    inventory: GitHubReviewSessionInventory
  ) -> GitHubReviewSessionLink {
    GitHubReviewSessionLink(
      provider: inventory.provider,
      session: session,
      itemID: SidebarSessionItemID.monitored(
        provider: inventory.provider,
        sessionId: session.id
      ),
      isPending: false,
      displayName: inventory.customNames[session.id] ?? session.displayName,
      status: inventory.statuses[session.id]
    )
  }

  private static func isReviewSession(
    _ session: CLISession,
    for pullRequest: GitHubProjectPullRequest
  ) -> Bool {
    [session.firstMessage, session.lastMessage]
      .compactMap { $0 }
      .contains { message in
        guard message.contains(pullRequest.url) else { return false }
        return message.localizedCaseInsensitiveContains(
          "Review this pull request independently"
        )
          || message.localizedCaseInsensitiveContains("read-only review")
      }
  }
}
