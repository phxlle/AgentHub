import AgentHubGitHub
import AgentHubSessionGraph
import Foundation

enum AgentWorkflowListScope: String, CaseIterable, Identifiable, Sendable {
  case active = "Active"
  case completed = "Completed"

  var id: Self { self }
}

enum DetectedAgentRole: String, Sendable {
  case implementer
  case reviewer
}

enum AgentDetectionConfidence: Int, Comparable, Sendable {
  case low
  case medium
  case high

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct AgentSessionObservation: Sendable, Equatable {
  let session: CLISession
  let provider: SessionProviderKind
  let repositoryPath: String
  let branchName: String?
  let linkedPullRequests: [GitHubPullRequestURLReference]
  let transcriptEvidence: String?

  init(
    session: CLISession,
    provider: SessionProviderKind,
    repositoryPath: String,
    branchName: String?,
    linkedPullRequests: [GitHubPullRequestURLReference],
    transcriptEvidence: String? = nil
  ) {
    self.session = session
    self.provider = provider
    self.repositoryPath = repositoryPath
    self.branchName = branchName
    self.linkedPullRequests = linkedPullRequests
    self.transcriptEvidence = transcriptEvidence
  }
}

struct DetectedAgentSession: Identifiable, Sendable, Equatable {
  var id: String { "\(provider.rawValue.lowercased()):\(session.id)" }

  let session: CLISession
  let provider: SessionProviderKind
  let role: DetectedAgentRole
  let roleConfidence: AgentDetectionConfidence
  let roleReason: String
}

struct WorkflowSessionLibraryItem: Identifiable, Sendable, Equatable {
  var id: String { assignment.id }

  let assignment: DetectedAgentSession
  let workflowTitle: String?
  let isAnalyzed: Bool
}

struct DetectedPullRequest: Sendable, Equatable {
  let number: Int
  let title: String
  let url: String
  let state: GitHubPullRequestState
  let headBranch: String

  init(
    number: Int,
    title: String,
    url: String,
    state: GitHubPullRequestState,
    headBranch: String
  ) {
    self.number = number
    self.title = title
    self.url = url
    self.state = state
    self.headBranch = headBranch
  }

  init(_ pullRequest: GitHubPullRequest) {
    number = pullRequest.number
    title = pullRequest.title
    url = pullRequest.url
    state = pullRequest.stateKind
    headBranch = pullRequest.headRefName
  }
}

struct DetectedBranchWorkflow: Identifiable, Sendable, Equatable {
  let id: String
  var ticketKey: String?
  let repositoryPath: String
  let repositoryName: String
  let branchName: String?
  var implementerSessions: [DetectedAgentSession]
  var reviewerSessions: [DetectedAgentSession]
  var linkedPullRequests: [GitHubPullRequestURLReference]
  var pullRequest: DetectedPullRequest?
  let lastActivityAt: Date
  var manualWorkflowID: String? = nil
  var automatedReview: AutomatedReviewRecord? = nil
  var isArchived = false

  var isCompleted: Bool {
    isArchived || pullRequest?.state == .merged
  }

  var primaryImplementer: DetectedAgentSession? {
    implementerSessions.first
  }

  var primaryReviewer: DetectedAgentSession? {
    reviewerSessions.first
  }
}

struct DetectedTicketWorkflow: Identifiable, Sendable, Equatable {
  let id: String
  let ticketKey: String?
  let summary: String?
  var branches: [DetectedBranchWorkflow]

  var lastActivityAt: Date {
    branches.map(\.lastActivityAt).max() ?? .distantPast
  }

  var isArchived: Bool {
    !branches.isEmpty && branches.allSatisfy(\.isArchived)
  }
}

enum AgentSessionWorkflowClassifier {
  private struct GroupKey: Hashable {
    let ticketKey: String?
    let repositoryPath: String
    let branchName: String?
  }

  private struct ClassifiedObservation {
    let observation: AgentSessionObservation
    let ticketKey: String?
    let role: DetectedAgentRole
    let roleConfidence: AgentDetectionConfidence
    let roleReason: String
  }

