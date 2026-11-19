//
//  MonitoringCardView.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

import AgentHubGitDiff
import AgentHubGitHub
import SwiftUI
import UniformTypeIdentifiers

// MARK: - MonitoringCardView

/// Card view for displaying a monitored session in the monitoring panel
public struct MonitoringCardView: View {
  let session: CLISession
  let state: SessionMonitorState?
  let planState: PlanState?
  let cliConfiguration: CLICommandConfiguration?
  let providerKind: SessionProviderKind
  let initialPrompt: String?
  let initialInputText: String?
  let launchContext: String?  // Curated context, delivered via the system-prompt channel
  let terminalKey: String?  // Key for terminal storage (session ID or "pending-{pendingId}")
  let viewModel: CLISessionsViewModel?
  let editorProjectPath: String
  let editorNavigationRequest: FileExplorerNavigationRequest?
  var dangerouslySkipPermissions: Bool = false
  var permissionModePlan: Bool = false
  let worktreeName: String?
  let onStopMonitoring: () -> Void
  let onConnect: () -> Void
  let onCopySessionId: () -> Void
  let onOpenSessionFile: () -> Void
  let onRefreshTerminal: () -> Void
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?
  let onShowDiff: ((CLISession, String) -> Void)?
  let onShowPlan: ((CLISession, PlanState) -> Void)?
  let onShowWebPreview: ((CLISession, String, WebPreviewMode) -> Void)?
  let onShowMermaid: ((CLISession) -> Void)?
  let onShowGitHub: ((CLISession, String, [GitHubPullRequestURLReference]) -> Void)?
  let onShowPendingChanges: ((CLISession, PendingToolUse) -> Void)?
  let onShowMCPApp: ((CLISession, String) -> Void)?
  let onShowMeasurement: ((CLISession) -> Void)?
  let onShowArtifact: ((CLISession) -> Void)?
  let onShowStudio: ((CLISession) -> Void)?
  let onShowSimulatorPreview: ((CLISession, String) -> Void)?
  let onFork: ((CLISession, SessionProviderKind) -> Void)?
  let onPromptConsumed: (() -> Void)?
  let onTerminalInteraction: (() -> Void)?
  let onRequestShowEditor: (() -> Void)?
  let isPrimarySession: Bool
  let showPrimaryIndicator: Bool
  var isSidePanelOpen: Bool = false
  @Binding private var contentMode: MonitoringCardContentMode
  @Binding private var selectedEditorFilePath: String?

  @State private var simulatorSheetSession: CLISession?
  @State private var sessionGitHubQuickAccessViewModel = SessionGitHubQuickAccessViewModel()
  @State private var isDragging = false
  @State private var showingActionsPopover = false
  @State private var showingFilePicker = false
  @State private var showingNameSheet = false
  @State private var activityRefreshTask: Task<Void, Never>?
  @State private var pendingActivityTimestamp: Date?
  /// What the agent tab's screen says right now (compacting), when readable.
  @State private var liveTerminalStatus: String?
  @AppStorage(AgentHubDefaults.chatEnabled) private var chatEnabled = false
  @AppStorage(AgentHubDefaults.diffDisplayMode)
  private var diffDisplayModeRawValue: String = DiffDisplayMode.inline.rawValue
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme

  public init(
    session: CLISession,
    state: SessionMonitorState?,
    planState: PlanState? = nil,
    cliConfiguration: CLICommandConfiguration? = nil,
    providerKind: SessionProviderKind = .claude,
    initialPrompt: String? = nil,
    initialInputText: String? = nil,
    launchContext: String? = nil,
    terminalKey: String? = nil,
    viewModel: CLISessionsViewModel? = nil,
    contentMode: Binding<MonitoringCardContentMode> = .constant(.terminal),
    selectedEditorFilePath: Binding<String?> = .constant(nil),
    editorProjectPath: String? = nil,
    editorNavigationRequest: FileExplorerNavigationRequest? = nil,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    worktreeName: String? = nil,
    onStopMonitoring: @escaping () -> Void,
    onConnect: @escaping () -> Void,
    onCopySessionId: @escaping () -> Void,
    onOpenSessionFile: @escaping () -> Void,
    onRefreshTerminal: @escaping () -> Void,
    onInlineRequestSubmit: ((String, CLISession) -> Void)? = nil,
    onShowDiff: ((CLISession, String) -> Void)? = nil,
    onShowPlan: ((CLISession, PlanState) -> Void)? = nil,
    onShowWebPreview: ((CLISession, String, WebPreviewMode) -> Void)? = nil,
    onShowMermaid: ((CLISession) -> Void)? = nil,
    onShowGitHub:
      ((CLISession, String, [GitHubPullRequestURLReference]) -> Void)? = nil,
    onShowPendingChanges: ((CLISession, PendingToolUse) -> Void)? = nil,
    onShowMCPApp: ((CLISession, String) -> Void)? = nil,
    onShowMeasurement: ((CLISession) -> Void)? = nil,
    onShowArtifact: ((CLISession) -> Void)? = nil,
    onShowStudio: ((CLISession) -> Void)? = nil,
    onShowSimulatorPreview: ((CLISession, String) -> Void)? = nil,
    onFork: ((CLISession, SessionProviderKind) -> Void)? = nil,
    onPromptConsumed: (() -> Void)? = nil,
    onTerminalInteraction: (() -> Void)? = nil,
    onRequestShowEditor: (() -> Void)? = nil,
    isPrimarySession: Bool = false,
    showPrimaryIndicator: Bool = false,
    isSidePanelOpen: Bool = false
  ) {
    self.session = session
    self.state = state
    self.planState = planState
    self.cliConfiguration = cliConfiguration
    self.providerKind = providerKind
    self.initialPrompt = initialPrompt
    self.initialInputText = initialInputText
    self.launchContext = launchContext
    self.terminalKey = terminalKey
    self.viewModel = viewModel
    self._contentMode = contentMode
    self._selectedEditorFilePath = selectedEditorFilePath
    self.editorProjectPath = editorProjectPath ?? session.projectPath
    self.editorNavigationRequest = editorNavigationRequest
    self.dangerouslySkipPermissions = dangerouslySkipPermissions
    self.permissionModePlan = permissionModePlan
    self.worktreeName = worktreeName
    self.onStopMonitoring = onStopMonitoring
    self.onConnect = onConnect
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.onRefreshTerminal = onRefreshTerminal
    self.onInlineRequestSubmit = onInlineRequestSubmit
    self.onShowDiff = onShowDiff
    self.onShowPlan = onShowPlan
    self.onShowWebPreview = onShowWebPreview
    self.onShowMermaid = onShowMermaid
    self.onShowGitHub = onShowGitHub
    self.onShowPendingChanges = onShowPendingChanges
    self.onShowMCPApp = onShowMCPApp
    self.onShowMeasurement = onShowMeasurement
    self.onShowArtifact = onShowArtifact
    self.onShowStudio = onShowStudio
    self.onShowSimulatorPreview = onShowSimulatorPreview
    self.onFork = onFork
    self.onPromptConsumed = onPromptConsumed
    self.onTerminalInteraction = onTerminalInteraction
    self.onRequestShowEditor = onRequestShowEditor
    self.isPrimarySession = isPrimarySession
    self.showPrimaryIndicator = showPrimaryIndicator
    self.isSidePanelOpen = isSidePanelOpen
  }

