//
//  GitHubProjectReviewService.swift
//  AgentHubGitHub
//

import Foundation

public protocol GitHubProjectReviewServiceProtocol: Sendable {
  func listProjects() async throws -> [GitHubReviewProject]
  func listPullRequests(
    project: GitHubReviewProject,
    view: GitHubProjectView,
    limit: Int
  ) async throws -> [GitHubProjectPullRequest]
  /// When the exhausted GitHub API quota frees up, to explain a rate-limit error.
  func rateLimitResetDate() async -> Date?
  /// The GitHub login `gh` is authenticated as.
  func viewerLogin() async -> String?
  /// Pull requests mentioning any of the ticket keys, grouped per key, with whether
  /// each is approved. Batched: a few searches for a whole sprint.
  func ticketPullRequests(forKeys keys: [String], owner: String?) async throws
    -> [String: [GitHubTicketPullRequest]]
  /// Pull requests whose title or body mentions `text` (e.g. a Jira key), open first.
  func searchPullRequests(mentioning text: String, owner: String?) async throws
    -> [GitHubProjectPullRequest]
}

extension GitHubProjectReviewServiceProtocol {
  public func rateLimitResetDate() async -> Date? { nil }
  public func viewerLogin() async -> String? { nil }
  public func ticketPullRequests(forKeys keys: [String], owner: String?) async throws
    -> [String: [GitHubTicketPullRequest]]
  { [:] }
  public func searchPullRequests(mentioning text: String, owner: String?) async throws
    -> [GitHubProjectPullRequest]
  { [] }
}

