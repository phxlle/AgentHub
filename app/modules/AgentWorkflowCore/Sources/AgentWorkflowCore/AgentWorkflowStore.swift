import Foundation
import GRDB

public protocol AgentWorkflowStoreProtocol: Sendable {
  func createTicketRun(
    ticketKey: String,
    summary: String?,
    coordinatorProvider: AgentProviderID
  ) async throws -> TicketRun
  func ticketRuns() async throws -> [TicketRun]
  func createBranchRun(
    ticketRunID: UUID,
    repositoryPath: String,
    worktreePath: String,
    branchName: String,
    baseBranch: String,
    implementerProvider: AgentProviderID,
    reviewerProvider: AgentProviderID
  ) async throws -> BranchRun
  func branchRuns(ticketRunID: UUID) async throws -> [BranchRun]
  func branchRun(id: UUID) async throws -> BranchRun?
  func apply(
    _ command: BranchWorkflowCommand,
    to branchRunID: UUID,
    at date: Date
  ) async throws -> BranchRun
  func requestApproval(
    branchRunID: UUID,
    action: ApprovalAction,
    at date: Date
  ) async throws -> ApprovalRequest
  func decideApproval(
    id: UUID,
    approved: Bool,
    at date: Date
  ) async throws -> ApprovalRequest
  func approvalRequests(branchRunID: UUID) async throws -> [ApprovalRequest]
  func events(ticketRunID: UUID) async throws -> [WorkflowEvent]
}