  private var queuedPreviewContextCount: Int {
    viewModel?.queuedWebPreviewContextStore.count(for: session.id) ?? 0
  }

  private var webPreviewCandidateStatus: WebPreviewCandidateStatus? {
    viewModel?.webPreviewCandidateStatus(for: session.projectPath)
  }

  private var projectCapabilities: ProjectCapabilities? {
    viewModel?.projectCapabilities(for: session.projectPath)
  }

  private var diffDisplayMode: DiffDisplayMode {
    DiffDisplayMode(rawValue: diffDisplayModeRawValue) ?? .inline
  }

  private var diffAvailabilityStatus: DiffAvailabilityStatus? {
    viewModel?.diffAvailabilityStatus(for: session.projectPath)
  }

  private var availableContentModes: [MonitoringCardContentMode] {
    MonitoringEditorStateStore.availableContentModes(
      diffDisplayMode: diffDisplayMode,
      diffAvailabilityStatus: diffAvailabilityStatus,
      chatEnabled: chatEnabled
    )
  }

  private var effectiveContentMode: MonitoringCardContentMode {
    MonitoringEditorStateStore.coercedContentMode(
      contentMode,
      availableModes: availableContentModes
    )
  }

  private var hasStorybook: Bool {
    projectCapabilities?.hasStorybook == true
  }

  private var isXcodeProject: Bool {
    projectCapabilities?.isXcodeProject == true
  }

  private var shouldShowWebPreviewButton: Bool {
    WebPreviewCandidateVisibility.shouldShow(
      candidateStatus: webPreviewCandidateStatus,
      detectedLocalhostURL: state?.detectedLocalhostURL
    )
  }

  private var resourceLinks: [ResourceLink] {
    state?.detectedResourceLinks ?? []
  }

  /// MCP apps to surface for this session: resources embedded in the JSONL plus
  /// host-rendered apps resolved from app-bearing tool calls (see the ViewModel).
  private var mcpAppDisplayItems: [MCPAppRenderItem] {
    viewModel?.mcpAppDisplayItems(for: session, state: state) ?? []
  }

  private var mcpAppResourceCount: Int {
    mcpAppDisplayItems.count
  }

  private var shouldShowMCPAppsButton: Bool {
    !mcpAppDisplayItems.isEmpty
  }

  /// Key that changes when the set of detected MCP tool invocations changes, so
  /// host-app resolution re-runs only when the agent makes a new app-bearing call.
  private var measurementCount: Int {
    viewModel?.measurements(for: session).count ?? 0
  }

  /// Claude-only: Codex and Antigravity have no artifact surface, so their parsers never file any.
  private var detectedArtifacts: [ClaudeArtifact] {
    guard providerKind == .claude else { return [] }
    return state?.detectedArtifacts ?? []
  }

  private var artifactButtonAccessibilityLabel: String {
    detectedArtifacts.count == 1
      ? "Open 1 published artifact"
      : "Open \(detectedArtifacts.count) published artifacts"
  }

  /// Studio items filed for this session's project — shared across both providers.
  private var studioArtifactCount: Int {
    viewModel?.studioArtifacts(for: session).count ?? 0
  }

  private var studioButtonAccessibilityLabel: String {
    studioArtifactCount == 1 ? "Open 1 Studio artifact" : "Open \(studioArtifactCount) Studio artifacts"
  }

  private var measurementButtonAccessibilityLabel: String {
    measurementCount == 1 ? "Open 1 recorded measurement" : "Open \(measurementCount) recorded measurements"
  }

  private var mcpAppInvocationResolutionKey: String {
    (state?.detectedMCPAppInvocations ?? []).map(\.id).joined(separator: ",")
  }

  private var mcpAppButtonAccessibilityLabel: String {
    mcpAppResourceCount == 1 ? "Open 1 MCP app" : "Open \(mcpAppResourceCount) MCP apps"
  }

  /// Memoized: read from `body`, so it re-parsed every detected link on each render.
  private var linkedPullRequests: [GitHubPullRequestURLReference] {
    let detected = GitHubPullRequestURLReferenceCache.references(in: resourceLinks.map(\.url))
    let itemID = SidebarSessionItemID.monitored(provider: providerKind, sessionId: session.id)
    let provider = viewModel?.agentHubProvider ?? agentHub
    let associated =
      provider?.gitHubReviewsViewModel
      .linkedPullRequestReferencesByItemID(provider: providerKind)[itemID] ?? []
    var seen: Set<GitHubPullRequestURLReference> = []
    return (detected + associated).filter { seen.insert($0).inserted }
  }

