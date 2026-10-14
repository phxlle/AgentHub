import AgentHubSessionGraph
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Automatic agent workflow classification")
struct AgentSessionWorkflowClassifierTests {
  @Test("Sessions with the same ticket and branch become implementer and reviewer")
  func pairsImplementationAndReviewSessions() {
    let implementer = observation(
      id: "impl",
      provider: .codex,
      branch: "feature/XFA-3299-mfa",
      message: "Implement XFA-3299 and run the tests"
    )
    let reviewer = observation(
      id: "review",
      provider: .claude,
      branch: "feature/XFA-3299-mfa",
      message: "Review the changes for XFA-3299 and report findings"
    )

    let branches = AgentSessionWorkflowClassifier.classify([implementer, reviewer])

    #expect(branches.count == 1)
    #expect(branches[0].ticketKey == "XFA-3299")
    #expect(branches[0].primaryImplementer?.session.id == "impl")
    #expect(branches[0].primaryReviewer?.session.id == "review")
  }

  @Test("A review on main joins the only ticket branch in the repository")
  func joinsGenericReviewBranch() {
    let implementer = observation(
      id: "impl",
      provider: .codex,
      branch: "XFA-3299-mfa",
      message: "Implement XFA-3299"
    )
    let reviewer = observation(
      id: "review",
      provider: .claude,
      branch: "main",
      message: "Code review for XFA-3299"
    )

    let branches = AgentSessionWorkflowClassifier.classify([implementer, reviewer])

    #expect(branches.count == 1)
    #expect(branches[0].branchName == "XFA-3299-mfa")
    #expect(branches[0].reviewerSessions.map(\.session.id) == ["review"])
  }

  @Test("Addressing review feedback remains implementation work")
  func responseToReviewIsImplementation() {
    let session = observation(
      id: "fix-review",
      provider: .codex,
      branch: "XFA-3299-mfa",
      message: "Address review comments and fix requested changes for XFA-3299"
    )

    let branch = AgentSessionWorkflowClassifier.classify([session])[0]

    #expect(branch.primaryImplementer?.session.id == "fix-review")
    #expect(branch.primaryReviewer == nil)
  }

  @Test("AgentHub's independent reviewer prompt overrides implementation language")
  func explicitIndependentReviewerOverridesImplementationLanguage() {
    let reviewer = observation(
      id: "generated-review",
      provider: .claude,
      branch: "XFA-3317-review",
      message: """
        You are the independent read-only review agent for XFA-3317.
        The implementation was produced by Codex in another session.
        Review the implementation request, implementation report, and current working tree.
        """
    )

    let branch = AgentSessionWorkflowClassifier.classify([reviewer])[0]

    #expect(branch.primaryImplementer == nil)
    #expect(branch.primaryReviewer?.session.id == "generated-review")
    #expect(branch.primaryReviewer?.roleConfidence == .high)
  }

  @Test("Uncertain automatic workflows remain hidden")
  func uncertainAutomaticWorkflowsRemainHidden() {
    let noTicket = AgentSessionWorkflowClassifier.classify([
      observation(
        id: "no-ticket",
        provider: .codex,
        branch: "main",
        message: "Investigate the current issue"
      )
    ])
    let weakTicket = AgentSessionWorkflowClassifier.classify([
      observation(
        id: "weak-ticket",
        provider: .codex,
        branch: "main",
        message: "Investigate XFA-9000"
      )
    ])

    #expect(AgentSessionWorkflowClassifier.workflows(from: noTicket, scope: .active).isEmpty)
    #expect(AgentSessionWorkflowClassifier.workflows(from: weakTicket, scope: .active).isEmpty)
  }

  @Test("Two sessions mentioning the same Jira ticket form a confident workflow")
  func duplicateTicketEvidenceFormsConfidentWorkflow() {
    let branches = AgentSessionWorkflowClassifier.classify([
      observation(
        id: "ticket-implementation",
        provider: .codex,
        branch: "main",
        message: "Implement XFA-9001"
      ),
      observation(
        id: "ticket-review",
        provider: .claude,
        branch: "main",
        message: "Review XFA-9001"
      ),
    ])

    let workflows = AgentSessionWorkflowClassifier.workflows(from: branches, scope: .active)

    #expect(workflows.count == 1)
    #expect(workflows[0].ticketKey == "XFA-9001")
  }