public actor GitHubProjectReviewService: GitHubProjectReviewServiceProtocol {
  struct StatusPredicate: Equatable, Sendable {
    let value: String
    let isNegated: Bool
  }

  struct SearchPlan: Equatable, Sendable {
    let query: String
    let statusPredicates: [StatusPredicate]
    let state: String?
    let merged: Bool?
  }

  struct ProjectFieldValues: Equatable, Sendable {
    let status: String?
    let priority: String?
  }

  private struct SearchPullRequest: Decodable {
    struct Repository: Decodable {
      let name: String
      let nameWithOwner: String
    }

    struct Author: Decodable {
      let login: String
    }

    let id: String
    let number: Int
    let title: String
    let url: String
    let repository: Repository
    let author: Author?
    let updatedAt: Date?
    let isDraft: Bool
    let state: String
  }

  private let cli: GitHubCLIService

  public init(cli: GitHubCLIService = GitHubCLIService()) {
    self.cli = cli
  }

  public func listProjects() async throws -> [GitHubReviewProject] {
    let query = """
      query {
        viewer {
          login
          projectsV2(first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
            nodes { id number title url closed views(first: 50) { nodes { id number name filter layout } } }
          }
          organizations(first: 50) {
            nodes {
              login
              projectsV2(first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
                nodes { id number title url closed views(first: 50) { nodes { id number name filter layout } } }
              }
            }
          }
        }
      }
      """
    let json = try await cli.runAuthenticatedCommand(
      ["api", "graphql", "-f", "query=\(query)"],
      timeout: 45
    )
    return try Self.decodeProjects(json)
  }

  /// Uses GitHub's search API, which has its own quota (30 requests a minute),
  /// separate from the GraphQL quota reviews and PR status use.
  public func searchPullRequests(mentioning text: String, owner: String?) async throws
    -> [GitHubProjectPullRequest]
  {
    var arguments = [
      "search", "prs", text,
      "--limit", "20",
      "--json", "id,number,title,url,repository,author,updatedAt,isDraft,state",
    ]
    if let owner, !owner.isEmpty { arguments += ["--owner", owner] }
    let json = try await cli.runAuthenticatedCommand(arguments, timeout: 30)
    return Self.sortedForTicket(try Self.decodeSearchPullRequests(json))
  }

  /// Open pull requests first, then most recently updated.
  static func sortedForTicket(_ pullRequests: [GitHubProjectPullRequest]) -> [GitHubProjectPullRequest] {
    pullRequests.sorted { lhs, rhs in
      let lhsOpen = lhs.state.lowercased() == "open"
      let rhsOpen = rhs.state.lowercased() == "open"
      if lhsOpen != rhsOpen { return lhsOpen }
      return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
    }
  }

  public func ticketPullRequests(forKeys keys: [String], owner: String?) async throws
    -> [String: [GitHubTicketPullRequest]]
  {
    var result: [String: [GitHubTicketPullRequest]] = [:]
    // GitHub search allows at most five OR operators per query.
    for start in stride(from: 0, to: keys.count, by: 6) {
      let chunk = Array(keys[start..<min(start + 6, keys.count)])
      let terms = Self.orTerms(chunk)
      let all = try await searchWithBody(terms: terms, owner: owner, approvedOnly: false)
      let approvedURLs = Set(
        try await searchWithBody(terms: terms, owner: owner, approvedOnly: true).map(\.pullRequest.url))
      for (key, pullRequests) in Self.groupByMentionedKey(all, keys: chunk) {
        result[key] = pullRequests.map {
          GitHubTicketPullRequest(pullRequest: $0, isApproved: approvedURLs.contains($0.url))
        }
      }
    }
    return result
  }

  /// `gh` quotes a single argument with spaces as a phrase, so `OR` must be its own argument.
  static func orTerms(_ keys: [String]) -> [String] {
    keys.enumerated().flatMap { index, key in index == 0 ? [key] : ["OR", key] }
  }

  private func searchWithBody(terms: [String], owner: String?, approvedOnly: Bool) async throws
    -> [(pullRequest: GitHubProjectPullRequest, body: String)]
  {
    var arguments = ["search", "prs"] + terms + [
      "--limit", "100",
      "--json", "id,number,title,url,repository,author,updatedAt,isDraft,state,body",
    ]
    if approvedOnly { arguments += ["--review", "approved"] }
    if let owner, !owner.isEmpty { arguments += ["--owner", owner] }
    let json = try await cli.runAuthenticatedCommand(arguments, timeout: 30)
    let pullRequests = try Self.decodeSearchPullRequests(json)
    let bodies = Self.decodeBodies(json)
    return pullRequests.map { ($0, bodies[$0.url] ?? "") }
  }

  static func decodeBodies(_ json: String) -> [String: String] {
    guard let data = json.data(using: .utf8),
      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [:] }
    var bodies: [String: String] = [:]
    for item in items {
      if let url = item["url"] as? String { bodies[url] = item["body"] as? String ?? "" }
    }
    return bodies
  }

  /// A pull request belongs to a key when its title or body mentions it exactly
  /// (`XFA-12` does not match `XFA-123`).
  static func groupByMentionedKey(
    _ items: [(pullRequest: GitHubProjectPullRequest, body: String)],
    keys: [String]
  ) -> [String: [GitHubProjectPullRequest]] {
    var grouped: [String: [GitHubProjectPullRequest]] = [:]
    for item in items {
      let text = item.pullRequest.title + "\n" + item.body
      for key in keys where mentions(text, key: key) {
        grouped[key, default: []].append(item.pullRequest)
      }
    }
    return grouped
  }

  static func mentions(_ text: String, key: String) -> Bool {
    let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: key) + "(?![0-9])"
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// One REST call (`/user`), not GraphQL.
  public func viewerLogin() async -> String? {
    guard let output = try? await cli.runAuthenticatedCommand(["api", "user", "--jq", ".login"], timeout: 15)
    else { return nil }
    let login = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return login.isEmpty ? nil : login
  }

  /// `gh api rate_limit` does not count against the quota it reports.
  public func rateLimitResetDate() async -> Date? {
    guard let json = try? await cli.runAuthenticatedCommand(["api", "rate_limit"], timeout: 15)
    else { return nil }
    return Self.rateLimitResetDate(fromRateLimitJSON: json)
  }

  /// The reset of an exhausted bucket (GraphQL first, it is what reviews use),
  /// otherwise the GraphQL reset.
  static func rateLimitResetDate(fromRateLimitJSON json: String) -> Date? {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let resources = object["resources"] as? [String: Any]
    else { return nil }
    func bucket(_ name: String) -> (remaining: Int, reset: Date)? {
      guard let entry = resources[name] as? [String: Any],
        let remaining = entry["remaining"] as? Int,
        let reset = entry["reset"] as? Double
      else { return nil }
      return (remaining, Date(timeIntervalSince1970: reset))
    }
    let buckets = ["graphql", "core", "search"].compactMap(bucket)
    return buckets.first(where: { $0.remaining == 0 })?.reset ?? bucket("graphql")?.reset
  }

  public func listPullRequests(
    project: GitHubReviewProject,
    view: GitHubProjectView,
    limit: Int = 200
  ) async throws -> [GitHubProjectPullRequest] {
    let plan = Self.searchPlan(for: view.filter ?? "")
    var arguments = ["search", "prs"]
    if !plan.query.isEmpty {
      arguments.append(plan.query)
    }
    if let state = plan.state {
      arguments += ["--state", state]
    }
    if let merged = plan.merged {
      arguments.append("--merged=\(merged)")
    }
    arguments += [
      "--project", "\(project.ownerLogin)/\(project.number)",
      "--limit", "\(max(1, min(limit, 1_000)))",
      "--draft=false",
      "--json", "id,number,title,url,repository,author,updatedAt,isDraft,state",
    ]

    let json = try await cli.runAuthenticatedCommand(arguments, timeout: 45)
    var pullRequests = try Self.decodeSearchPullRequests(json)
      .filter { !$0.isDraft }

    guard !pullRequests.isEmpty else { return [] }

    let projectFields = try await projectFieldValues(
      pullRequestIDs: pullRequests.map(\.id),
      projectID: project.id
    )
    pullRequests = pullRequests.compactMap { pullRequest in
      let fields = projectFields[pullRequest.id]
      guard Self.matches(status: fields?.status, predicates: plan.statusPredicates) else {
        return nil
      }
      return GitHubProjectPullRequest(
        id: pullRequest.id,
        number: pullRequest.number,
        title: pullRequest.title,
        url: pullRequest.url,
        repositoryName: pullRequest.repositoryName,
        repositoryNameWithOwner: pullRequest.repositoryNameWithOwner,
        authorLogin: pullRequest.authorLogin,
        updatedAt: pullRequest.updatedAt,
        isDraft: pullRequest.isDraft,
        state: pullRequest.state,
        projectStatus: fields?.status,
        projectPriority: fields?.priority
      )
    }
    return pullRequests
  }

  private func projectFieldValues(
    pullRequestIDs: [String],
    projectID: String
  ) async throws -> [String: ProjectFieldValues] {
    var result: [String: ProjectFieldValues] = [:]
    for batchStart in stride(from: 0, to: pullRequestIDs.count, by: 50) {
      let batchEnd = min(batchStart + 50, pullRequestIDs.count)
      let batch = Array(pullRequestIDs[batchStart..<batchEnd])
      let query = """
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on PullRequest {
              id
              projectItems(first: 100) {
                nodes {
                  project { id }
                  status: fieldValueByName(name: "Status") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name }
                  }
                  priority: fieldValueByName(name: "Priority") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name }
                  }
                }
              }
            }
          }
        }
        """
      var arguments = ["api", "graphql", "-f", "query=\(query)"]
      for id in batch {
        arguments += ["-F", "ids[]=\(id)"]
      }
      let json = try await cli.runAuthenticatedCommand(arguments, timeout: 45)
      let decoded = try Self.decodeProjectFieldValues(json, projectID: projectID)
      for (id, values) in decoded {
        result[id] = values
      }
    }
    return result
  }

  static func searchPlan(for filter: String) -> SearchPlan {
    var retainedTokens: [String] = []
    var statusPredicates: [StatusPredicate] = []
    var state: String?
    var merged: Bool?

    for token in tokens(in: filter) {
      let lowercaseToken = token.lowercased()
      if lowercaseToken.hasPrefix("status:") || lowercaseToken.hasPrefix("-status:") {
        let isNegated = lowercaseToken.hasPrefix("-status:")
        guard let separator = token.firstIndex(of: ":") else { continue }
        let rawValue = token[token.index(after: separator)...]
          .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !rawValue.isEmpty {
          statusPredicates.append(StatusPredicate(value: rawValue, isNegated: isNegated))
        }
        continue
      }
      if lowercaseToken == "is:pr" || lowercaseToken == "is:issue" {
        continue
      }
      if lowercaseToken == "is:open" || lowercaseToken == "-is:closed" {
        state = "open"
        continue
      }
      if lowercaseToken == "is:closed" || lowercaseToken == "-is:open" {
        state = "closed"
        continue
      }
      if lowercaseToken == "is:merged" {
        merged = true
        continue
      }
      if lowercaseToken == "-is:merged" {
        merged = false
        continue
      }
      if lowercaseToken == "is:draft" || lowercaseToken == "-is:draft"
        || lowercaseToken == "draft:true" || lowercaseToken == "draft:false"
      {
        continue
      }
      retainedTokens.append(token)
    }

    return SearchPlan(
      query: retainedTokens.joined(separator: " "),
      statusPredicates: statusPredicates,
      state: state,
      merged: merged
    )
  }

  static func decodeProjects(_ json: String) throws -> [GitHubReviewProject] {
    guard let data = json.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dataObject = root["data"] as? [String: Any],
      let viewer = dataObject["viewer"] as? [String: Any],
      let viewerLogin = viewer["login"] as? String
    else {
      throw GitHubCLIError.parseError("Invalid GitHub Projects response")
    }

    var projects: [GitHubReviewProject] = []
    projects += parseProjectConnection(
      viewer["projectsV2"],
      ownerLogin: viewerLogin,
      ownerType: "User"
    )
    if let organizations = viewer["organizations"] as? [String: Any],
      let nodes = organizations["nodes"] as? [[String: Any]]
    {
      for organization in nodes {
        guard let login = organization["login"] as? String else { continue }
        projects += parseProjectConnection(
          organization["projectsV2"],
          ownerLogin: login,
          ownerType: "Organization"
        )
      }
    }

    var seen = Set<String>()
    return projects.filter { seen.insert($0.id).inserted }
      .sorted {
        if $0.ownerLogin == $1.ownerLogin { return $0.title < $1.title }
        return $0.ownerLogin < $1.ownerLogin
      }
  }

  static func decodeSearchPullRequests(_ json: String) throws -> [GitHubProjectPullRequest] {
    guard let data = json.data(using: .utf8) else {
      throw GitHubCLIError.parseError("Invalid pull request response encoding")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode([SearchPullRequest].self, from: data).map { pullRequest in
        GitHubProjectPullRequest(
          id: pullRequest.id,
          number: pullRequest.number,
          title: pullRequest.title,
          url: pullRequest.url,
          repositoryName: pullRequest.repository.name,
          repositoryNameWithOwner: pullRequest.repository.nameWithOwner,
          authorLogin: pullRequest.author?.login,
          updatedAt: pullRequest.updatedAt,
          isDraft: pullRequest.isDraft,
          state: pullRequest.state,
          projectStatus: nil,
          projectPriority: nil
        )
      }
    } catch {
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  static func decodeProjectFieldValues(
    _ json: String,
    projectID: String
  ) throws -> [String: ProjectFieldValues] {
    guard let data = json.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dataObject = root["data"] as? [String: Any],
      let nodes = dataObject["nodes"] as? [Any]
    else {
      throw GitHubCLIError.parseError("Invalid project status response")
    }

    var fieldValues: [String: ProjectFieldValues] = [:]
    for case let node as [String: Any] in nodes {
      guard let id = node["id"] as? String else { continue }
      var matchingValues: ProjectFieldValues?
      if let projectItems = node["projectItems"] as? [String: Any],
        let itemNodes = projectItems["nodes"] as? [[String: Any]]
      {
        for item in itemNodes {
          guard let project = item["project"] as? [String: Any],
            project["id"] as? String == projectID
          else { continue }
          let status = (item["status"] as? [String: Any])?["name"] as? String
          let priority = (item["priority"] as? [String: Any])?["name"] as? String
          matchingValues = ProjectFieldValues(status: status, priority: priority)
          break
        }
      }
      if let matchingValues {
        fieldValues[id] = matchingValues
      }
    }
    return fieldValues
  }

  private static func parseProjectConnection(
    _ value: Any?,
    ownerLogin: String,
    ownerType: String
  ) -> [GitHubReviewProject] {
    guard let connection = value as? [String: Any],
      let nodes = connection["nodes"] as? [[String: Any]]
    else { return [] }

    return nodes.compactMap { node in
      guard node["closed"] as? Bool != true,
        let id = node["id"] as? String,
        let number = node["number"] as? Int,
        let title = node["title"] as? String,
        let url = node["url"] as? String
      else { return nil }
      let viewsObject = node["views"] as? [String: Any]
      let viewNodes = viewsObject?["nodes"] as? [[String: Any]] ?? []
      let views = viewNodes.compactMap { view -> GitHubProjectView? in
        guard let viewID = view["id"] as? String,
          let viewNumber = view["number"] as? Int,
          let name = view["name"] as? String,
          let layout = view["layout"] as? String
        else { return nil }
        return GitHubProjectView(
          id: viewID,
          number: viewNumber,
          name: name,
          filter: view["filter"] as? String,
          layout: layout
        )
      }
      return GitHubReviewProject(
        id: id,
        ownerLogin: ownerLogin,
        ownerType: ownerType,
        number: number,
        title: title,
        url: url,
        views: views
      )
    }
  }

  private static func tokens(in query: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var isInsideQuotes = false
    for character in query {
      if character == "\"" {
        isInsideQuotes.toggle()
        current.append(character)
      } else if character.isWhitespace, !isInsideQuotes {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }
    return tokens
  }

  private static func matches(status: String?, predicates: [StatusPredicate]) -> Bool {
    predicates.allSatisfy { predicate in
      let isEqual = status?.localizedCaseInsensitiveCompare(predicate.value) == .orderedSame
      return predicate.isNegated ? !isEqual : isEqual
    }
  }
}