  private var hubProvider: AgentHubProvider? {
    viewModel?.agentHubProvider ?? agentHub
  }

  /// Jira ticket this session works on, from its branch, name, or first prompt.
  private var linkedTicketKey: String? {
    guard let jira = hubProvider?.jiraSprintViewModel else { return nil }
    return jira.sessionLinker.cachedKeys(
      id: SidebarSessionItemID.monitored(provider: providerKind, sessionId: session.id),
      branchName: session.branchName,
      customName: viewModel?.sessionCustomNames[session.id],
      prompt: session.firstMessage,
      knownProjectKeys: jira.knownProjectKeys
    ).first
  }

  private var localDiffSummary: LocalDiffSummary? {
    viewModel?.localDiffSummary(for: session.projectPath)
  }

  private var shouldShowResourcesPanel: Bool {
    !resourceLinks.isEmpty
      || sessionGitHubQuickAccessViewModel.currentBranchPR != nil
      || (localDiffSummary?.fileCount ?? 0) > 0
  }

  private var gitHubQuickAccessCoordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)? {
    viewModel?.agentHubProvider?.gitHubQuickAccessCoordinator
      ?? agentHub?.gitHubQuickAccessCoordinator
  }

  private var gitHubPRObservationService: (any GitHubPRObservationServiceProtocol)? {
    viewModel?.agentHubProvider?.gitHubPRObservationService ?? agentHub?.gitHubPRObservationService
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with session info and actions
      header
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(minHeight: AgentHubLayout.topBarHeight)

      Divider()

      // Path row with repo path, branch, and GitHub button
      pathRow
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: AgentHubLayout.subBarHeight)

      // Terminal content
      Divider()

      SessionSubagentsSection(
        session: session,
        providerKind: providerKind,
        refreshTrigger: state?.lastActivityAt,
        service: hubProvider?.subagentDiscoveryService,
        reader: hubProvider?.chatTranscriptReader ?? ChatTranscriptReader()
      )

      monitorContent

      ResourceLinksPanel(
        links: resourceLinks,
        providerKind: providerKind,
        currentPullRequest: sessionGitHubQuickAccessViewModel.currentBranchPR,
        localDiffSummary: localDiffSummary,
        onCreatePullRequest: createPullRequestFromSession
      ) {
        Button {
          showingActionsPopover = true
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(Color.brandPrimary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingActionsPopover) {
          actionsPopoverContent
        }
        .help("Session actions")
      }
    }
    .background(.clear)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(
          showPrimaryIndicator && isPrimarySession
            ? Color.brandPrimary(for: providerKind)
            : Color.clear,
          lineWidth: 1
        )
    )
    .shadow(
      color: Color.blue.opacity(isDragging ? 0.875 : 0),
      radius: isDragging ? 12 : 0
    )
    .animation(.easeInOut(duration: 0.2), value: isDragging)
    .task(id: session.projectPath) {
      await loadWebPreviewCandidateIfNeeded()
    }
    .task(id: liveStatusPollKey) {
      await pollLiveTerminalStatus()
    }
    .task {
      // Project keys come from Jira; without them branch names can't be matched.
      await hubProvider?.jiraSprintViewModel.loadIfNeeded()
    }
    .task(id: session.projectPath) {
      await viewModel?.ensureProjectCapabilities(for: session.projectPath)
    }
    .task(id: session.projectPath) {
      await viewModel?.ensureDiffAvailability(for: session.projectPath, forceRefresh: true)
    }
    .task(id: session.projectPath) {
      await viewModel?.ensureLocalDiffSummary(for: session.projectPath, forceRefresh: true)
    }
    .task(id: mcpAppInvocationResolutionKey) {
      await viewModel?.ensureMCPAppRenderItems(for: session, state: state)
    }
    // Measurements outlive the session that filed them, so the button has to reflect
    // what this project already holds — not just what this session produced.
    .task(id: session.projectPath) {
      viewModel?.loadMeasurements(for: session)
      viewModel?.loadStudioArtifacts(for: session)
    }
    .task(id: gitHubObservationTaskID) {
      if linkedPullRequests.isEmpty {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
      }
      if let notifier = viewModel?.agentHubProvider?.gitHubCIFailureNotifier
        ?? agentHub?.gitHubCIFailureNotifier
      {
        let context = GitHubCIFailureSessionContext(
          sessionId: session.id,
          providerKind: providerKind,
          projectPath: session.projectPath,
          branchName: session.branchName
        )
        sessionGitHubQuickAccessViewModel.onSnapshotApplied = { snapshot in
          notifier.evaluate(snapshot: snapshot, context: context)
        }
      }
      await sessionGitHubQuickAccessViewModel.load(
        projectPath: session.projectPath,
        branchName: session.branchName,
        linkedPullRequests: linkedPullRequests,
        coordinator: gitHubQuickAccessCoordinator,
        observationService: gitHubPRObservationService
      )
      if let lastActivityAt = state?.lastActivityAt {
        await sessionGitHubQuickAccessViewModel.notifySessionActivity(at: lastActivityAt)
      }
    }
    .onDisappear {
      sessionGitHubQuickAccessViewModel.stopPolling()
      activityRefreshTask?.cancel()
      activityRefreshTask = nil
    }
    .onChange(of: state?.lastActivityAt) { _, newValue in
      guard let newValue else { return }
      // Coalesce to one refresh pass per 2s: this fires on every parsed JSONL
      // activity while the agent streams, and per-tick forced git refreshes
      // thrash the observable dictionaries and the diff actors. The trailing
      // task picks up the latest timestamp at fire time.
      pendingActivityTimestamp = newValue
      guard activityRefreshTask == nil else { return }
      activityRefreshTask = Task { @MainActor in
        defer { activityRefreshTask = nil }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, let timestamp = pendingActivityTimestamp else { return }
        pendingActivityTimestamp = nil
        await sessionGitHubQuickAccessViewModel.notifySessionActivity(at: timestamp)
        await loadWebPreviewCandidateIfNeeded()
        await viewModel?.ensureDiffAvailability(for: session.projectPath, forceRefresh: true)
        await viewModel?.ensureLocalDiffSummary(for: session.projectPath, forceRefresh: true)
      }
    }
    .onChange(of: state?.detectedLocalhostURL) { _, newValue in
      guard newValue == nil else { return }
      Task {
        await loadWebPreviewCandidateIfNeeded()
      }
    }
    .onDrop(
      of: [.agentHubGitHubContextItem, .fileURL, .png, .tiff, .image, .pdf],
      isTargeted: $isDragging
    ) { providers in
      handleDroppedItems(providers)
      return true
    }
    .sheet(item: $simulatorSheetSession) { session in
      SimulatorPickerView(
        session: session,
        onDismiss: { simulatorSheetSession = nil },
        onSendToSession: { error in
          guard let vm = viewModel else { return }
          vm.showTerminalWithPrompt(
            for: session,
            prompt: SimulatorBuildErrorPromptBuilder.prompt(for: error))
          simulatorSheetSession = nil
        }
      )
    }
    .sheet(isPresented: $showingNameSheet) {
      NameSessionSheet(
        session: session,
        currentName: viewModel?.sessionCustomNames[session.id],
        onSave: { name in
          viewModel?.setCustomName(name, for: session)
        },
        onDismiss: { showingNameSheet = false }
      )
    }
    .fileImporter(
      isPresented: $showingFilePicker,
      allowedContentTypes: [.image, .pdf, .plainText, .data],
      allowsMultipleSelection: true
    ) { result in
      handlePickedFiles(result)
    }
  }

  private var isHighlighted: Bool {
    guard let state = state else { return false }
    switch state.status {
    case .awaitingApproval, .executingTool, .thinking:
      return true
    default:
      return false
    }
  }

  // MARK: - Drag and Drop

  /// Handles dropped providers by typing context into the terminal without submitting.
  private func handleDroppedItems(_ providers: [NSItemProvider]) {
    guard let key = terminalKey, let viewModel = viewModel else { return }

    if handleDroppedGitHubContext(providers, key: key, viewModel: viewModel) {
      return
    }

    handleDroppedFiles(providers, key: key, viewModel: viewModel)
  }

  private func handleDroppedGitHubContext(
    _ providers: [NSItemProvider],
    key: String,
    viewModel: CLISessionsViewModel
  ) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(GitHubContextDragPayload.typeIdentifier)
      })
    else {
      return false
    }

    GitHubContextDragPayload.load(from: provider) { payload in
      guard let payload else { return }

      Task { @MainActor in
        contentMode = .terminal
        viewModel.typeToTerminal(forKey: key, text: payload.commandText + " ")
        viewModel.focusTerminal(forKey: key)
      }
    }

    return true
  }

  /// Handles dropped file providers by extracting paths and typing them into terminal.
  private func handleDroppedFiles(
    _ providers: [NSItemProvider],
    key: String,
    viewModel: CLISessionsViewModel
  ) {
    for provider in providers {
      // Handle file URLs (files dragged from Finder)
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
          guard let url = url, error == nil else { return }

          Task { @MainActor in
            let path = url.path
            let quotedPath = path.contains(" ") ? "\"\(path)\"" : path
            viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
          }
        }
      }
      // Handle PNG data (screenshots)
      else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
        _ = provider.loadDataRepresentation(for: .png) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("screenshot_\(UUID().uuidString).png")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped screenshot: \(error)")
            }
          }
        }
      }
      // Handle TIFF data (another screenshot format)
      else if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
        _ = provider.loadDataRepresentation(for: .tiff) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("screenshot_\(UUID().uuidString).tiff")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped screenshot: \(error)")
            }
          }
        }
      }
      // Handle generic image data
      else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        _ = provider.loadDataRepresentation(for: .image) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("dropped_image_\(UUID().uuidString).png")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped image: \(error)")
            }
          }
        }
      }
      // Handle PDF data (documents dragged from Preview or other apps)
      else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
        _ = provider.loadDataRepresentation(for: .pdf) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("dropped_document_\(UUID().uuidString).pdf")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped PDF: \(error)")
            }
          }
        }
      }
    }
  }

  // MARK: - File Picker

  /// Handles files selected from the file picker by typing their paths into terminal
  private func handlePickedFiles(_ result: Result<[URL], Error>) {
    guard let key = terminalKey, let viewModel = viewModel else { return }

    switch result {
    case .success(let urls):
      for url in urls {
        let path = url.path
        let quotedPath = path.contains(" ") ? "\"\(path)\"" : path
        viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
      }
    case .failure(let error):
      print("File picker error: \(error.localizedDescription)")
    }
  }

  private func presentWebPreview(mode: WebPreviewMode = .app) {
    onShowWebPreview?(session, session.projectPath, mode)
  }

  @MainActor
  private func loadWebPreviewCandidateIfNeeded() async {
    guard state?.detectedLocalhostURL == nil else { return }
    await viewModel?.ensureWebPreviewCandidate(for: session.projectPath)
  }

  private func presentGitHubPanel() {
    onShowGitHub?(session, session.projectPath, linkedPullRequests)
  }

  private var gitHubObservationTaskID: String {
    SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: session.projectPath,
      branchName: session.branchName,
      linkedPullRequests: linkedPullRequests
    )
  }

  private static let createPullRequestPrompt =
    "Make a PR for the current branch. Include the local changes in this worktree and use the session context for the title, body, and validation notes."

  private func createPullRequestFromSession() {
    guard let viewModel else { return }
    let key = terminalKey ?? session.id
    contentMode = .terminal
    if !viewModel.sendPromptToActiveTerminal(forKey: key, prompt: Self.createPullRequestPrompt) {
      viewModel.showTerminalWithPrompt(for: session, prompt: Self.createPullRequestPrompt)
    }
    viewModel.focusTerminal(forKey: key)
  }

  // MARK: - Header

  /// Parent module for the header label: repo name plus whether the session
  /// runs in a worktree, resolved via the selected repositories.
  private var sessionModulePreview: SessionHoverPreview {
    SessionHoverPreview.make(
      session: session,
      customName: nil,
      repositories: WorktreeModuleResolver.mergedRepositories(
        (agentHub?.claudeSessionsViewModel.selectedRepositories ?? [])
          + (agentHub?.codexSessionsViewModel.selectedRepositories ?? [])
          + (agentHub?.antigravitySessionsViewModel.selectedRepositories ?? [])
      )
    )
  }

  private var isWorktreeSession: Bool {
    sessionModulePreview.worktreePath != nil
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        // Activity indicator: the dot plus a word, so state never depends on color alone.
        HStack(spacing: 5) {
          Circle()
            .fill(isHighlighted ? Color.brandPrimary(for: providerKind) : .gray.opacity(0.3))
            .frame(width: 10, height: 10)
            .shadow(
              color: isHighlighted ? Color.brandPrimary(for: providerKind).opacity(0.6) : .clear,
              radius: 4)
            .accessibilityHidden(true)
          if let statusWord {
            Text(statusWord)
              .font(.secondaryCaption)
              .foregroundStyle(isHighlighted ? Color.brandPrimary(for: providerKind) : .secondary)
              .lineLimit(1)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(statusWord ?? "unknown")")
        .help(statusWord ?? "Status unknown")

        Text(sessionDisplayName)
          .font(.primaryDefault)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(1)

        // Provider name with brand color
        Text(providerKind.rawValue)
          .font(.secondaryCaption)
          .foregroundColor(.brandPrimary(for: providerKind))
          .fixedSize()
          .layoutPriority(1)

        Spacer(minLength: 8)

        // Attention first: what needs you now stays a button.
        if let pendingToolUse = state?.pendingToolUse,
          pendingToolUse.isCodeChangeTool
        {
          Button(action: {
            onShowPendingChanges?(session, pendingToolUse)
          }) {
            HStack(spacing: 4) {
              Image(systemName: "eye")
                .font(.caption2)
              Text("Edits")
            }
          }
          .buttonStyle(.agentHubOutlined(tint: .orange))
          .fixedSize()
          .help("Preview pending \(pendingToolUse.toolName) change")
        }

        if let planState = planState {
          Button(action: {
            onShowPlan?(session, planState)
          }) {
            HStack(spacing: 4) {
              Image(systemName: "list.bullet.clipboard")
                .font(.caption2)
              Text("Plan")
            }
          }
          .buttonStyle(.agentHubOutlined(tint: .orange))
          .fixedSize()
          .help("View session plan")
        }

      }
      HStack(spacing: 8) {
        // Where you work: Terminal, Chat, Files, Diffs. One control, always visible.
        CompactPillSegmentedControl(
          selection: contentModeSelection,
          items: contentModeItems,
          selectedColor: Color.brandSecondary(for: providerKind),
          accessibilityLabel: "Session view"
        )
        .fixedSize()
        .layoutPriority(2)
        .help("Switch between Terminal, Chat, Files, and Diffs")

        Spacer(minLength: 0)

        // Secondary tools stay available without crowding the primary modes.
        toolsMenu
          .fixedSize()
          .layoutPriority(2)
      }
    }
  }

  private var contentModeSelection: Binding<MonitoringCardContentMode> {
    Binding(
      get: { effectiveContentMode },
      set: { contentMode = $0 }
    )
  }

  private var contentModeItems: [CompactPillSegmentedControlItem<MonitoringCardContentMode>] {
    availableContentModes.map { mode in
      CompactPillSegmentedControlItem(value: mode, title: mode.label, helpText: mode.label)
    }
  }

  /// Side panels this session can open. Items appear only when they apply;
  /// the count in the label says how many agent-produced things are waiting.
  private var toolsMenu: some View {
    Menu {
      if diffDisplayMode == .sidePanel {
        Button {
          onShowDiff?(session, session.projectPath)
        } label: {
          Label("Diff", systemImage: "arrow.left.arrow.right")
        }
      }

      // Storybook takes precedence when present: showing both would route the
      // same pane to two URLs.
      if hasStorybook {
        Button {
          Task {
            await DevServerManager.shared.startStorybookServer(
              for: session.id,
              projectPath: session.projectPath
            )
          }
          presentWebPreview(mode: .storybook)
        } label: {
          Label("Storybook", systemImage: "book.pages")
        }
      } else if shouldShowWebPreviewButton {
        Button {
          presentWebPreview(mode: .app)
        } label: {
          Label(
            queuedPreviewContextCount > 0
              ? "Preview (\(queuedPreviewContextCount) queued updates)" : "Preview",
            systemImage: "globe")
        }
      }

      if shouldShowMCPAppsButton {
        Button {
          onShowMCPApp?(session, session.projectPath)
        } label: {
          Label("MCP apps (\(mcpAppResourceCount))", systemImage: "square.stack.3d.up")
        }
        .accessibilityLabel(mcpAppButtonAccessibilityLabel)
      }

      if measurementCount > 0 {
        Button {
          onShowMeasurement?(session)
        } label: {
          Label("Measurements (\(measurementCount))", systemImage: "chart.bar.doc.horizontal")
        }
        .accessibilityLabel(measurementButtonAccessibilityLabel)
      }

      if onShowStudio != nil, studioArtifactCount > 0 {
        Button {
          onShowStudio?(session)
        } label: {
          Label("Studio (\(studioArtifactCount))", systemImage: "paintpalette")
        }
        .accessibilityLabel(studioButtonAccessibilityLabel)
      }

      if onShowArtifact != nil, !detectedArtifacts.isEmpty {
        Button {
          onShowArtifact?(session)
        } label: {
          Label("Artifact (\(detectedArtifacts.count))", systemImage: "sparkles.rectangle.stack")
        }
        .accessibilityLabel(artifactButtonAccessibilityLabel)
      }

      if state?.hasMermaidContent == true {
        Button {
          onShowMermaid?(session)
        } label: {
          Label("Diagram", systemImage: "chart.xyaxis.line")
        }
      }

      // Xcode projects: the live simulator panel, or the legacy management
      // sheet where the panel callback is not wired.
      if isXcodeProject {
        Button {
          if onShowSimulatorPreview != nil {
            onShowSimulatorPreview?(session, session.projectPath)
          } else {
            simulatorSheetSession = session
          }
        } label: {
          Label("Simulator", systemImage: "iphone.gen3")
        }
      }

      Button(action: presentGitHubPanel) {
        Label("GitHub", systemImage: "arrow.triangle.pull")
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "square.grid.2x2")
          .font(.caption2)
        Text("Tools")
        if toolsAttentionCount > 0 {
          Text("\(toolsAttentionCount)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
    }
    .menuStyle(.borderlessButton)
    .help("Panels this session can open: GitHub, diff, preview, simulator, and what the agent produced")
    .accessibilityLabel(
      toolsAttentionCount > 0
        ? "Tools menu, \(toolsAttentionCount) agent results waiting" : "Tools menu")
  }

  /// Things the agent produced that are waiting to be looked at.
  private var toolsAttentionCount: Int {
    mcpAppResourceCount + measurementCount + studioArtifactCount + detectedArtifacts.count
  }

  /// One word for the header: what the agent is doing right now.
  private var statusWord: String? {
    if let state { return state.status.displayName }
    return session.id.hasPrefix("pending-") ? "Starting" : nil
  }

  // MARK: - Actions Popover Content

  private var actionsPopoverContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Session actions (always visible)
      PopoverButton(icon: "doc.on.doc", title: "Copy Session ID") {
        onCopySessionId()
        showingActionsPopover = false
      }
      PopoverButton(icon: "doc.text", title: "View Transcript") {
        onOpenSessionFile()
        showingActionsPopover = false
      }
      if providerKind == .claude {
        PopoverButton(icon: "rectangle.portrait.and.arrow.right", title: "Open in Terminal") {
          onConnect()
          showingActionsPopover = false
        }
      }
      // Restarts the terminal process; a rare action, so it lives here and not
      // in the header next to the everyday buttons.
      PopoverButton(icon: "arrow.clockwise", title: "Refresh Terminal") {
        showingActionsPopover = false
        onRefreshTerminal()
      }
      PopoverButton(icon: "pencil", title: "Name Session") {
        showingActionsPopover = false
        showingNameSheet = true
      }

      PopoverButton(icon: "arrow.triangle.branch", title: "Fork") {
        showingActionsPopover = false
        if let onFork {
          onFork(session, providerKind)
        } else {
          viewModel?.forkSession(session, targetProvider: providerKind)
        }
      }

      Divider()
        .padding(.vertical, DesignTokens.Spacing.xs)

      PopoverButton(icon: "plus.rectangle.on.folder", title: "Add Files") {
        showingActionsPopover = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          showingFilePicker = true
        }
      }
    }
    .padding(DesignTokens.Spacing.sm)
  }

  // MARK: - Path Row

  private var pathRow: some View {
    MonitoringCardPathRow(
      session: session,
      providerKind: providerKind,
      isWorktree: isWorktreeSession,
      linkedPullRequest: linkedPullRequests.last,
      linkedTicketKey: linkedTicketKey,
      onOpenReview: { reference in
        hubProvider?.showReview(
          owner: reference.owner, repository: reference.repository, number: reference.number)
      },
      onOpenTicket: { key in hubProvider?.showJiraTicket(key) }
    )
  }

  // MARK: - Monitor Content

  @ViewBuilder
  private var monitorContent: some View {
    switch effectiveContentMode {
    case .terminal:
      terminalContent
    case .chat:
      // The terminal stays mounted (invisible) under the chat: a new session only
      // starts once its terminal exists, and the composer types into it.
      ZStack {
        terminalContent
          .environment(\.isTerminalConcealed, true)
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        chatContent
      }
    case .editor:
      editorContent
    case .diffs:
      diffContent
    }
  }

  private var chatContent: some View {
    ChatTranscriptView(
      transcriptPath: session.sessionFilePath,
      providerKind: providerKind,
      reader: hubProvider?.chatTranscriptReader ?? ChatTranscriptReader(),
      onSend: { text in
        guard let viewModel else { return false }
        // Straight to this card's terminal first (also covers a session still
        // starting, whose id is only a placeholder that must not be monitored).
        if viewModel.sendPromptToActiveTerminal(forKey: terminalKey ?? session.id, prompt: text) {
          AppLogger.chat.notice("Chat sent to terminal \(terminalKey ?? session.id, privacy: .public)")
          return true
        }
        AppLogger.chat.notice("Chat terminal not ready for \(terminalKey ?? session.id, privacy: .public)")
        guard !session.id.hasPrefix("pending-") else { return false }
        return viewModel.sendAutomatedPrompt(to: session, prompt: text)
      },
      target: ChatSessionTarget(name: sessionDisplayName, providerKind: providerKind),
      // Only the active card's composer takes the keyboard; typing or focusing
      // the chat of another column makes that column active first.
      isActiveCard: isPrimarySession,
      onInteraction: onTerminalInteraction,
      liveTerminalStatus: liveTerminalStatus,
      terminalNotice: chatTerminalNotice,
      terminalFocusNotice: chatTerminalFocusNotice,
      onShowTerminal: { contentMode = .terminal },
      pendingApproval: state?.pendingToolUse.map { ($0.toolName, $0.input.map(ChatTranscriptReader.firstLine)) },
      onApprove: {
        // The permission menu selects option 1 ("Yes") on its digit key. Always
        // the agent's own tab: an active child tab must never get the parent's approval.
        viewModel?.typeTextInAgentTerminal(forKey: terminalKey ?? session.id, text: "1") ?? false
      }
    )
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var sessionDisplayName: String {
    viewModel?.displayName(for: session) ?? session.displayName
  }

  /// Whether this card reads its agent tab's screen: only the active card, only
  /// while its chat is on screen. One bounded read of a few rows every two
  /// seconds; no file I/O, no other terminals.
  private var liveStatusPollKey: String {
    "\(isPrimarySession)|\(effectiveContentMode == .chat)|\(terminalKey ?? session.id)"
  }

  private func pollLiveTerminalStatus() async {
    guard isPrimarySession, effectiveContentMode == .chat else {
      liveTerminalStatus = nil
      return
    }
    let key = terminalKey ?? session.id
    while !Task.isCancelled {
      let tail = viewModel?.agentTerminalScreenTail(forKey: key, maxRows: Self.liveStatusRows)
      let status = tail.flatMap(TerminalLiveStatusDetector.status(in:))
      if status != liveTerminalStatus { liveTerminalStatus = status }
      try? await Task.sleep(for: .seconds(2))
    }
    liveTerminalStatus = nil
  }

  private static let liveStatusRows = 12

  /// Things the chat can't show: approvals and a launch that hasn't written yet.
  private var chatTerminalNotice: String? {
    if case .awaitingApproval = state?.status {
      return "\(sessionDisplayName) is waiting for your approval in the terminal."
    }
    if session.sessionFilePath == nil {
      return "\(sessionDisplayName) is starting. Its first steps show in the terminal."
    }
    return nil
  }

  /// The terminal under the chat is on a child session tab. The chat does not
  /// follow it; it says so instead, so nothing is read or sent to the wrong agent.
  private var chatTerminalFocusNotice: String? {
    guard
      let linked = viewModel?.terminalWorkspaceSnapshots[terminalKey ?? session.id]?
        .activeLinkedSession
    else { return nil }
    return
      "The terminal is on child session \(linked.sessionId.prefix(8)) (\(linked.provider.rawValue)). This chat stays with \(sessionDisplayName)."
  }

  private var terminalContent: some View {
    MonitoringCardTerminalContent(
      terminalKey: terminalKey ?? session.id,
      sessionId: session.id,
      projectPath: session.projectPath,
      cliConfiguration: liveCLIConfiguration,
      initialPrompt: initialPrompt,
      initialInputText: initialInputText,
      launchContext: launchContext,
      viewModel: viewModel,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      onUserInteraction: onTerminalInteraction,
      onRequestShowEditor: onRequestShowEditor,
      consumeQueuedWebPreviewContextOnSubmit: {
        viewModel?.consumeQueuedWebPreviewContextPrompt(for: session.id)
      }
    )
  }

  private var editorContent: some View {
    FileExplorerView(
      session: session,
      projectPath: editorProjectPath,
      onDismiss: { contentMode = .chat },
      isEmbedded: false,
      selectedFilePath: $selectedEditorFilePath,
      navigationRequest: editorNavigationRequest
    )
    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    .id("editor-\(session.id)")
  }

  private var diffContent: some View {
    GitDiffView(
      session: session,
      projectPath: session.projectPath,
      onDismiss: { contentMode = .chat },
      cliConfiguration: liveCLIConfiguration,
      providerKind: providerKind,
      onInlineRequestSubmit: { prompt, sess in
        contentMode = .terminal
        if let onInlineRequestSubmit {
          onInlineRequestSubmit(prompt, sess)
        } else {
          viewModel?.showTerminalWithPrompt(for: sess, prompt: prompt)
        }
      },
      isEmbedded: false
    )
    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    .id("diffs-\(session.id)")
  }

  private var liveCLIConfiguration: CLICommandConfiguration {
    viewModel?.cliConfiguration(for: providerKind)
      ?? cliConfiguration
      ?? .default(for: providerKind)
  }

}

