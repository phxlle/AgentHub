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
          "key,issuetype,summary,status,assignee,description",
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
