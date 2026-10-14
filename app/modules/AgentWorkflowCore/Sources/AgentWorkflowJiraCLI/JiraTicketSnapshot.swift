import Foundation

public struct JiraTicketSnapshot: Codable, Equatable, Sendable {
  public let key: String
  public let summary: String
  public let issueType: String?
  public let status: String?
  public let assignee: String?
  public let assigneeAccountId: String?
  public let assigneeEmail: String?
  public let assigneeAvatarURL: String?
  public let description: String?
  /// Jira status category key: `new`, `indeterminate`, or `done`.
  public let statusCategory: String?
  public let priority: String?
  public let fetchedAt: Date

  public init(
    key: String,
    summary: String,
    issueType: String? = nil,
    status: String? = nil,
    assignee: String? = nil,
    assigneeAccountId: String? = nil,
    assigneeEmail: String? = nil,
    assigneeAvatarURL: String? = nil,
    description: String? = nil,
    statusCategory: String? = nil,
    priority: String? = nil,
    fetchedAt: Date = Date()
  ) {
    self.key = key
    self.summary = summary
    self.issueType = issueType
    self.status = status
    self.assignee = assignee
    self.assigneeAccountId = assigneeAccountId
    self.assigneeEmail = assigneeEmail
    self.assigneeAvatarURL = assigneeAvatarURL
    self.description = description
    self.statusCategory = statusCategory
    self.priority = priority
    self.fetchedAt = fetchedAt
  }
}

extension JiraTicketSnapshot {
  /// The same ticket in another workflow status, for updating the board locally
  /// after a transition without refetching the sprint.
  public func withStatus(_ status: String, category: String?) -> JiraTicketSnapshot {
    JiraTicketSnapshot(
      key: key,
      summary: summary,
      issueType: issueType,
      status: status,
      assignee: assignee,
      assigneeAccountId: assigneeAccountId,
      assigneeEmail: assigneeEmail,
      assigneeAvatarURL: assigneeAvatarURL,
      description: description,
      statusCategory: category,
      priority: priority,
      fetchedAt: fetchedAt
    )
  }
}

public enum JiraTicketReaderError: Error, Equatable, Sendable {
  case invalidTicketKey
  case commandFailed(exitCode: Int32, message: String)
  case invalidResponse
}
