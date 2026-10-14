import Foundation
import Testing

@testable import AgentWorkflowJiraCLI

@Suite("ACLI Jira ticket reader")
struct ACLITicketReaderTests {
  @Test("Reads a ticket through the read-only workitem view command")
  func readsTicket() async throws {
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(
        standardOutput: Data(Self.ticketJSON.utf8),
        standardError: Data(),
        exitCode: 0
      ))
    let fetchedAt = Date(timeIntervalSince1970: 42)
    let reader = ACLITicketReader(runner: runner, now: { fetchedAt })

    let ticket = try await reader.ticket(key: "xfa-3299")
    let arguments = await runner.receivedArguments

    #expect(
      arguments == [
        [
          "jira", "workitem", "view", "XFA-3299", "--json", "--fields",
          "key,issuetype,summary,status,assignee,priority,description",
        ]
      ])
    #expect(ticket.key == "XFA-3299")
    #expect(ticket.summary == "MFA confirmation")
    #expect(ticket.status == "To Do")
    #expect(ticket.assignee == "Philippe")
    #expect(ticket.description == "Require MFA confirmation before continuing.")
    #expect(ticket.fetchedAt == fetchedAt)
  }

  @Test("Rejects malformed keys without invoking the CLI")
  func rejectsMalformedKey() async {
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(
        standardOutput: Data(),
        standardError: Data(),
        exitCode: 0
      ))
    let reader = ACLITicketReader(runner: runner)

    await #expect(throws: JiraTicketReaderError.invalidTicketKey) {
      _ = try await reader.ticket(key: "XFA-3299; rm")
    }
    #expect(await runner.receivedArguments.isEmpty)
  }

  @Test("Surfaces CLI failures without parsing output")
  func surfacesCommandFailure() async {
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(
        standardOutput: Data(),
        standardError: Data("not authenticated\n".utf8),
        exitCode: 1
      ))
    let reader = ACLITicketReader(runner: runner)

    await #expect(
      throws: JiraTicketReaderError.commandFailed(
        exitCode: 1,
        message: "not authenticated"
      )
    ) {
      _ = try await reader.ticket(key: "XFA-3299")
    }
  }

  @Test("Searches sprint tickets and reads status category and priority")
  func searchesTickets() async throws {
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(
        standardOutput: Data(Self.searchJSON.utf8),
        standardError: Data(),
        exitCode: 0
      ))
    let reader = ACLITicketReader(runner: runner)

    let tickets = try await reader.searchTickets(jql: "sprint in openSprints()", limit: 5)

    #expect(
      await runner.receivedArguments == [
        [
          "jira", "workitem", "search", "--jql", "sprint in openSprints()", "--json", "--limit",
          "5", "--fields", "key,issuetype,summary,status,assignee,priority",
        ]
      ])
    #expect(tickets.map(\.key) == ["XFA-1", "XFA-2"])
    #expect(tickets[0].statusCategory == "indeterminate")
    #expect(tickets[0].priority == "High")
    #expect(tickets[0].assigneeAccountId == "a1")
    #expect(tickets[0].assigneeEmail == "g@x.tech")
    #expect(tickets[0].assigneeAvatarURL == "https://avatar/g.png")
    #expect(tickets[1].summary == "Second")
  }

  @Test("Transitions a ticket non-interactively")
  func transitions() async throws {
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(standardOutput: Data(), standardError: Data(), exitCode: 0))
    try await ACLITicketReader(runner: runner).transition(key: "xfa-12", toStatus: "In Progress")
    #expect(
      await runner.receivedArguments == [
        ["jira", "workitem", "transition", "--key", "XFA-12", "--status", "In Progress", "--yes"]
      ])
  }

  @Test("Authenticates through the browser login")
  func authenticates() async throws {
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(standardOutput: Data(), standardError: Data(), exitCode: 0))
    try await ACLITicketReader(runner: runner).authenticate()
    #expect(await runner.receivedArguments == [["jira", "auth", "login", "--web"]])
  }

  @Test("Reads the logged-in account from auth status")
  func readsAccount() async throws {
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(
        standardOutput: Data(
          "✓ Authenticated\n  Site: xfatech.atlassian.net\n  Email: me@xfa.tech\n".utf8),
        standardError: Data(), exitCode: 0))
    let account = try await ACLITicketReader(runner: runner).currentAccount()
    #expect(account == JiraAccount(site: "xfatech.atlassian.net", email: "me@xfa.tech"))
    #expect(account.browseURL(forKey: "XFA-1")?.absoluteString == "https://xfatech.atlassian.net/browse/XFA-1")
  }

  @Test("Lists open sprints with the active sprint first")
  func listsSprints() async throws {
    let json = #"""
      {"sprints": [
        {"id": 267, "name": "Sprint 11", "state": "future", "startDate": null},
        {"id": 266, "name": "Sprint 10", "state": "active",
         "startDate": "2026-09-29T11:15:42.921Z", "endDate": "2026-10-06T03:31:23.000Z"}
      ]}
      """#
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(standardOutput: Data(json.utf8), standardError: Data(), exitCode: 0))
    let sprints = try await ACLITicketReader(runner: runner).openSprints(boardID: 1)

    #expect(
      await runner.receivedArguments == [
        ["jira", "board", "list-sprints", "--id", "1", "--state", "active,future", "--json"]
      ])
    #expect(sprints.map(\.id) == [266, 267])
    #expect(sprints[0].endDate == Date(timeIntervalSince1970: 1_791_257_483))
  }

  @Test("Flattens ADF descriptions keeping paragraphs and lists")
  func flattensDescription() async throws {
    let json = #"""
      {"key": "XFA-1", "fields": {"summary": "S", "description": {"type": "doc", "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "Intro"}]},
        {"type": "bulletList", "content": [
          {"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "One"}]}]},
          {"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Two"}]}]}
        ]}
      ]}}}
      """#
    let runner = MockJiraCLICommandRunner(
      result: JiraCLICommandResult(standardOutput: Data(json.utf8), standardError: Data(), exitCode: 0))
    let ticket = try await ACLITicketReader(runner: runner).ticket(key: "XFA-1")
    #expect(ticket.description == "Intro\n\n• One\n• Two")
  }

  private static let searchJSON = #"""
    [
      {
        "key": "XFA-1",
        "fields": {
          "summary": "First",
          "status": { "name": "In Progress", "statusCategory": { "key": "indeterminate" } },
          "priority": { "name": "High" },
          "assignee": { "accountId": "a1", "displayName": "Gijs", "emailAddress": "g@x.tech",
            "avatarUrls": { "48x48": "https://avatar/g.png" } }
        }
      },
      { "key": "XFA-2", "fields": { "summary": "Second" } },
      { "fields": { "summary": "No key, skipped" } }
    ]
    """#

  private static let ticketJSON = #"""
    {
      "key": "XFA-3299",
      "fields": {
        "summary": "MFA confirmation",
        "issuetype": { "name": "Story" },
        "status": { "name": "To Do" },
        "assignee": { "displayName": "Philippe" },
        "description": {
          "type": "doc",
          "content": [
            {
              "type": "paragraph",
              "content": [
                { "type": "text", "text": "Require MFA confirmation before continuing." }
              ]
            }
          ]
        }
      }
    }
    """#
}

private actor MockJiraCLICommandRunner: JiraCLICommandRunning {
  private(set) var receivedArguments: [[String]] = []
  private let result: JiraCLICommandResult

  init(result: JiraCLICommandResult) {
    self.result = result
  }

  func run(arguments: [String]) async throws -> JiraCLICommandResult {
    receivedArguments.append(arguments)
    return result
  }
}
