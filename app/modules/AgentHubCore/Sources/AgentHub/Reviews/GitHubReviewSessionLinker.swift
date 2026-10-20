//
//  GitHubReviewSessionLinker.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation

struct GitHubReviewSessionLaunch: Equatable, Sendable {
  let pullRequestID: String
  let pullRequestURL: String
  let provider: SessionProviderKind
  let pendingID: UUID?
  let sessionID: String?
  let projectPath: String
  let launchedAt: Date

  init(
    pullRequestID: String,
    pullRequestURL: String,
    provider: SessionProviderKind,
    pendingID: UUID?,
    sessionID: String? = nil,
    projectPath: String,
    launchedAt: Date
  ) {
    self.pullRequestID = pullRequestID
    self.pullRequestURL = pullRequestURL
    self.provider = provider
    self.pendingID = pendingID
    self.sessionID = sessionID
    self.projectPath = projectPath
    self.launchedAt = launchedAt
  }

  init?(_ association: GitHubReviewSessionAssociation) {
    guard let provider = association.providerKind else { return nil }
    self.init(
      pullRequestID: association.pullRequestID,
      pullRequestURL: association.pullRequestURL,
      provider: provider,
      pendingID: association.pendingUUID,
      sessionID: association.sessionID,
      projectPath: association.projectPath,
      launchedAt: association.createdAt
    )
  }

  var association: GitHubReviewSessionAssociation {
    GitHubReviewSessionAssociation(
      pullRequestID: pullRequestID,
      pullRequestURL: pullRequestURL,
      provider: provider,
      pendingID: pendingID,
      sessionID: sessionID,
      projectPath: projectPath,
      createdAt: launchedAt
    )
  }

  func resolving(to sessionID: String) -> GitHubReviewSessionLaunch {
    GitHubReviewSessionLaunch(
      pullRequestID: pullRequestID,
      pullRequestURL: pullRequestURL,
      provider: provider,
      pendingID: pendingID,
      sessionID: sessionID,
      projectPath: projectPath,
      launchedAt: launchedAt
    )
  }
}

struct GitHubReviewSessionInventory {
  let provider: SessionProviderKind
  let sessions: [CLISession]
  let pendingSessions: [PendingHubSession]
  let resolvedPendingSessionIDs: [UUID: String]
  let customNames: [String: String]
  let statuses: [String: SessionStatus]
  /// Jira ticket keys each session works on (branch, name, prompt), so a PR titled
  /// "XFA-123: …" links to the session that implements XFA-123.
  var ticketKeysBySessionID: [String: [String]] = [:]
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
        if let sessionID = launch.sessionID,
          let session = inventory.sessions.first(where: { $0.id == sessionID })
        {
          insert(
            link(for: session, inventory: inventory),
            into: &candidates
          )
        } else if let pendingID = launch.pendingID,
          let sessionID = inventory.resolvedPendingSessionIDs[pendingID],
          let session = inventory.sessions.first(where: { $0.id == sessionID })
        {
          insert(
            link(for: session, inventory: inventory),
            into: &candidates
          )
        } else if let pendingID = launch.pendingID,
          let pending = inventory.pendingSessions.first(where: {
            $0.id == pendingID
          })
        {
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
              displayName: pending.worktree.name,
              status: nil
            ),
            into: &candidates
          )
        }
      }

      let pullRequestKeys = ticketKeys(inTitle: pullRequest.title)
      if !pullRequestKeys.isEmpty {
        // Same ticket is not enough: one ticket often spans several repositories,
        // and a session on the Organization Service must not claim the Web Flow PR.
        for session in inventory.sessions
        where !Set(inventory.ticketKeysBySessionID[session.id] ?? []).isDisjoint(with: pullRequestKeys)
          && sessionPath(session.projectPath, belongsTo: pullRequest.repositoryName)
        {
          insert(link(for: session, inventory: inventory), into: &candidates)
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

  /// Whether a session's working directory is inside the PR's repository: a path
  /// component named like the repository, or a worktree named `<repo>-…`.
  static func sessionPath(_ path: String, belongsTo repositoryName: String) -> Bool {
    let name = repositoryName.lowercased()
    guard !name.isEmpty else { return false }
    return path.lowercased().split(separator: "/").contains { component in
      component == name || component.hasPrefix(name + "-")
    }
  }

  static func ticketKeys(inTitle title: String) -> Set<String> {
    let range = NSRange(title.startIndex..., in: title)
    return Set(
      ticketKeyPattern.matches(in: title, range: range).compactMap { match in
        Range(match.range, in: title).map { String(title[$0]).uppercased() }
      })
  }

  private static let ticketKeyPattern = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])[A-Z][A-Z0-9]+-[0-9]+(?![0-9])"#)

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
          || message.localizedCaseInsensitiveContains("independent code review")
          || message.localizedCaseInsensitiveContains("read-only review")
      }
  }
}
