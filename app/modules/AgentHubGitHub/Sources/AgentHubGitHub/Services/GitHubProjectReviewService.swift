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

    guard !plan.statusPredicates.isEmpty, !pullRequests.isEmpty else {
      return pullRequests
    }

    let statuses = try await projectStatuses(
      pullRequestIDs: pullRequests.map(\.id),
      projectID: project.id
    )
    pullRequests = pullRequests.compactMap { pullRequest in
      let status = statuses[pullRequest.id] ?? nil
      guard Self.matches(status: status, predicates: plan.statusPredicates) else { return nil }
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
        projectStatus: status
      )
    }
    return pullRequests
  }

  private func projectStatuses(
    pullRequestIDs: [String],
    projectID: String
  ) async throws -> [String: String?] {
    var result: [String: String?] = [:]
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
                  fieldValueByName(name: "Status") {
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
      let decoded = try Self.decodeProjectStatuses(json, projectID: projectID)
      for (id, status) in decoded {
        result[id] = status
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
          projectStatus: nil
        )
      }
    } catch {
      throw GitHubCLIError.parseError(error.localizedDescription)
    }
  }

  static func decodeProjectStatuses(
    _ json: String,
    projectID: String
  ) throws -> [String: String?] {
    guard let data = json.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dataObject = root["data"] as? [String: Any],
      let nodes = dataObject["nodes"] as? [Any]
    else {
      throw GitHubCLIError.parseError("Invalid project status response")
    }

    var statuses: [String: String?] = [:]
    for case let node as [String: Any] in nodes {
      guard let id = node["id"] as? String else { continue }
      var matchingStatus: String?
      if let projectItems = node["projectItems"] as? [String: Any],
        let itemNodes = projectItems["nodes"] as? [[String: Any]]
      {
        for item in itemNodes {
          guard let project = item["project"] as? [String: Any],
            project["id"] as? String == projectID
          else { continue }
          if let value = item["fieldValueByName"] as? [String: Any] {
            matchingStatus = value["name"] as? String
          }
          break
        }
      }
      statuses[id] = matchingStatus
    }
    return statuses
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