public actor AgentWorkflowStore: AgentWorkflowStoreProtocol {
  private enum MigrationID {
    static let createWorkflowTables = "v1_create_workflow_tables"
  }

  private let dbQueue: DatabaseQueue

  public init() throws {
    let appSupportURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    let agentHubDirectory = appSupportURL.appendingPathComponent("AgentHub", isDirectory: true)
    try FileManager.default.createDirectory(
      at: agentHubDirectory,
      withIntermediateDirectories: true
    )
    dbQueue = try DatabaseQueue(
      path: agentHubDirectory.appendingPathComponent("agent_workflows.sqlite").path
    )
    try migrator.migrate(dbQueue)
  }

  public init(path: String) throws {
    dbQueue = try DatabaseQueue(path: path)
    try migrator.migrate(dbQueue)
  }

  public func createTicketRun(
    ticketKey: String,
    summary: String? = nil,
    coordinatorProvider: AgentProviderID
  ) async throws -> TicketRun {
    let ticketRun = try TicketRun(
      ticketKey: ticketKey,
      summary: summary,
      coordinatorProvider: coordinatorProvider
    )
    try await dbQueue.write { db in
      try TicketRunRecord(ticketRun).insert(db)
      try WorkflowEventRecord(
        WorkflowEvent(
          ticketRunID: ticketRun.id,
          kind: "ticket.created",
          message: ticketRun.ticketKey
        )
      ).insert(db)
    }
    return ticketRun
  }

  public func ticketRuns() async throws -> [TicketRun] {
    try await dbQueue.read { db in
      try TicketRunRecord
        .order(Column("updatedAt").desc)
        .fetchAll(db)
        .map { try $0.model() }
    }
  }

  public func createBranchRun(
    ticketRunID: UUID,
    repositoryPath: String,
    worktreePath: String,
    branchName: String,
    baseBranch: String,
    implementerProvider: AgentProviderID,
    reviewerProvider: AgentProviderID
  ) async throws -> BranchRun {
    let branchRun = try BranchRun(
      ticketRunID: ticketRunID,
      repositoryPath: repositoryPath,
      worktreePath: worktreePath,
      branchName: branchName,
      baseBranch: baseBranch,
      implementerProvider: implementerProvider,
      reviewerProvider: reviewerProvider
    )

    try await dbQueue.write { db in
      guard try TicketRunRecord.fetchOne(db, key: ticketRunID.uuidString) != nil else {
        throw AgentWorkflowError.ticketRunNotFound(ticketRunID)
      }
      try BranchRunRecord(branchRun).insert(db)
      try WorkflowEventRecord(
        WorkflowEvent(
          ticketRunID: ticketRunID,
          branchRunID: branchRun.id,
          kind: "branch.created",
          message: branchName
        )
      ).insert(db)
    }
    return branchRun
  }

  public func branchRuns(ticketRunID: UUID) async throws -> [BranchRun] {
    try await dbQueue.read { db in
      try BranchRunRecord
        .filter(Column("ticketRunID") == ticketRunID.uuidString)
        .order(Column("createdAt"))
        .fetchAll(db)
        .map { try $0.model() }
    }
  }

  public func branchRun(id: UUID) async throws -> BranchRun? {
    try await dbQueue.read { db in
      try BranchRunRecord.fetchOne(db, key: id.uuidString)?.model()
    }
  }

  @discardableResult
  public func apply(
    _ command: BranchWorkflowCommand,
    to branchRunID: UUID,
    at date: Date = Date()
  ) async throws -> BranchRun {
    try await dbQueue.write { db in
      guard let record = try BranchRunRecord.fetchOne(db, key: branchRunID.uuidString) else {
        throw AgentWorkflowError.branchRunNotFound(branchRunID)
      }
      var branchRun = try record.model()
      let previousDiffHash = branchRun.currentDiffHash
      try BranchWorkflowStateMachine.apply(command, to: &branchRun, at: date)
      try BranchRunRecord(branchRun).update(db)

      if case .testsPassed = command, previousDiffHash != branchRun.currentDiffHash {
        try db.execute(
          sql: """
            UPDATE approval_requests
            SET status = ?, decidedAt = ?
            WHERE branchRunID = ? AND diffHash <> ? AND status IN (?, ?)
            """,
          arguments: [
            ApprovalStatus.invalidated.rawValue,
            date,
            branchRun.id.uuidString,
            branchRun.currentDiffHash ?? "",
            ApprovalStatus.pending.rawValue,
            ApprovalStatus.approved.rawValue,
          ]
        )
      }

      try WorkflowEventRecord(
        WorkflowEvent(
          ticketRunID: branchRun.ticketRunID,
          branchRunID: branchRun.id,
          kind: command.eventKind,
          message: command.eventMessage,
          createdAt: date
        )
      ).insert(db)
      return branchRun
    }
  }

  public func requestApproval(
    branchRunID: UUID,
    action: ApprovalAction,
    at date: Date = Date()
  ) async throws -> ApprovalRequest {
    try await dbQueue.write { db in
      guard let branchRecord = try BranchRunRecord.fetchOne(db, key: branchRunID.uuidString) else {
        throw AgentWorkflowError.branchRunNotFound(branchRunID)
      }
      let branchRun = try branchRecord.model()
      guard branchRun.status == .awaitingApproval else {
        throw AgentWorkflowError.approvalNotAllowed(branchRun.status)
      }
      guard let diffHash = branchRun.currentDiffHash, !diffHash.isEmpty else {
        throw AgentWorkflowError.invalidDiffHash
      }

      let request = ApprovalRequest(
        branchRunID: branchRunID,
        action: action,
        diffHash: diffHash,
        requestedAt: date
      )
      try ApprovalRequestRecord(request).insert(db)
      try WorkflowEventRecord(
        WorkflowEvent(
          ticketRunID: branchRun.ticketRunID,
          branchRunID: branchRun.id,
          kind: "approval.requested.\(action.rawValue)",
          message: diffHash,
          createdAt: date
        )
      ).insert(db)
      return request
    }
  }

  @discardableResult
  public func decideApproval(
    id: UUID,
    approved: Bool,
    at date: Date = Date()
  ) async throws -> ApprovalRequest {
    try await dbQueue.write { db in
      guard let record = try ApprovalRequestRecord.fetchOne(db, key: id.uuidString) else {
        throw AgentWorkflowError.approvalRequestNotFound(id)
      }
      var request = try record.model()
      guard request.status == .pending else {
        throw AgentWorkflowError.approvalAlreadyDecided(request.status)
      }
      guard let branchRecord = try BranchRunRecord.fetchOne(db, key: request.branchRunID.uuidString)
      else {
        throw AgentWorkflowError.branchRunNotFound(request.branchRunID)
      }
      let branchRun = try branchRecord.model()
      guard branchRun.currentDiffHash == request.diffHash else {
        throw AgentWorkflowError.diffChanged
      }

      request.status = approved ? .approved : .rejected
      request.decidedAt = date
      try ApprovalRequestRecord(request).update(db)
      try WorkflowEventRecord(
        WorkflowEvent(
          ticketRunID: branchRun.ticketRunID,
          branchRunID: branchRun.id,
          kind: approved ? "approval.approved" : "approval.rejected",
          message: request.action.rawValue,
          createdAt: date
        )
      ).insert(db)
      return request
    }
  }

  public func approvalRequests(branchRunID: UUID) async throws -> [ApprovalRequest] {
    try await dbQueue.read { db in
      try ApprovalRequestRecord
        .filter(Column("branchRunID") == branchRunID.uuidString)
        .order(Column("requestedAt"))
        .fetchAll(db)
        .map { try $0.model() }
    }
  }

  public func events(ticketRunID: UUID) async throws -> [WorkflowEvent] {
    try await dbQueue.read { db in
      try WorkflowEventRecord
        .filter(Column("ticketRunID") == ticketRunID.uuidString)
        .order(Column("createdAt"))
        .fetchAll(db)
        .map { try $0.model() }
    }
  }

  private nonisolated var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(MigrationID.createWorkflowTables) { db in
      try db.execute(
        sql: """
          CREATE TABLE ticket_runs (
            id TEXT PRIMARY KEY NOT NULL,
            ticketKey TEXT NOT NULL,
            summary TEXT,
            coordinatorProvider TEXT NOT NULL,
            coordinatorSessionID TEXT,
            status TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
          );
          CREATE INDEX idx_ticket_runs_updated ON ticket_runs(updatedAt);

          CREATE TABLE branch_runs (
            id TEXT PRIMARY KEY NOT NULL,
            ticketRunID TEXT NOT NULL REFERENCES ticket_runs(id) ON DELETE CASCADE,
            repositoryPath TEXT NOT NULL,
            worktreePath TEXT NOT NULL,
            branchName TEXT NOT NULL,
            baseBranch TEXT NOT NULL,
            implementerProvider TEXT NOT NULL,
            implementerSessionID TEXT,
            reviewerProvider TEXT NOT NULL,
            reviewerSessionID TEXT,
            status TEXT NOT NULL,
            reviewCycle INTEGER NOT NULL DEFAULT 0 CHECK(reviewCycle BETWEEN 0 AND 2),
            currentDiffHash TEXT,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            UNIQUE(ticketRunID, repositoryPath, branchName)
          );
          CREATE INDEX idx_branch_runs_ticket ON branch_runs(ticketRunID, createdAt);

          CREATE TABLE approval_requests (
            id TEXT PRIMARY KEY NOT NULL,
            branchRunID TEXT NOT NULL REFERENCES branch_runs(id) ON DELETE CASCADE,
            action TEXT NOT NULL,
            diffHash TEXT NOT NULL,
            status TEXT NOT NULL,
            requestedAt DATETIME NOT NULL,
            decidedAt DATETIME,
            UNIQUE(branchRunID, action, diffHash)
          );
          CREATE INDEX idx_approval_requests_branch ON approval_requests(branchRunID, requestedAt);

          CREATE TABLE workflow_events (
            id TEXT PRIMARY KEY NOT NULL,
            ticketRunID TEXT NOT NULL REFERENCES ticket_runs(id) ON DELETE CASCADE,
            branchRunID TEXT REFERENCES branch_runs(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            message TEXT,
            createdAt DATETIME NOT NULL
          );
          CREATE INDEX idx_workflow_events_ticket ON workflow_events(ticketRunID, createdAt);
          """)
    }
    return migrator
  }
}

