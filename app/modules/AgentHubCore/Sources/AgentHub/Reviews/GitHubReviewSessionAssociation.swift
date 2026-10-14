//
//  GitHubReviewSessionAssociation.swift
//  AgentHub
//

import Foundation
import GRDB

protocol GitHubReviewSessionStoreProtocol: Sendable {
  func saveGitHubReviewSessionAssociation(
    _ association: GitHubReviewSessionAssociation
  ) async throws
  func githubReviewSessionAssociations() async throws -> [GitHubReviewSessionAssociation]
}

struct GitHubReviewSessionAssociation:
  Codable, Equatable, Sendable, FetchableRecord, PersistableRecord
{
  var pullRequestID: String
  var pullRequestURL: String
  var provider: String
  var pendingID: String?
  var sessionID: String?
  var projectPath: String
  var createdAt: Date
  var updatedAt: Date

  static var databaseTableName: String { "github_review_sessions" }

  init(
    pullRequestID: String,
    pullRequestURL: String,
    provider: SessionProviderKind,
    pendingID: UUID?,
    sessionID: String?,
    projectPath: String,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.pullRequestID = pullRequestID
    self.pullRequestURL = pullRequestURL
    self.provider = provider.rawValue
    self.pendingID = pendingID?.uuidString
    self.sessionID = sessionID
    self.projectPath = projectPath
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  var providerKind: SessionProviderKind? {
    SessionProviderKind(rawValue: provider)
  }

  var pendingUUID: UUID? {
    pendingID.flatMap(UUID.init(uuidString:))
  }
}
