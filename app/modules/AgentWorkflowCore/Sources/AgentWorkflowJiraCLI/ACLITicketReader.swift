import Foundation

public protocol JiraTicketReading: Sendable {
  func ticket(key: String) async throws -> JiraTicketSnapshot
}

public actor ACLITicketReader: JiraTicketReading {
  private static let fields = [
    "key",
    "issuetype",
    "summary",
    "status",
    "assignee",
    "description",
  ]

  private let runner: any JiraCLICommandRunning
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
    guard result.exitCode == 0 else {
      let message =
        String(data: result.standardError, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw JiraTicketReaderError.commandFailed(
        exitCode: result.exitCode,
        message: message
      )
    }

    return try Self.parse(
      data: result.standardOutput,
      fallbackKey: normalizedKey,
      fetchedAt: now()
    )
  }

  private static func isValidTicketKey(_ key: String) -> Bool {
    key.range(of: #"^[A-Z][A-Z0-9]+-[0-9]+$"#, options: .regularExpression) != nil
  }

  private static func parse(
    data: Data,
    fallbackKey: String,
    fetchedAt: Date
  ) throws -> JiraTicketSnapshot {
    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let fields = object["fields"] as? [String: Any],
      let summary = fields["summary"] as? String
    else {
      throw JiraTicketReaderError.invalidResponse
    }

    let key = object["key"] as? String ?? fallbackKey
    let issueType = (fields["issuetype"] as? [String: Any])?["name"] as? String
    let status = (fields["status"] as? [String: Any])?["name"] as? String
    let assignee = (fields["assignee"] as? [String: Any])?["displayName"] as? String

    return JiraTicketSnapshot(
      key: key,
      summary: summary,
      issueType: issueType,
      status: status,
      assignee: assignee,
      description: descriptionText(from: fields["description"]),
      fetchedAt: fetchedAt
    )
  }

  private static func descriptionText(from value: Any?) -> String? {
    if let text = value as? String {
      return text
    }
    guard let value else { return nil }
    let fragments = collectText(from: value)
    let text = fragments.joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func collectText(from value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
      var result: [String] = []
      if let text = dictionary["text"] as? String {
        result.append(text)
      }
      if let content = dictionary["content"] as? [Any] {
        result.append(contentsOf: content.flatMap(collectText))
      }
      return result
    }
    if let values = value as? [Any] {
      return values.flatMap(collectText)
    }
    return []
  }
}