private struct TicketRunRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "ticket_runs"

  var id: String
  var ticketKey: String
  var summary: String?
  var coordinatorProvider: String
  var coordinatorSessionID: String?
  var status: String
  var createdAt: Date
  var updatedAt: Date

  init(_ model: TicketRun) {
    id = model.id.uuidString
    ticketKey = model.ticketKey
    summary = model.summary
    coordinatorProvider = model.coordinator.provider.rawValue
    coordinatorSessionID = model.coordinator.sessionID
    status = model.status.rawValue
    createdAt = model.createdAt
    updatedAt = model.updatedAt
  }

  func model() throws -> TicketRun {
    guard let id = UUID(uuidString: id), let status = TicketRunStatus(rawValue: status) else {
      throw AgentWorkflowError.corruptPersistenceRecord("ticket run")
    }
    var model = try TicketRun(
      id: id,
      ticketKey: ticketKey,
      summary: summary,
      coordinatorProvider: AgentProviderID(rawValue: coordinatorProvider),
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    model.coordinator.sessionID = coordinatorSessionID
    return model
  }
}

private struct BranchRunRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "branch_runs"

  var id: String
  var ticketRunID: String
  var repositoryPath: String
  var worktreePath: String
  var branchName: String
  var baseBranch: String
  var implementerProvider: String
  var implementerSessionID: String?
  var reviewerProvider: String
  var reviewerSessionID: String?
  var status: String
  var reviewCycle: Int
  var currentDiffHash: String?
  var createdAt: Date
  var updatedAt: Date

  init(_ model: BranchRun) {
    id = model.id.uuidString
    ticketRunID = model.ticketRunID.uuidString
    repositoryPath = model.repositoryPath
    worktreePath = model.worktreePath
    branchName = model.branchName
    baseBranch = model.baseBranch
    implementerProvider = model.implementer.provider.rawValue
    implementerSessionID = model.implementer.sessionID
    reviewerProvider = model.reviewer.provider.rawValue
    reviewerSessionID = model.reviewer.sessionID
    status = model.status.rawValue
    reviewCycle = model.reviewCycle
    currentDiffHash = model.currentDiffHash
    createdAt = model.createdAt
    updatedAt = model.updatedAt
  }

  func model() throws -> BranchRun {
    guard
      let id = UUID(uuidString: id),
      let ticketRunID = UUID(uuidString: ticketRunID),
      let status = BranchRunStatus(rawValue: status)
    else {
      throw AgentWorkflowError.corruptPersistenceRecord("branch run")
    }
    var model = try BranchRun(
      id: id,
      ticketRunID: ticketRunID,
      repositoryPath: repositoryPath,
      worktreePath: worktreePath,
      branchName: branchName,
      baseBranch: baseBranch,
      implementerProvider: AgentProviderID(rawValue: implementerProvider),
      reviewerProvider: AgentProviderID(rawValue: reviewerProvider),
      status: status,
      reviewCycle: reviewCycle,
      currentDiffHash: currentDiffHash,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    model.implementer.sessionID = implementerSessionID
    model.reviewer.sessionID = reviewerSessionID
    return model
  }
}