  static func classify(_ observations: [AgentSessionObservation]) -> [DetectedBranchWorkflow] {
    let classified = observations.map(classify)
    let knownBranches = knownBranchNames(in: classified)
    var grouped: [GroupKey: [ClassifiedObservation]] = [:]

    for item in classified {
      let repositoryPath = normalizedPath(item.observation.repositoryPath)
      let rawBranch = normalizedBranch(item.observation.branchName)
      let resolvedBranch: String?
      if isGenericBranch(rawBranch), let ticketKey = item.ticketKey {
        let candidates = knownBranches["\(ticketKey)|\(repositoryPath)", default: []]
        resolvedBranch = candidates.count == 1 ? candidates.first : rawBranch
      } else {
        resolvedBranch = rawBranch
      }

      grouped[
        GroupKey(
          ticketKey: item.ticketKey,
          repositoryPath: repositoryPath,
          branchName: resolvedBranch
        ),
        default: []
      ].append(item)
    }

    return grouped.map { key, items in
      let assignments = items.map { item in
        DetectedAgentSession(
          session: item.observation.session,
          provider: item.observation.provider,
          role: item.role,
          roleConfidence: item.roleConfidence,
          roleReason: item.roleReason
        )
      }
      let implementers =
        assignments
        .filter { $0.role == .implementer }
        .sorted(by: assignmentSort)
      let reviewers =
        assignments
        .filter { $0.role == .reviewer }
        .sorted(by: assignmentSort)
      let links = Array(
        Set(items.flatMap { $0.observation.linkedPullRequests })
      ).sorted { $0.number < $1.number }
      let newest = assignments.map(\.session.lastActivityAt).max() ?? .distantPast
      let branchID = key.branchName ?? "unknown-branch"
      let ticketID = key.ticketKey ?? "unassigned"

      return DetectedBranchWorkflow(
        id: "\(ticketID)|\(key.repositoryPath)|\(branchID)",
        ticketKey: key.ticketKey,
        repositoryPath: key.repositoryPath,
        repositoryName: URL(fileURLWithPath: key.repositoryPath).lastPathComponent,
        branchName: key.branchName,
        implementerSessions: implementers,
        reviewerSessions: reviewers,
        linkedPullRequests: links,
        pullRequest: nil,
        lastActivityAt: newest
      )
    }
    .sorted { lhs, rhs in
      if lhs.lastActivityAt != rhs.lastActivityAt {
        return lhs.lastActivityAt > rhs.lastActivityAt
      }
      return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
  }

  static func ticketKey(in values: [String?]) -> String? {
    let pattern = #"(?i)\b([A-Z][A-Z0-9]{1,11}-[0-9]+)\b"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }

    for value in values.compactMap({ $0 }) where !value.isEmpty {
      let range = NSRange(value.startIndex..<value.endIndex, in: value)
      guard let match = expression.firstMatch(in: value, range: range),
        let swiftRange = Range(match.range(at: 1), in: value)
      else {
        continue
      }
      return String(value[swiftRange]).uppercased()
    }
    return nil
  }

  static func pullRequestReferences(in values: [String?]) -> [GitHubPullRequestURLReference] {
    let pattern = #"https?://(?:www\.)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    var references: [GitHubPullRequestURLReference] = []

    for value in values.compactMap({ $0 }) where !value.isEmpty {
      let range = NSRange(value.startIndex..<value.endIndex, in: value)
      for match in expression.matches(in: value, range: range) {
        guard let swiftRange = Range(match.range, in: value),
          let reference = GitHubPullRequestURLReference(urlString: String(value[swiftRange]))
        else {
          continue
        }
        references.append(reference)
      }
    }
    return Array(Set(references)).sorted { $0.number < $1.number }
  }

  static func workflows(
    from branches: [DetectedBranchWorkflow],
    scope: AgentWorkflowListScope
  ) -> [DetectedTicketWorkflow] {
    let filtered = branches.filter { branch in
      scope == .completed ? branch.isCompleted : !branch.isCompleted
    }
    let groups = Dictionary(grouping: filtered) { branch in
      branch.manualWorkflowID ?? branch.ticketKey ?? "unassigned:\(branch.repositoryPath)"
    }

    return groups.map { id, branches in
      let ticketKey = branches.compactMap(\.ticketKey).first
      let summary = summaryText(for: branches)
      return DetectedTicketWorkflow(
        id: id,
        ticketKey: ticketKey,
        summary: summary,
        branches: branches.sorted { $0.lastActivityAt > $1.lastActivityAt }
      )
    }
    .sorted { lhs, rhs in
      if lhs.lastActivityAt != rhs.lastActivityAt {
        return lhs.lastActivityAt > rhs.lastActivityAt
      }
      return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
  }

  private static func classify(_ observation: AgentSessionObservation) -> ClassifiedObservation {
    let branch = observation.branchName ?? observation.session.branchName
    let firstMessage = observation.session.firstMessage
    let lastMessage = observation.session.lastMessage
    let ticketKey = ticketKey(
      in: [
        branch, firstMessage, lastMessage, observation.session.slug, observation.transcriptEvidence,
      ]
    )
    let firstText = firstMessage?.lowercased() ?? ""
    let remainingText = [lastMessage, observation.session.slug, branch]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")
    let reviewScore =
      score(firstText, terms: reviewTerms, weight: 3)
      + score(remainingText, terms: reviewTerms, weight: 1)
    let implementScore =
      score(firstText, terms: implementationTerms, weight: 3)
      + score(remainingText, terms: implementationTerms, weight: 1)
    let responseToReviewScore =
      score(firstText, terms: responseToReviewTerms, weight: 5)
      + score(remainingText, terms: responseToReviewTerms, weight: 2)

    let role: DetectedAgentRole
    let confidence: AgentDetectionConfidence
    let reason: String
    if reviewScore >= implementScore + 2 && responseToReviewScore == 0 {
      role = .reviewer
      confidence = reviewScore >= 6 ? .high : .medium
      reason = "Review language detected in the session"
    } else {
      role = .implementer
      if implementScore + responseToReviewScore >= 6 {
        confidence = .high
        reason =
          responseToReviewScore > 0
          ? "Implementation work responding to review feedback"
          : "Implementation language detected in the session"
      } else if reviewScore == 0 {
        confidence = .medium
        reason = "Default writer role for this branch"
      } else {
        confidence = .low
        reason = "Mixed implementation and review language"
      }
    }

    return ClassifiedObservation(
      observation: observation,
      ticketKey: ticketKey,
      role: role,
      roleConfidence: confidence,
      roleReason: reason
    )
  }

  private static func knownBranchNames(
    in items: [ClassifiedObservation]
  ) -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    for item in items {
      guard let ticketKey = item.ticketKey,
        let branch = normalizedBranch(item.observation.branchName),
        !isGenericBranch(branch)
      else {
        continue
      }
      let repositoryPath = normalizedPath(item.observation.repositoryPath)
      result["\(ticketKey)|\(repositoryPath)", default: []].insert(branch)
    }
    return result
  }

  private static func normalizedPath(_ path: String) -> String {
    WorktreeModuleResolver.normalizedDirectoryPath(path)
  }

  private static func normalizedBranch(_ branch: String?) -> String? {
    guard let value = branch?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func isGenericBranch(_ branch: String?) -> Bool {
    guard let branch else { return true }
    return ["main", "master", "develop", "development", "trunk", "head"].contains(
      branch.lowercased()
    )
  }

  private static func score(_ text: String, terms: [String], weight: Int) -> Int {
    terms.reduce(into: 0) { total, term in
      if text.contains(term) {
        total += weight
      }
    }
  }

  private static func assignmentSort(
    _ lhs: DetectedAgentSession,
    _ rhs: DetectedAgentSession
  ) -> Bool {
    if lhs.session.isActive != rhs.session.isActive {
      return lhs.session.isActive
    }
    if lhs.roleConfidence != rhs.roleConfidence {
      return lhs.roleConfidence > rhs.roleConfidence
    }
    return lhs.session.lastActivityAt > rhs.session.lastActivityAt
  }

  private static func summaryText(for branches: [DetectedBranchWorkflow]) -> String? {
    if let pullRequestTitle = branches.compactMap(\.pullRequest?.title).first,
      !pullRequestTitle.isEmpty
    {
      return pullRequestTitle
    }
    return
      branches
      .flatMap { $0.implementerSessions + $0.reviewerSessions }
      .compactMap { $0.session.firstMessage }
      .first { !$0.isEmpty }
  }

  private static let reviewTerms = [
    "review", "code review", "review this", "review the", "reviewer", "review pull request",
    "pr review", "review changes", "beoordeel", "controleer de code", "nakijken",
    "findings", "read-only review", "audit the changes",
  ]

  private static let implementationTerms = [
    "implement", "implementation", "build", "fix", "change request", "write the code",
    "update the code", "maak", "bouw", "pas aan", "implementeer", "los op", "repareer",
  ]

  private static let responseToReviewTerms = [
    "address review", "fix review", "review feedback", "review comments", "requested changes",
    "verwerk de review", "reviewopmerkingen", "feedback verwerken",
  ]
}
