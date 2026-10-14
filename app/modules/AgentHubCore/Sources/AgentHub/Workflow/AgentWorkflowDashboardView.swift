import AgentHubGitHub
import AgentHubSessionGraph
import AppKit
import SwiftUI

public struct AgentWorkflowDashboardView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @Bindable private var viewModel: AgentWorkflowDashboardViewModel
  private let onOpenSession: ((DetectedAgentSession) -> Void)?
  private let onCloseSession: ((DetectedAgentSession) -> Void)?
  private let onStartSession: ((String, SessionProviderKind, String?) -> Void)?
  private let onCompareSessions: ((WorkflowSessionComparisonRequest) -> Void)?
  @State private var isCreatingWorkflow = false
  @State private var sessionSearchText = ""

  public init(viewModel: AgentWorkflowDashboardViewModel) {
    self.viewModel = viewModel
    onOpenSession = nil
    onCloseSession = nil
    onStartSession = nil
    onCompareSessions = nil
  }

  init(
    viewModel: AgentWorkflowDashboardViewModel,
    onOpenSession: @escaping (DetectedAgentSession) -> Void,
    onCloseSession: @escaping (DetectedAgentSession) -> Void,
    onStartSession: @escaping (String, SessionProviderKind, String?) -> Void,
    onCompareSessions: @escaping (WorkflowSessionComparisonRequest) -> Void
  ) {
    self.viewModel = viewModel
    self.onOpenSession = onOpenSession
    self.onCloseSession = onCloseSession
    self.onStartSession = onStartSession
    self.onCompareSessions = onCompareSessions
  }

  public var body: some View {
    NavigationSplitView {
      workflowSidebar
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    } content: {
      branchColumn
        .navigationSplitViewColumnWidth(min: 400, ideal: 500, max: 640)
    } detail: {
      sessionColumn
    }
    .navigationSplitViewStyle(.balanced)
    .tint(Color.brandPrimary(from: runtimeTheme))
    .background(workspaceBackground.ignoresSafeArea())
    .task {
      await viewModel.load()
    }
    .task(id: viewModel.sessionRevision) {
      await viewModel.refreshDetectedWorkflows()
    }
    .sheet(isPresented: $isCreatingWorkflow) {
      CreateManualWorkflowSheet(
        onCreate: createManualWorkflow,
        onDismiss: { isCreatingWorkflow = false }
      )
    }
  }

  private var workflowSidebar: some View {
    VStack(spacing: 0) {
      sidebarHeader
      Divider()
      VSplitView {
        workflowList
          .frame(minHeight: 180, idealHeight: 300)
        sessionLibrary
          .frame(minHeight: 220, idealHeight: 340)
      }
    }
    .background(panelBackground)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Detected ticket workflows")
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("AGENT WORKFLOWS")
            .font(.geist(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Text("Detected automatically from local sessions")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          isCreatingWorkflow.toggle()
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .help("Create a workflow and start its implementation agent")
        .accessibilityLabel("Create workflow")
        Button {
          Task { await viewModel.refreshDetectedWorkflows(forcePullRequestRefresh: true) }
        } label: {
          if viewModel.isDiscoveringSessions {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isDiscoveringSessions)
        .help("Refresh pull request states for analyzed sessions")
        .accessibilityLabel("Refresh pull request states")
      }

      Picker("Workflow state", selection: scopeBinding) {
        Text("Active \(viewModel.activeWorkflowCount)")
          .tag(AgentWorkflowListScope.active)
        Text("Completed \(viewModel.completedWorkflowCount)")
          .tag(AgentWorkflowListScope.completed)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Workflow state")

      sessionAnalysisControls

      if let errorMessage = viewModel.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.secondaryCaption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let warning = viewModel.pullRequestWarning {
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.secondaryCaption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(DesignTokens.Spacing.md)
  }

  private func createManualWorkflow(_ request: ManualWorkflowCreationRequest) -> Bool {
    guard
      let workflowID = viewModel.createManualWorkflow(
        name: request.name,
        repositoryPath: request.repositoryPath,
        branchName: request.branchName
      )
    else {
      return false
    }
    onStartSession?(workflowID, request.provider, request.prompt)
    isCreatingWorkflow = false
    return true
  }

  private var sessionAnalysisControls: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if viewModel.isDiscoveringSessions {
        ProgressView()
          .controlSize(.small)
        Text("Analyzing up to 10 sessions…")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      } else {
        Label(
          "\(viewModel.analyzedSessionCount) of \(viewModel.totalSessionCount) analyzed",
          systemImage: viewModel.remainingSessionCount == 0 ? "checkmark.circle" : "tray.full"
        )
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: DesignTokens.Spacing.xs)

      if viewModel.remainingSessionCount > 0 {
        Button("Analyze next \(viewModel.nextSessionBatchCount)") {
          Task { await viewModel.analyzeNextSessionBatch() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!viewModel.canAnalyzeNextSessionBatch)
        .help("Analyze the next sessions, ordered by most recent activity")
        .accessibilityLabel("Analyze next \(viewModel.nextSessionBatchCount) sessions")
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var scopeBinding: Binding<AgentWorkflowListScope> {
    Binding(
      get: { viewModel.workflowScope },
      set: { viewModel.changeScope($0) }
    )
  }

  @ViewBuilder
  private var workflowList: some View {
    if viewModel.displayedWorkflows.isEmpty {
      ContentUnavailableView {
        Label(emptyTitle, systemImage: emptySymbol)
      } description: {
        Text(emptyDescription)
      }
    } else {
      List(selection: workflowSelection) {
        ForEach(viewModel.displayedWorkflows) { workflow in
          DetectedTicketWorkflowRow(workflow: workflow)
            .tag(workflow.id)
            .dropDestination(for: String.self) { sessionIDs, _ in
              guard let sessionID = sessionIDs.first else { return false }
              Task { await viewModel.moveSession(sessionID, to: workflow.id) }
              return true
            }
            .contextMenu {
              if workflow.isArchived {
                Button("Restore workflow") {
                  viewModel.restoreWorkflow(workflow.id)
                }
              } else if viewModel.workflowScope == .active {
                Button("Archive workflow") {
                  viewModel.archiveWorkflow(workflow.id)
                }
              }
              if workflow.id.hasPrefix("manual:") {
                Divider()
                Button("Delete workflow", role: .destructive) {
                  viewModel.deleteManualWorkflow(workflow.id)
                }
              }
            }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(panelBackground)
      .accessibilityLabel("Ticket workflow list")
    }
  }

  private var sessionLibrary: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("SESSION LIBRARY")
              .font(.geist(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
            Text("Drag a session onto a workflow above")
              .font(.secondaryCaption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(filteredSessionLibraryItems.count)")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: DesignTokens.Spacing.sm) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Filter sessions", text: $sessionSearchText)
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: 28)
        .background(
          Color.themedControlBackground(theme: runtimeTheme),
          in: RoundedRectangle(cornerRadius: 6)
        )
      }
      .padding(DesignTokens.Spacing.md)

      Divider()

      if filteredSessionLibraryItems.isEmpty {
        ContentUnavailableView {
          Label(
            sessionSearchText.isEmpty ? "No local sessions" : "No matching sessions",
            systemImage: sessionSearchText.isEmpty ? "tray" : "magnifyingglass"
          )
        } description: {
          Text(
            sessionSearchText.isEmpty
              ? "Loaded Codex and Claude sessions will appear here."
              : "Try another session, branch, repository, or provider."
          )
        }
      } else {
        List(filteredSessionLibraryItems) { item in
          WorkflowSessionLibraryRow(
            item: item,
            displayName: viewModel.displayName(for: item.assignment),
            onOpenSession: onOpenSession
          )
          .draggable(item.id) {
            Label(
              "\(item.assignment.provider.rawValue) · \(viewModel.displayName(for: item.assignment))",
              systemImage: "terminal"
            )
            .padding(DesignTokens.Spacing.sm)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(panelBackground)
        .accessibilityLabel("Local session library")
      }
    }
    .background(panelBackground)
  }

  private var filteredSessionLibraryItems: [WorkflowSessionLibraryItem] {
    let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return viewModel.sessionLibraryItems }
    return viewModel.sessionLibraryItems.filter { item in
      let session = item.assignment.session
      return [
        item.assignment.provider.rawValue,
        viewModel.displayName(for: item.assignment),
        session.displayName,
        session.firstMessage,
        session.branchName,
        session.projectPath,
        item.workflowTitle,
      ]
      .compactMap { $0 }
      .contains { $0.localizedCaseInsensitiveContains(query) }
    }
  }

  private var emptyTitle: String {
    switch viewModel.workflowScope {
    case .active: "No active workflows detected"
    case .completed: "No completed workflows detected"
    }
  }

  private var emptySymbol: String {
    viewModel.workflowScope == .active ? "waveform.path.ecg" : "checkmark.circle"
  }

  private var emptyDescription: String {
    switch viewModel.workflowScope {
    case .active:
      "Add repositories under Sessions. Ticket keys and agent roles are inferred from branches and session prompts."
    case .completed:
      "A workflow moves here automatically when its pull request is merged."
    }
  }

  private var workflowSelection: Binding<String?> {
    Binding(
      get: { viewModel.selectedWorkflowID },
      set: { viewModel.selectWorkflow($0) }
    )
  }

  @ViewBuilder
  private var branchColumn: some View {
    if let workflow = viewModel.selectedDetectedWorkflow {
      VStack(spacing: 0) {
        DetectedTicketWorkflowHeader(
          workflow: workflow,
          scope: viewModel.workflowScope,
          onArchive: {
            viewModel.archiveWorkflow(workflow.id)
          },
          onRestore: {
            viewModel.restoreWorkflow(workflow.id)
          }
        )
        Divider()
        List(selection: branchSelection) {
          ForEach(workflow.branches) { branch in
            DetectedBranchWorkflowRow(branch: branch)
              .tag(branch.id)
          }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(workspaceBackground)
        .accessibilityLabel("Branches for \(workflow.ticketKey ?? "unassigned sessions")")
      }
    } else {
      ContentUnavailableView {
        Label("Select a workflow", systemImage: "sidebar.left")
      } description: {
        Text("Choose a detected ticket to inspect its implementation and review sessions.")
      }
    }
  }

  private var branchSelection: Binding<String?> {
    Binding(
      get: { viewModel.selectedDetectedBranchID },
      set: { viewModel.selectDetectedBranch($0) }
    )
  }

  private var workspaceBackground: Color {
    Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
  }

  private var panelBackground: Color {
    Color.themedPanelBackground(for: colorScheme, theme: runtimeTheme)
  }

  @ViewBuilder
  private var sessionColumn: some View {
    if let workflow = viewModel.selectedDetectedWorkflow,
      let branch = viewModel.selectedDetectedBranch
    {
      let workflowSessions = workflow.branches.flatMap {
        $0.implementerSessions + $0.reviewerSessions
      }
      DetectedBranchSessionDetail(
        workflowID: workflow.id,
        branch: branch,
        workflowSessionCount: workflowSessions.count,
        onOpenSession: onOpenSession,
        onCloseSession: { assignment in
          viewModel.dismissSession(assignment.id)
          onCloseSession?(assignment)
        },
        onRemoveSessionOverride: { assignment in
          viewModel.removeSessionWorkflowOverride(assignment.id)
        },
        hasSessionOverride: { assignment in
          viewModel.hasSessionWorkflowOverride(assignment.id)
        },
        sessionDisplayName: viewModel.displayName(for:),
        onMoveSession: { sessionID in
          Task { await viewModel.moveSession(sessionID, to: workflow.id) }
        },
        onRetryReview: {
          viewModel.retryAutomatedReview(for: branch.id)
        },
        onCreateReviewAgent: {
          viewModel.createReviewAgent(for: branch.id)
        },
        onCloseAllSessions: {
          viewModel.dismissSessions(workflowSessions.map(\.id))
          for assignment in workflowSessions {
            onCloseSession?(assignment)
          }
        },
        onStartSession: onStartSession,
        comparisonRequest: viewModel.comparisonRequest(for: branch.id),
        onCompareSessions: onCompareSessions
      )
    } else {
      ContentUnavailableView {
        Label("No branch selected", systemImage: "terminal")
      } description: {
        Text("Select a branch to inspect the linked implementation and review agents.")
      }
    }
  }
}

private struct WorkflowSessionLibraryRow: View {
  let item: WorkflowSessionLibraryItem
  let displayName: String
  let onOpenSession: ((DetectedAgentSession) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Text(item.assignment.provider.rawValue)
          .font(.secondarySmall)
        if item.assignment.session.isActive {
          Label("Active", systemImage: "circle.fill")
            .font(.secondaryCaption)
            .foregroundStyle(.green)
        } else if !item.isAnalyzed {
          Text("Not analyzed")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(item.assignment.session.lastActivityAt.timeAgoDisplay())
          .font(.secondaryCaption)
          .foregroundStyle(.tertiary)
      }

      Text(sessionTitle)
        .font(.secondaryDefault)
        .lineLimit(2)

      HStack(spacing: DesignTokens.Spacing.xs) {
        Image(systemName: item.workflowTitle == nil ? "tray" : "arrow.turn.down.right")
        Text(item.workflowTitle ?? item.assignment.session.branchName ?? "Not in a workflow")
          .lineLimit(1)
      }
      .font(.secondaryCaption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
    .contentShape(Rectangle())
    .contextMenu {
      if let onOpenSession {
        Button("Open terminal") {
          onOpenSession(item.assignment)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("Drag this session onto a workflow to assign it")
  }

  private var sessionTitle: String {
    if displayName != item.assignment.session.displayName {
      return displayName
    }
    let message = item.assignment.session.firstMessage?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let message, !message.isEmpty {
      return message
    }
    return displayName
  }
}

private struct DetectedTicketWorkflowRow: View {
  let workflow: DetectedTicketWorkflow

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Text(workflow.ticketKey ?? "Unassigned")
          .font(.primaryDefault)
        Spacer()
        Text("\(workflow.branches.count) \(workflow.branches.count == 1 ? "branch" : "branches")")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }
      if let summary = workflow.summary, !summary.isEmpty {
        Text(summary)
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Label(
        workflow.id.hasPrefix("manual:")
          ? "Manual workflow"
          : workflow.ticketKey == nil ? "Ticket not recognized" : "Detected from sessions",
        systemImage: workflow.id.hasPrefix("manual:")
          ? "hand.point.up.left"
          : workflow.ticketKey == nil ? "questionmark.circle" : "sparkle.magnifyingglass"
      )
      .font(.secondaryCaption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
    .accessibilityElement(children: .combine)
  }
}

private struct DetectedTicketWorkflowHeader: View {
  let workflow: DetectedTicketWorkflow
  let scope: AgentWorkflowListScope
  let onArchive: () -> Void
  let onRestore: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text(workflow.ticketKey ?? "Unassigned sessions")
          .font(.jetBrainsMono(size: 14, weight: .semibold))
        if let summary = workflow.summary {
          Text(summary)
            .font(.secondaryDefault)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer()
      Label(
        workflow.isArchived ? "Archived" : scope == .active ? "Active" : "Merged",
        systemImage: workflow.isArchived
          ? "archivebox" : scope == .active ? "play.circle" : "arrow.triangle.merge"
      )
      .font(.secondaryCaption)
      .foregroundStyle(.secondary)
      if workflow.isArchived {
        Button("Restore", systemImage: "arrow.uturn.backward", action: onRestore)
          .controlSize(.small)
      } else if scope == .active {
        Button("Archive", systemImage: "archivebox", action: onArchive)
          .controlSize(.small)
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .accessibilityElement(children: .combine)
  }
}

private struct DetectedBranchWorkflowRow: View {
  let branch: DetectedBranchWorkflow

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
        VStack(alignment: .leading, spacing: 2) {
          Text(
            branch.branchName
              ?? (branch.manualWorkflowID == nil ? "Branch not recognized" : "Workflow inbox")
          )
          .font(.primaryDefault)
          .lineLimit(1)
          Text(branch.repositoryName)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let pullRequest = branch.pullRequest {
          Label(
            "PR #\(pullRequest.number) · \(pullRequest.state.displayName)",
            systemImage: pullRequest.state == .merged
              ? "arrow.triangle.merge" : "arrow.triangle.pull"
          )
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: DesignTokens.Spacing.lg) {
        CompactAgentRole(
          title: "Implementer",
          assignment: branch.primaryImplementer,
          additionalCount: max(0, branch.implementerSessions.count - 1)
        )
        CompactAgentRole(
          title: "Reviewer",
          assignment: branch.primaryReviewer,
          additionalCount: max(0, branch.reviewerSessions.count - 1)
        )
        Spacer(minLength: 0)
        Text(branch.lastActivityAt.timeAgoDisplay())
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }

      if let automation = branch.automatedReview {
        Label(automation.phase.displayName, systemImage: automation.phase.systemImage)
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
    .accessibilityElement(children: .combine)
  }
}

private struct CompactAgentRole: View {
  let title: String
  let assignment: DetectedAgentSession?
  let additionalCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.geist(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
      if let assignment {
        HStack(spacing: 4) {
          Image(systemName: assignment.role == .reviewer ? "doc.text.magnifyingglass" : "hammer")
          Text(assignment.provider.rawValue)
          if assignment.session.isActive {
            Text("active")
              .foregroundStyle(.secondary)
          }
          if additionalCount > 0 {
            Text("+\(additionalCount)")
              .foregroundStyle(.secondary)
          }
        }
        .font(.secondarySmall)
      } else {
        Text("Not detected")
          .font(.secondarySmall)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

private struct DetectedBranchSessionDetail: View {
  let workflowID: String
  let branch: DetectedBranchWorkflow
  let workflowSessionCount: Int
  let onOpenSession: ((DetectedAgentSession) -> Void)?
  let onCloseSession: (DetectedAgentSession) -> Void
  let onRemoveSessionOverride: (DetectedAgentSession) -> Void
  let hasSessionOverride: (DetectedAgentSession) -> Bool
  let sessionDisplayName: (DetectedAgentSession) -> String
  let onMoveSession: (String) -> Void
  let onRetryReview: () -> Void
  let onCreateReviewAgent: () -> Void
  let onCloseAllSessions: () -> Void
  let onStartSession: ((String, SessionProviderKind, String?) -> Void)?
  let comparisonRequest: WorkflowSessionComparisonRequest?
  let onCompareSessions: ((WorkflowSessionComparisonRequest) -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      detailHeader
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
          if branch.isArchived {
            Label(
              "This workflow is archived. Restore it to start or continue agent work.",
              systemImage: "archivebox"
            )
            .font(.secondarySmall)
            .foregroundStyle(.secondary)
          } else if branch.isCompleted {
            Label(
              "Pull request merged. This workflow is read-only history.",
              systemImage: "checkmark.circle"
            )
            .font(.secondarySmall)
            .foregroundStyle(.secondary)
          }

          if let automation = branch.automatedReview,
            automation.phase == .failed,
            let failureMessage = automation.failureMessage
          {
            Label(failureMessage, systemImage: "exclamationmark.triangle")
              .font(.secondarySmall)
              .foregroundStyle(.orange)
          }

          if branch.manualWorkflowID != nil,
            branch.implementerSessions.isEmpty,
            branch.reviewerSessions.isEmpty
          {
            ManualWorkflowEmptyState(
              workflowID: workflowID,
              onStartSession: onStartSession
            )

            Divider()

            RoleSessionSection(
              title: "Review agent",
              symbol: "doc.text.magnifyingglass",
              sessions: [],
              emptyMessage: "Add an implementation agent before creating a reviewer.",
              emptyActionTitle: "Create review agent",
              isEmptyActionEnabled: false,
              emptyActionHelp: "A review agent requires an implementation agent in this workflow.",
              onEmptyAction: onCreateReviewAgent,
              onOpenSession: onOpenSession,
              onCloseSession: onCloseSession,
              onRemoveSessionOverride: onRemoveSessionOverride,
              hasSessionOverride: hasSessionOverride,
              sessionDisplayName: sessionDisplayName
            )
          } else {
            RoleSessionSection(
              title: "Implementation agent",
              symbol: "hammer",
              sessions: branch.implementerSessions,
              emptyMessage: "No implementation session was detected for this branch.",
              onOpenSession: onOpenSession,
              onCloseSession: onCloseSession,
              onRemoveSessionOverride: onRemoveSessionOverride,
              hasSessionOverride: hasSessionOverride,
              sessionDisplayName: sessionDisplayName
            )

            Divider()

            RoleSessionSection(
              title: "Review agent",
              symbol: "doc.text.magnifyingglass",
              sessions: branch.reviewerSessions,
              emptyMessage: "No independent review session was detected yet.",
              emptyActionTitle: reviewActionTitle,
              isEmptyActionEnabled: canCreateReviewAgent,
              emptyActionHelp: reviewActionHelp,
              onEmptyAction: reviewActionTitle == nil ? nil : onCreateReviewAgent,
              onOpenSession: onOpenSession,
              onCloseSession: onCloseSession,
              onRemoveSessionOverride: onRemoveSessionOverride,
              hasSessionOverride: hasSessionOverride,
              sessionDisplayName: sessionDisplayName
            )
          }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .dropDestination(for: String.self) { sessionIDs, _ in
      guard let sessionID = sessionIDs.first else { return false }
      onMoveSession(sessionID)
      return true
    }
  }

  private var canCreateReviewAgent: Bool {
    branch.primaryImplementer != nil
      && branch.reviewerSessions.isEmpty
      && !branch.isCompleted
      && (branch.automatedReview == nil || branch.automatedReview?.phase == .failed)
  }

  private var reviewActionTitle: String? {
    guard branch.reviewerSessions.isEmpty else { return nil }
    if branch.automatedReview?.phase == .failed {
      return "Retry review agent"
    }
    return branch.automatedReview == nil ? "Create review agent" : nil
  }

  private var reviewActionHelp: String {
    if branch.primaryImplementer == nil {
      return "A review agent requires an implementation agent in this workflow."
    }
    return "Start an independent cross-model review of the implementation agent's current work."
  }

  private var detailHeader: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(
          branch.branchName
            ?? (branch.manualWorkflowID == nil ? "Branch not recognized" : "Workflow inbox")
        )
        .font(.primaryDefault)
        .lineLimit(1)
        Text(branch.repositoryPath)
          .font(.jetBrainsMono(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button("Close all sessions", systemImage: "xmark.circle", action: onCloseAllSessions)
        .controlSize(.small)
        .disabled(workflowSessionCount == 0)
        .help("Close every implementation and review session in this workflow")
      if let comparisonRequest, let onCompareSessions {
        Button("Side by side", systemImage: "rectangle.split.2x1") {
          onCompareSessions(comparisonRequest)
        }
        .controlSize(.small)
        .help("Open the implementation and review sessions next to each other")
      }
      if let automation = branch.automatedReview {
        Label(automation.phase.displayName, systemImage: automation.phase.systemImage)
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
        if automation.phase == .failed {
          Button("Retry reviewer", action: onRetryReview)
            .controlSize(.small)
        }
      }
      if branch.manualWorkflowID != nil, !branch.isCompleted, let onStartSession {
        Menu {
          Button("Codex") {
            onStartSession(workflowID, .codex, nil)
          }
          Button("Claude") {
            onStartSession(workflowID, .claude, nil)
          }
        } label: {
          Label("Start session", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      if let pullRequest = branch.pullRequest, let url = URL(string: pullRequest.url) {
        Link(destination: url) {
          Label("PR #\(pullRequest.number)", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.plain)
        .font(.secondarySmall)
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .frame(height: AgentHubLayout.topBarHeight)
  }
}

private struct RoleSessionSection: View {
  let title: String
  let symbol: String
  let sessions: [DetectedAgentSession]
  let emptyMessage: String
  var emptyActionTitle: String? = nil
  var isEmptyActionEnabled = true
  var emptyActionHelp = ""
  var onEmptyAction: (() -> Void)? = nil
  let onOpenSession: ((DetectedAgentSession) -> Void)?
  let onCloseSession: (DetectedAgentSession) -> Void
  let onRemoveSessionOverride: (DetectedAgentSession) -> Void
  let hasSessionOverride: (DetectedAgentSession) -> Bool
  let sessionDisplayName: (DetectedAgentSession) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Label(title, systemImage: symbol)
        .font(.primaryDefault)

      if sessions.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
          Text(emptyMessage)
            .font(.secondarySmall)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          if let emptyActionTitle, let onEmptyAction {
            Button(emptyActionTitle, action: onEmptyAction)
              .buttonStyle(.bordered)
              .controlSize(.small)
              .disabled(!isEmptyActionEnabled)
              .help(emptyActionHelp)
          }
        }
      } else {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, assignment in
          if index > 0 {
            Divider()
          }
          DetectedAgentSessionRow(
            assignment: assignment,
            isPrimary: index == 0,
            onOpenSession: onOpenSession,
            onCloseSession: onCloseSession,
            onRemoveSessionOverride: onRemoveSessionOverride,
            hasSessionOverride: hasSessionOverride,
            displayName: sessionDisplayName(assignment)
          )
        }
      }
    }
  }
}

private struct DetectedAgentSessionRow: View {
  let assignment: DetectedAgentSession
  let isPrimary: Bool
  let onOpenSession: ((DetectedAgentSession) -> Void)?
  let onCloseSession: (DetectedAgentSession) -> Void
  let onRemoveSessionOverride: (DetectedAgentSession) -> Void
  let hasSessionOverride: (DetectedAgentSession) -> Bool
  let displayName: String

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        HStack(spacing: DesignTokens.Spacing.sm) {
          Text(assignment.provider.rawValue)
            .font(.secondarySmall)
          Text(displayName)
            .font(.jetBrainsMono(size: 10))
            .foregroundStyle(.secondary)
          if assignment.session.isActive {
            Label("Active", systemImage: "circle.fill")
              .font(.secondaryCaption)
              .foregroundStyle(.green)
          } else if isPrimary {
            Text("Latest")
              .font(.secondaryCaption)
              .foregroundStyle(.secondary)
          }
        }

        if let message = assignment.session.firstMessage, !message.isEmpty {
          Text(message)
            .font(.secondaryDefault)
            .lineLimit(3)
        }

        Text("\(assignment.roleReason) · \(assignment.roleConfidence.label) confidence")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      if let onOpenSession {
        Button("Open terminal") {
          onOpenSession(assignment)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Menu {
        if let onOpenSession {
          Button("Open terminal") {
            onOpenSession(assignment)
          }
        }
        if hasSessionOverride(assignment) {
          Button("Return to detected workflow") {
            onRemoveSessionOverride(assignment)
          }
        }
        Divider()
        Button("Close session", role: .destructive) {
          onCloseSession(assignment)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Session actions")
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
    .accessibilityElement(children: .contain)
    .draggable(assignment.id) {
      Label(
        "\(assignment.provider.rawValue) · \(displayName)",
        systemImage: assignment.role == .reviewer ? "doc.text.magnifyingglass" : "hammer"
      )
      .padding(DesignTokens.Spacing.sm)
    }
  }
}

private struct ManualWorkflowCreationRequest {
  let name: String
  let repositoryPath: String
  let branchName: String?
  let provider: SessionProviderKind
  let prompt: String
}

private struct CreateManualWorkflowSheet: View {
  let onCreate: (ManualWorkflowCreationRequest) -> Bool
  let onDismiss: () -> Void

  @State private var name = ""
  @State private var repositoryPath = ""
  @State private var branchName = ""
  @State private var provider = SessionProviderKind.codex
  @State private var prompt = ""
  @FocusState private var focusedField: Field?

  private enum Field {
    case name
    case prompt
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Label("New Workflow", systemImage: "rectangle.stack.badge.plus")
          .font(.headline)
        Text("Create the workflow and start its implementation agent immediately.")
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
      }

      Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: 10) {
        GridRow {
          fieldLabel("Title")
          TextField("Workflow name or Jira ticket", text: $name)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .name)
        }

        GridRow {
          fieldLabel("Repository")
          HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Repository or worktree path", text: $repositoryPath)
              .textFieldStyle(.roundedBorder)
            Button("Choose…", action: chooseRepository)
              .controlSize(.small)
          }
        }

        GridRow {
          fieldLabel("Branch")
          TextField("Optional", text: $branchName)
            .textFieldStyle(.roundedBorder)
        }

        GridRow {
          fieldLabel("Implementer")
          Picker("Implementation agent", selection: $provider) {
            Text("Codex").tag(SessionProviderKind.codex)
            Text("Claude").tag(SessionProviderKind.claude)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 240)
        }
      }

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text("Implementation prompt")
          .font(.secondarySmall)
        TextField(
          "Describe what the implementation agent should build, change, or investigate.",
          text: $prompt,
          axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(6...10)
        .focused($focusedField, equals: .prompt)
      }

      HStack(spacing: DesignTokens.Spacing.sm) {
        Label(
          "The new session is linked as the implementation agent.",
          systemImage: "hammer"
        )
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)

        Spacer()

        Button("Cancel", action: onDismiss)
          .keyboardShortcut(.cancelAction)
        Button("Create & Start", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
    }
    .padding(DesignTokens.Spacing.xl)
    .frame(width: 580)
    .onAppear { focusedField = .name }
  }

  private func fieldLabel(_ title: String) -> some View {
    Text(title)
      .font(.secondarySmall)
      .frame(width: 82, alignment: .trailing)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedRepositoryPath: String {
    repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedPrompt: String {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canCreate: Bool {
    !trimmedName.isEmpty && !trimmedRepositoryPath.isEmpty && !trimmedPrompt.isEmpty
  }

  private func chooseRepository() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Repository"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    repositoryPath = url.path
  }

  private func create() {
    guard canCreate else { return }
    let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = ManualWorkflowCreationRequest(
      name: trimmedName,
      repositoryPath: trimmedRepositoryPath,
      branchName: trimmedBranch.isEmpty ? nil : trimmedBranch,
      provider: provider,
      prompt: trimmedPrompt
    )
    if onCreate(request) {
      onDismiss()
    }
  }
}

private struct ManualWorkflowEmptyState: View {
  let workflowID: String
  let onStartSession: ((String, SessionProviderKind, String?) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Label("No sessions yet", systemImage: "tray")
        .font(.primaryDefault)
      Text("Drag a session onto this workflow, or start a new local agent here.")
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
      if let onStartSession {
        HStack(spacing: DesignTokens.Spacing.sm) {
          Button("Start Codex") {
            onStartSession(workflowID, .codex, nil)
          }
          Button("Start Claude") {
            onStartSession(workflowID, .claude, nil)
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
    .padding(DesignTokens.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

extension AgentDetectionConfidence {
  fileprivate var label: String {
    switch self {
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    }
  }
}

extension AutomatedReviewPhase {
  fileprivate var displayName: String {
    switch self {
    case .reviewerLaunching: "Starting cross-model reviewer"
    case .reviewing: "Independent review in progress"
    case .feedbackDelivered: "Review feedback sent to implementer"
    case .approved: "Independent review approved"
    case .needsHumanIntervention: "Review needs human intervention"
    case .failed: "Review automation failed"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .reviewerLaunching: "arrow.triangle.2.circlepath"
    case .reviewing: "doc.text.magnifyingglass"
    case .feedbackDelivered: "arrow.uturn.backward.circle"
    case .approved: "checkmark.circle"
    case .needsHumanIntervention: "person.crop.circle.badge.exclamationmark"
    case .failed: "exclamationmark.triangle"
    }
  }
}