private struct ApprovalRequestRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "approval_requests"

  var id: String
  var branchRunID: String
  var action: String
  var diffHash: String
  var status: String
  var requestedAt: Date
  var decidedAt: Date?

  init(_ model: ApprovalRequest) {
    id = model.id.uuidString
    branchRunID = model.branchRunID.uuidString
    action = model.action.rawValue
    diffHash = model.diffHash
    status = model.status.rawValue
    requestedAt = model.requestedAt
    decidedAt = model.decidedAt
  }

  func model() throws -> ApprovalRequest {
    guard
      let id = UUID(uuidString: id),
      let branchRunID = UUID(uuidString: branchRunID),
      let action = ApprovalAction(rawValue: action),
      let status = ApprovalStatus(rawValue: status)
    else {
      throw AgentWorkflowError.corruptPersistenceRecord("approval request")
    }
    return ApprovalRequest(
      id: id,
      branchRunID: branchRunID,
      action: action,
      diffHash: diffHash,
      status: status,
      requestedAt: requestedAt,
      decidedAt: decidedAt
    )
  }
}

private struct WorkflowEventRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "workflow_events"

  var id: String
  var ticketRunID: String
  var branchRunID: String?
  var kind: String
  var message: String?
  var createdAt: Date

  init(_ model: WorkflowEvent) {
    id = model.id.uuidString
    ticketRunID = model.ticketRunID.uuidString
    branchRunID = model.branchRunID?.uuidString
    kind = model.kind
    message = model.message
    createdAt = model.createdAt
  }

  func model() throws -> WorkflowEvent {
    guard let id = UUID(uuidString: id), let ticketRunID = UUID(uuidString: ticketRunID) else {
      throw AgentWorkflowError.corruptPersistenceRecord("workflow event")
    }
    let branchRunID = try branchRunID.map { value in
      guard let id = UUID(uuidString: value) else {
        throw AgentWorkflowError.corruptPersistenceRecord("workflow event branch run ID")
      }
      return id
    }
    return WorkflowEvent(
      id: id,
      ticketRunID: ticketRunID,
      branchRunID: branchRunID,
      kind: kind,
      message: message,
      createdAt: createdAt
    )
  }
}