enum MonitoringCardContentModeItems {
  static func items(
    diffDisplayMode: DiffDisplayMode,
    diffAvailabilityStatus: DiffAvailabilityStatus?
  ) -> [CompactPillSegmentedControlItem<MonitoringCardContentMode>] {
    MonitoringEditorStateStore.availableContentModes(
      diffDisplayMode: diffDisplayMode,
      diffAvailabilityStatus: diffAvailabilityStatus
    ).map { mode in
      CompactPillSegmentedControlItem(
        value: mode,
        title: mode.label,
        helpText: mode.label
      )
    }
  }
}

private struct MonitoringCardPathRow: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let isWorktree: Bool
  let linkedPullRequest: GitHubPullRequestURLReference?
  let linkedTicketKey: String?
  let onOpenReview: (GitHubPullRequestURLReference) -> Void
  let onOpenTicket: (String) -> Void

  var body: some View {
    HStack(spacing: 8) {
      projectPathLabel
        .layoutPriority(1)

      projectPathActionsMenu

      if let linkedTicketKey {
        SessionLinkChip(
          title: linkedTicketKey,
          systemImage: "ticket",
          tint: .indigo,
          help: "Open \(linkedTicketKey) on the Sprint board"
        ) { onOpenTicket(linkedTicketKey) }
      }

      if let linkedPullRequest {
        SessionLinkChip(
          title: "Reviewing PR #\(linkedPullRequest.number) · \(linkedPullRequest.repository)",
          systemImage: "arrow.triangle.pull",
          tint: .blue,
          help: "Show this pull request in Reviews (\(linkedPullRequest.url))"
        ) { onOpenReview(linkedPullRequest) }

        if let branch = session.branchName,
          branch.caseInsensitiveCompare("main") != .orderedSame,
          branch.caseInsensitiveCompare("master") != .orderedSame
        {
          Text(branch)
            .font(.primaryCaption)
            .foregroundStyle(Color.brandPrimary(for: providerKind))
            .lineLimit(1)
            .layoutPriority(1)
        }
      } else if let branch = session.branchName {
        Text(branch)
          .font(.primaryCaption)
          .foregroundStyle(Color.brandPrimary(for: providerKind))
          .lineLimit(1)
          .layoutPriority(1)
      }

      Spacer(minLength: 8)
    }
    .frame(minHeight: 24)
  }

  private var projectPathLabel: some View {
    HStack(spacing: 4) {
      Image(systemName: isWorktree ? "arrow.triangle.branch" : "folder")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(session.projectPath)
        .font(.primaryCaption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var projectPathActionsMenu: some View {
    Menu {
      Section("Open with") {
        ForEach(ProjectPathOpenTarget.allCases) { target in
          Button {
            target.open(path: session.projectPath)
          } label: {
            Text(target.label)
          }
          .disabled(!target.isInstalled)
        }
      }

      Divider()

      Button {
        ProjectPathOpenTarget.copyPath(session.projectPath)
      } label: {
        Label("Copy path", systemImage: "doc.on.doc")
      }
    } label: {
      Image(systemName: "arrow.forward.circle")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
    .help("Open project path menu")
  }
}

private struct MonitoringCardTerminalContent: View {
  let terminalKey: String
  let sessionId: String?
  let projectPath: String
  let cliConfiguration: CLICommandConfiguration
  let initialPrompt: String?
  let initialInputText: String?
  let launchContext: String?
  let viewModel: CLISessionsViewModel?
  let dangerouslySkipPermissions: Bool
  let permissionModePlan: Bool
  let worktreeName: String?
  let onUserInteraction: (() -> Void)?
  let onRequestShowEditor: (() -> Void)?
  let consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?

  var body: some View {
    EmbeddedTerminalView(
      terminalKey: terminalKey,
      sessionId: sessionId,
      projectPath: projectPath,
      cliConfiguration: cliConfiguration,
      initialPrompt: initialPrompt,
      initialInputText: initialInputText,
      launchContext: launchContext,
      viewModel: viewModel,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      onUserInteraction: onUserInteraction,
      onRequestShowEditor: onRequestShowEditor,
      consumeQueuedWebPreviewContextOnSubmit: consumeQueuedWebPreviewContextOnSubmit
    )
    .padding(DesignTokens.Spacing.sm)
    .frame(minHeight: 300)
  }
}

// MARK: - PopoverButton

/// A styled button for use in action popovers
private struct PopoverButton: View {
  let icon: String
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .frame(width: 20)
        Text(title)
        Spacer()
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Animated Copy Button

/// Reusable copy button with animated checkmark confirmation
struct AnimatedCopyButton: View {
  let action: () -> Void
  var size: CGFloat = 24
  var iconFont: Font = .caption
  var showBackground: Bool = true

  @State private var showConfirmation = false

  var body: some View {
    Button {
      action()
      withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
        showConfirmation = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        withAnimation(.easeOut(duration: 0.2)) {
          showConfirmation = false
        }
      }
    } label: {
      Image(systemName: showConfirmation ? "checkmark" : "doc.on.doc")
        .font(iconFont)
        .fontWeight(showConfirmation ? .bold : .regular)
        .foregroundColor(showConfirmation ? .green : .secondary)
        .frame(width: size, height: size)
        .background(showBackground ? Color.secondary.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
    .help("Copy session ID")
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    // Active session with slug
    MonitoringCardView(
      session: CLISession(
        id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
        projectPath: "/Users/james/git/ClaudeCodeUI",
        branchName: "main",
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 42,
        isActive: true,
        slug: "cryptic-orbiting-flame"
      ),
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date(), type: .toolUse(name: "Bash"), description: "swift build")
        ]
      ),
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )

    // Awaiting approval with slug
    MonitoringCardView(
      session: CLISession(
        id: "f2c9bbf3-3b44-5513-b9f6-997d5e5eb481",
        projectPath: "/Users/james/git/MyProject",
        branchName: "feature/auth",
        isWorktree: true,
        lastActivityAt: Date(),
        messageCount: 15,
        isActive: true,
        slug: "async-coalescing-summit"
      ),
      state: SessionMonitorState(
        status: .awaitingApproval(tool: "git"),
        lastActivityAt: Date(),
        model: "claude-sonnet-4-20250514",
        recentActivities: []
      ),
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )

    // Loading state (no slug - shows only session ID)
    MonitoringCardView(
      session: CLISession(
        id: "a3d0ccg4-4c55-6624-c0g7-aa8e6f6fc592",
        projectPath: "/Users/james/Desktop",
        branchName: nil,
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 5,
        isActive: false
      ),
      state: nil,
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )
  }
  .padding()
  .frame(width: 320)
}

// MARK: - SessionLinkChip

/// Clickable chip in the session path row that jumps to the linked review or ticket.
private struct SessionLinkChip: View {
  let title: String
  let systemImage: String
  let tint: Color
  let help: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: systemImage)
          .font(.system(size: 9, weight: .semibold))
        Text(title)
          .font(.primaryCaption)
          .lineLimit(1)
        Image(systemName: "arrow.up.forward")
          .font(.system(size: 8, weight: .bold))
          .opacity(isHovered ? 1 : 0.5)
      }
      .foregroundStyle(tint)
      .padding(.horizontal, 7)
      .frame(height: 18)
      .background(Capsule().fill(tint.opacity(isHovered ? 0.2 : 0.12)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(help)
    .layoutPriority(1)
  }
}
