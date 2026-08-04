//
//  GitHubProjectReviewModels.swift
//  AgentHubGitHub
//

import Foundation

public struct GitHubProjectView: Identifiable, Equatable, Sendable {
  public let id: String
  public let number: Int
  public let name: String
  public let filter: String?
  public let layout: String

  public init(id: String, number: Int, name: String, filter: String?, layout: String) {
    self.id = id
    self.number = number
    self.name = name
    self.filter = filter
    self.layout = layout
  }
}

public struct GitHubReviewProject: Identifiable, Equatable, Sendable {
  public let id: String
  public let ownerLogin: String
  public let ownerType: String
  public let number: Int
  public let title: String
  public let url: String
  public let views: [GitHubProjectView]

  public init(
    id: String,
    ownerLogin: String,
    ownerType: String,
    number: Int,
    title: String,
    url: String,
    views: [GitHubProjectView]
  ) {
    self.id = id
    self.ownerLogin = ownerLogin
    self.ownerType = ownerType
    self.number = number
    self.title = title
    self.url = url
    self.views = views
  }

  public var displayName: String {
    "\(ownerLogin) / \(title)"
  }
}

public struct GitHubProjectPullRequest: Identifiable, Equatable, Sendable {
  public let id: String
  public let number: Int
  public let title: String
  public let url: String
  public let repositoryName: String
  public let repositoryNameWithOwner: String
  public let authorLogin: String?
  public let updatedAt: Date?
  public let isDraft: Bool
  public let state: String
  public let projectStatus: String?

  public init(
    id: String,
    number: Int,
    title: String,
    url: String,
    repositoryName: String,
    repositoryNameWithOwner: String,
    authorLogin: String?,
    updatedAt: Date?,
    isDraft: Bool,
    state: String,
    projectStatus: String?
  ) {
    self.id = id
    self.number = number
    self.title = title
    self.url = url
    self.repositoryName = repositoryName
    self.repositoryNameWithOwner = repositoryNameWithOwner
    self.authorLogin = authorLogin
    self.updatedAt = updatedAt
    self.isDraft = isDraft
    self.state = state
    self.projectStatus = projectStatus
  }
}