  @Test("Manual workflows always remain visible")
  func manualWorkflowsAlwaysRemainVisible() {
    var branch = AgentSessionWorkflowClassifier.classify([
      observation(
        id: "manual-session",
        provider: .codex,
        branch: "main",
        message: "Investigate the current issue"
      )
    ])[0]
    branch.manualWorkflowID = "manual:kept"

    let workflows = AgentSessionWorkflowClassifier.workflows(from: [branch], scope: .active)

    #expect(workflows.count == 1)
    #expect(workflows[0].id == "manual:kept")
  }

  @Test("Only merged pull request workflows appear under Completed")
  func mergedPullRequestsMoveToCompleted() {
    var merged = AgentSessionWorkflowClassifier.classify([
      observation(
        id: "merged",
        provider: .codex,
        branch: "XFA-3299-mfa",
        message: "Implement XFA-3299"
      )
    ])[0]
    merged.pullRequest = DetectedPullRequest(
      number: 42,
      title: "XFA-3299 MFA confirmation",
      url: "https://github.com/example/repo/pull/42",
      state: .merged,
      headBranch: "XFA-3299-mfa"
    )

    let active = AgentSessionWorkflowClassifier.workflows(from: [merged], scope: .active)
    let completed = AgentSessionWorkflowClassifier.workflows(from: [merged], scope: .completed)

    #expect(active.isEmpty)
    #expect(completed.count == 1)
    #expect(completed[0].ticketKey == "XFA-3299")
  }

  @Test("Pull request links are extracted from session prompts")
  func extractsPullRequestLinks() {
    let references = AgentSessionWorkflowClassifier.pullRequestReferences(
      in: ["Review https://github.com/example/repo/pull/42 and report findings"]
    )

    #expect(references.count == 1)
    #expect(references[0].number == 42)
    #expect(references[0].repository == "repo")
  }

  @Test("Ticket evidence is read from the underlying session file")
  func readsTranscriptEvidence() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = directory.appendingPathComponent("session.jsonl")
    try #"{"type":"message","content":"Continue work for XFA-7788"}"#
      .write(to: transcript, atomically: true, encoding: .utf8)
    let session = CLISession(
      id: "transcript",
      projectPath: "/repos/app",
      branchName: "main",
      firstMessage: "Continue the current task",
      sessionFilePath: transcript.path
    )
    let observation = AgentSessionObservation(
      session: session,
      provider: .codex,
      repositoryPath: "/repos/app",
      branchName: "main",
      linkedPullRequests: []
    )

    let enriched = await AgentSessionTranscriptEvidenceReader().enrich([observation])
    let branches = AgentSessionWorkflowClassifier.classify(enriched)

    #expect(branches[0].ticketKey == "XFA-7788")
  }

  @Test("A recognized ticket skips transcript inspection")
  func recognizedTicketSkipsTranscript() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcript = directory.appendingPathComponent("session.jsonl")
    try "This transcript should not replace the recognized XFA-9999 ticket"
      .write(to: transcript, atomically: true, encoding: .utf8)
    let observation = AgentSessionObservation(
      session: CLISession(
        id: "recognized",
        projectPath: "/repos/app",
        branchName: "feature/XFA-3299-mfa",
        firstMessage: "Continue implementation",
        sessionFilePath: transcript.path
      ),
      provider: .codex,
      repositoryPath: "/repos/app",
      branchName: "feature/XFA-3299-mfa",
      linkedPullRequests: []
    )

    let enriched = await AgentSessionTranscriptEvidenceReader().enrich([observation])

    #expect(enriched[0].transcriptEvidence == nil)
    #expect(AgentSessionWorkflowClassifier.classify(enriched)[0].ticketKey == "XFA-3299")
  }

  private func observation(
    id: String,
    provider: SessionProviderKind,
    branch: String,
    message: String
  ) -> AgentSessionObservation {
    AgentSessionObservation(
      session: CLISession(
        id: id,
        projectPath: "/repos/app",
        branchName: branch,
        lastActivityAt: Date(timeIntervalSince1970: id == "review" ? 20 : 10),
        isActive: true,
        firstMessage: message
      ),
      provider: provider,
      repositoryPath: "/repos/app",
      branchName: branch,
      linkedPullRequests: []
    )
  }
}
