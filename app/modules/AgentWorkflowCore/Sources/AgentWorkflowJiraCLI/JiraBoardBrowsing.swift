import Foundation

public struct JiraBoard: Codable, Equatable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  public let location: String?

  public init(id: Int, name: String, location: String? = nil) {
    self.id = id
    self.name = name
    self.location = location
  }
}

public struct JiraSprint: Codable, Equatable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  /// `active`, `future`, or `closed`.
  public let state: String
  public let startDate: Date?
  public let endDate: Date?

  public init(id: Int, name: String, state: String, startDate: Date? = nil, endDate: Date? = nil) {
    self.id = id
    self.name = name
    self.state = state
    self.startDate = startDate
    self.endDate = endDate
  }

  public var isActive: Bool { state == "active" }
}

/// The Jira site and user the Atlassian CLI is logged in as.
public struct JiraAccount: Equatable, Sendable {
  public let site: String
  public let email: String

  public init(site: String, email: String) {
    self.site = site
    self.email = email
  }

  public func browseURL(forKey key: String) -> URL? {
    URL(string: "https://\(site)/browse/\(key)")
  }
}

public protocol JiraBoardBrowsing: Sendable {
  func currentAccount() async throws -> JiraAccount
  func boards() async throws -> [JiraBoard]
  /// Active and future sprints of a board, active first.
  func openSprints(boardID: Int) async throws -> [JiraSprint]
}

extension ACLITicketReader: JiraBoardBrowsing {
  public func currentAccount() async throws -> JiraAccount {
    let result = try await runner.run(arguments: ["jira", "auth", "status"])
    try Self.requireSuccess(result)
    let text = String(data: result.standardOutput, encoding: .utf8) ?? ""
    func value(_ label: String) -> String? {
      text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("\(label):") }
        .map { String($0.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces) }
    }
    guard let site = value("Site"), let email = value("Email") else {
      throw JiraTicketReaderError.invalidResponse
    }
    return JiraAccount(site: site, email: email)
  }

  public func boards() async throws -> [JiraBoard] {
    let result = try await runner.run(arguments: ["jira", "board", "search", "--json", "--limit", "100"])
    try Self.requireSuccess(result)
    guard
      let object = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
      let values = object["values"] as? [[String: Any]]
    else {
      throw JiraTicketReaderError.invalidResponse
    }
    return values.compactMap { board in
      guard let id = board["id"] as? Int, let name = board["name"] as? String else { return nil }
      return JiraBoard(id: id, name: name, location: board["location"] as? String)
    }
  }

  public func openSprints(boardID: Int) async throws -> [JiraSprint] {
    let result = try await runner.run(arguments: [
      "jira", "board", "list-sprints", "--id", String(boardID), "--state", "active,future", "--json",
    ])
    try Self.requireSuccess(result)
    guard
      let object = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
      let values = object["sprints"] as? [[String: Any]]
    else {
      throw JiraTicketReaderError.invalidResponse
    }
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func date(_ value: Any?) -> Date? {
      guard let string = value as? String else { return nil }
      return dates.date(from: string)
        ?? ISO8601DateFormatter().date(from: string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
    let sprints = values.compactMap { sprint -> JiraSprint? in
      guard let id = sprint["id"] as? Int, let name = sprint["name"] as? String else { return nil }
      return JiraSprint(
        id: id,
        name: name,
        state: sprint["state"] as? String ?? "future",
        startDate: date(sprint["startDate"]),
        endDate: date(sprint["endDate"])
      )
    }
    return sprints.filter(\.isActive) + sprints.filter { !$0.isActive }
  }
}
