import Foundation

public protocol JiraTicketReading: Sendable {
  func ticket(key: String) async throws -> JiraTicketSnapshot
}

public protocol JiraTicketSearching: Sendable {
  func searchTickets(jql: String, limit: Int) async throws -> [JiraTicketSnapshot]
}

public protocol JiraTicketTransitioning: Sendable {
  /// Moves a ticket to the named workflow status (e.g. "In Progress").
  func transition(key: String, toStatus status: String) async throws
}

public protocol JiraAuthenticating: Sendable {
  /// Starts the Atlassian CLI browser (OAuth) login and returns once it finishes.
  func authenticate() async throws
}

public actor ACLITicketReader: JiraTicketReading, JiraTicketSearching,
  JiraAuthenticating, JiraTicketTransitioning
{
  private static let fields = [
    "key",
    "issuetype",
    "summary",
    "status",
    "assignee",
    "priority",
    "description",
  ]

  let runner: any JiraCLICommandRunning
  private let now: @Sendable () -> Date

  public init(
    runner: any JiraCLICommandRunning = JiraCLIProcessRunner(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.runner = runner
    self.now = now
  }

  public func ticket(key: String) async throws -> JiraTicketSnapshot {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard Self.isValidTicketKey(normalizedKey) else {
      throw JiraTicketReaderError.invalidTicketKey
    }

    let result = try await runner.run(arguments: [
      "jira",
      "workitem",
      "view",
      normalizedKey,
      "--json",
      "--fields",
      Self.fields.joined(separator: ","),
    ])
    try Self.requireSuccess(result)

    return try Self.parse(
      data: result.standardOutput,
      fallbackKey: normalizedKey,
      fetchedAt: now()
    )
  }

  public func searchTickets(jql: String, limit: Int = 100) async throws -> [JiraTicketSnapshot] {
    let result = try await runner.run(arguments: [
      "jira",
      "workitem",
      "search",
      "--jql",
      jql,
      "--json",
      "--limit",
      String(limit),
      "--fields",
      Self.searchFields.joined(separator: ","),
    ])
    try Self.requireSuccess(result)
    guard let objects = try JSONSerialization.jsonObject(with: result.standardOutput) as? [Any]
    else {
      throw JiraTicketReaderError.invalidResponse
    }
    let fetchedAt = now()
    return objects.compactMap { object in
      guard let object = object as? [String: Any], let key = object["key"] as? String else {
        return nil
      }
      return try? Self.parse(object: object, fallbackKey: key, fetchedAt: fetchedAt)
    }
  }

  public func transition(key: String, toStatus status: String) async throws {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard Self.isValidTicketKey(normalizedKey) else {
      throw JiraTicketReaderError.invalidTicketKey
    }
    try Self.requireSuccess(
      try await runner.run(arguments: [
        "jira", "workitem", "transition", "--key", normalizedKey, "--status", status, "--yes",
      ]))
  }

  public func authenticate() async throws {
    try Self.requireSuccess(try await runner.run(arguments: ["jira", "auth", "login", "--web"]))
  }

  private static let searchFields = ["key", "issuetype", "summary", "status", "assignee", "priority"]

  static func requireSuccess(_ result: JiraCLICommandResult) throws {
    guard result.exitCode == 0 else {
      let message =
        String(data: result.standardError, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw JiraTicketReaderError.commandFailed(
        exitCode: result.exitCode,
        message: message
      )
    }
  }

  private static func isValidTicketKey(_ key: String) -> Bool {
    key.range(of: #"^[A-Z][A-Z0-9]+-[0-9]+$"#, options: .regularExpression) != nil
  }

  private static func parse(
    data: Data,
    fallbackKey: String,
    fetchedAt: Date
  ) throws -> JiraTicketSnapshot {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw JiraTicketReaderError.invalidResponse
    }
    return try parse(object: object, fallbackKey: fallbackKey, fetchedAt: fetchedAt)
  }

  private static func parse(
    object: [String: Any],
    fallbackKey: String,
    fetchedAt: Date
  ) throws -> JiraTicketSnapshot {
    guard
      let fields = object["fields"] as? [String: Any],
      let summary = fields["summary"] as? String
    else {
      throw JiraTicketReaderError.invalidResponse
    }

    let key = object["key"] as? String ?? fallbackKey
    let issueType = (fields["issuetype"] as? [String: Any])?["name"] as? String
    let status = (fields["status"] as? [String: Any])?["name"] as? String
    let assigneeObject = fields["assignee"] as? [String: Any]
    let assignee = assigneeObject?["displayName"] as? String
    let statusCategory =
      ((fields["status"] as? [String: Any])?["statusCategory"] as? [String: Any])?["key"] as? String
    let priority = (fields["priority"] as? [String: Any])?["name"] as? String

    return JiraTicketSnapshot(
      key: key,
      summary: summary,
      issueType: issueType,
      status: status,
      assignee: assignee,
      assigneeAccountId: assigneeObject?["accountId"] as? String,
      assigneeEmail: assigneeObject?["emailAddress"] as? String,
      assigneeAvatarURL: (assigneeObject?["avatarUrls"] as? [String: Any])?["48x48"] as? String,
      description: descriptionText(from: fields["description"]),
      statusCategory: statusCategory,
      priority: priority,
      fetchedAt: fetchedAt
    )
  }

  private static func descriptionText(from value: Any?) -> String? {
    if let text = value as? String {
      return text
    }
    guard let value else { return nil }
    let text = renderADF(value)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// Flattens Atlassian Document Format to plain text, keeping paragraph and list structure.
  private static func renderADF(_ value: Any, listDepth: Int = 0) -> String {
    if let values = value as? [Any] {
      return values.map { renderADF($0, listDepth: listDepth) }.joined()
    }
    guard let node = value as? [String: Any] else { return "" }
    let type = node["type"] as? String ?? ""
    let content = node["content"] as? [Any] ?? []

    switch type {
    case "text":
      return node["text"] as? String ?? ""
    case "hardBreak":
      return "\n"
    case "bulletList", "orderedList":
      let isOrdered = type == "orderedList"
      let items = content.enumerated().map { index, item in
        let indent = String(repeating: "  ", count: listDepth)
        let marker = isOrdered ? "\(index + 1)." : "•"
        let body = renderADF(item, listDepth: listDepth + 1)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(indent)\(marker) \(body)"
      }
      return items.joined(separator: "\n") + "\n\n"
    case "listItem":
      return content.map { renderADF($0, listDepth: listDepth) }.joined(separator: "\n")
    case "paragraph", "heading", "blockquote", "codeBlock", "panel":
      return renderADF(content, listDepth: listDepth) + "\n\n"
    case "mention", "emoji":
      let attrs = node["attrs"] as? [String: Any]
      return attrs?["text"] as? String ?? ""
    default:
      return renderADF(content, listDepth: listDepth)
    }
  }
}
