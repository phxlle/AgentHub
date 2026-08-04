import Foundation

public struct JiraTicketSnapshot: Codable, Equatable, Sendable {
  public let key: String
  public let summary: String
  public let issueType: String?
  public let status: String?
  public let assignee: String?
  public let description: String?
  public let fetchedAt: Date

  public init(
    key: String,
    summary: String,
    issueType: String? = nil,
    status: String? = nil,
    assignee: String? = nil,
    description: String? = nil,
    fetchedAt: Date = Date()
  ) {
    self.key = key
    self.summary = summary
    self.issueType = issueType
    self.status = status
    self.assignee = assignee
    self.description = description
    self.fetchedAt = fetchedAt
  }
}

public enum JiraTicketReaderError: Error, Equatable, Sendable {
  case invalidTicketKey
  case commandFailed(exitCode: Int32, message: String)
  case invalidResponse
}
