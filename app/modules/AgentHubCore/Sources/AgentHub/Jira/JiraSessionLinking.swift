//
//  JiraSessionLinking.swift
//  AgentHub
//
//  Links agent sessions to Jira tickets by the ticket key they carry: the
//  branch name (`xfa-123-fix-login`), a Jira browse URL or "Jira ticket KEY"
//  in the first prompt, or a custom name that starts with the key.
//

import Foundation

enum JiraTicketKeyDetector {
  private static let explicitPatterns = [
    #"atlassian\.net/browse/([A-Za-z][A-Za-z0-9]+-\d+)"#,
    #"[Jj]ira ticket ([A-Z][A-Z0-9]+-\d+)"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }
  private static let prefixedKey = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9]+-\d+)(?:$|[-_ :])"#)

  /// Ticket keys for a session. Explicit references (browse URLs, the Sprint tab's
  /// pick-up prompt) always count. Branch and name prefixes only count for known
  /// project keys, so branches like `release-2` don't become tickets.
  static func keys(
    branchName: String?,
    customName: String?,
    prompt: String?,
    knownProjectKeys: Set<String>
  ) -> [String] {
    var keys: [String] = []
    func add(_ key: String) {
      let key = key.uppercased()
      if !keys.contains(key) { keys.append(key) }
    }

    if let prompt {
      let text = String(prompt.prefix(4000))
      for pattern in explicitPatterns {
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
          if let keyRange = Range(match.range(at: 1), in: text) { add(String(text[keyRange])) }
        }
      }
    }

    let candidates = [
      branchName.map { String($0.split(separator: "/").last ?? "") },
      customName,
    ].compactMap { $0 }
    for candidate in candidates {
      let range = NSRange(candidate.startIndex..., in: candidate)
      guard
        let match = prefixedKey.firstMatch(in: candidate, range: range),
        let keyRange = Range(match.range(at: 1), in: candidate)
      else { continue }
      let key = String(candidate[keyRange]).uppercased()
      if let project = key.split(separator: "-").first, knownProjectKeys.contains(String(project)) {
        add(key)
      }
    }
    return keys
  }
}

/// A session (or a session still launching) that works on a Jira ticket.
struct JiraLinkedSession: Identifiable, Equatable {
  let provider: SessionProviderKind
  let itemID: String
  let title: String
  let branchName: String?
  let lastActivityAt: Date
  let isPending: Bool
  let isMonitored: Bool
  let session: CLISession?

  var id: String { itemID }
}

/// Builds ticket key → sessions for the Sprint board. Detection is cached per
/// session input so re-rendering the board doesn't re-run regexes over every
/// session's first prompt.
@MainActor
final class JiraSessionLinker {
  private var cache: [String: [String]] = [:]

  func links(
    from viewModels: [CLISessionsViewModel],
    knownProjectKeys: Set<String>
  ) -> [String: [JiraLinkedSession]] {
    var result: [String: [JiraLinkedSession]] = [:]
    var seen: Set<String> = []

    for viewModel in viewModels {
      let provider = viewModel.providerKind
      let monitored = viewModel.monitoredSessionList
      let monitoredIDs = Set(monitored.map(\.id))
      let sessions =
        monitored
        + viewModel.selectedRepositories.flatMap(\.worktrees).flatMap(\.sessions)

      for session in sessions {
        let itemID = SidebarSessionItemID.monitored(provider: provider, sessionId: session.id)
        guard seen.insert(itemID).inserted else { continue }
        let customName = viewModel.sessionCustomNames[session.id]
        let keys = cachedKeys(
          id: itemID,
          branchName: session.branchName,
          customName: customName,
          prompt: session.firstMessage,
          knownProjectKeys: knownProjectKeys
        )
        guard !keys.isEmpty else { continue }
        let link = JiraLinkedSession(
          provider: provider,
          itemID: itemID,
          title: customName ?? session.slug ?? session.firstMessage ?? session.shortId,
          branchName: session.branchName,
          lastActivityAt: session.lastActivityAt,
          isPending: false,
          isMonitored: monitoredIDs.contains(session.id),
          session: session
        )
        for key in keys { result[key, default: []].append(link) }
      }

      for pending in viewModel.pendingHubSessions {
        let itemID = SidebarSessionItemID.pending(provider: provider, pendingId: pending.id)
        let keys = cachedKeys(
          id: itemID,
          branchName: nil,
          customName: nil,
          prompt: pending.initialPrompt,
          knownProjectKeys: knownProjectKeys
        )
        for key in keys {
          result[key, default: []].append(
            JiraLinkedSession(
              provider: provider,
              itemID: itemID,
              title: "Starting \(provider.rawValue)…",
              branchName: nil,
              lastActivityAt: pending.startedAt,
              isPending: true,
              isMonitored: true,
              session: nil
            ))
        }
      }
    }
    return result.mapValues { $0.sorted { $0.lastActivityAt > $1.lastActivityAt } }
  }

  /// Ticket keys for one session, cached by its inputs.
  func cachedKeys(
    id: String,
    branchName: String?,
    customName: String?,
    prompt: String?,
    knownProjectKeys: Set<String>
  ) -> [String] {
    let cacheKey = [
      id, branchName ?? "", customName ?? "", String(prompt?.count ?? 0),
      knownProjectKeys.sorted().joined(separator: ","),
    ].joined(separator: "|")
    if let cached = cache[cacheKey] { return cached }
    let keys = JiraTicketKeyDetector.keys(
      branchName: branchName,
      customName: customName,
      prompt: prompt,
      knownProjectKeys: knownProjectKeys
    )
    cache[cacheKey] = keys
    return keys
  }
}
