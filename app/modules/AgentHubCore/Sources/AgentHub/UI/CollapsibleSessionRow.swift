import AgentHubGitHub
import SwiftUI

struct SessionSidebarPresentation: Equatable {
  let title: String
  let context: String
  let linkedPullRequest: GitHubPullRequestURLReference?

  init(
    session: CLISession,
    customName: String?,
    linkedPullRequests: [GitHubPullRequestURLReference]
  ) {
    let cleanedCustomName = Self.cleaned(customName)
    let branch = Self.cleaned(session.branchName)
    let meaningfulBranch = branch.flatMap { Self.isDefaultBranch($0) ? nil : $0 }
    let pullRequest = linkedPullRequests.last
    linkedPullRequest = pullRequest

    if let cleanedCustomName {
      title = cleanedCustomName
    } else if let pullRequest {
      title = "PR #\(pullRequest.number)"
    } else if let meaningfulBranch {
      title = meaningfulBranch
    } else if let slug = Self.cleaned(session.slug) {
      title = slug
    } else if !session.projectName.isEmpty {
      title = "\(session.projectName) · \(session.shortId)"
    } else {
      title = session.shortId
    }

    var contextParts: [String] = []
    if let pullRequest {
      contextParts.append("Reviewing PR #\(pullRequest.number)")
      contextParts.append("\(pullRequest.owner)/\(pullRequest.repository)")
    } else if !session.projectName.isEmpty {
      contextParts.append(session.projectName)
    }
    if let displayBranch = pullRequest == nil ? branch : meaningfulBranch,
      displayBranch.localizedCaseInsensitiveCompare(title) != .orderedSame
    {
      contextParts.append(displayBranch)
    }
    context = contextParts.joined(separator: " · ")
  }

  private static func cleaned(_ value: String?) -> String? {
    let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func isDefaultBranch(_ branch: String) -> Bool {
    branch.caseInsensitiveCompare("main") == .orderedSame
      || branch.caseInsensitiveCompare("master") == .orderedSame
  }
}

// MARK: - CollapsibleSessionRow

struct CollapsibleSessionRow: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let timestamp: Date
  let isPending: Bool
  let isPrimary: Bool
  let customName: String?
  let sessionStatus: SessionStatus?
  var linkedPullRequests: [GitHubPullRequestURLReference] = []
  let colorScheme: ColorScheme
  let isPinned: Bool
  let onPin: (() -> Void)?
  let onArchive: (() -> Void)?
  let onSelect: () -> Void

  private static let statusLabelMaxWidth: CGFloat = 124

  @State private var pulseScale: CGFloat = 1.0
  @State private var isPulseAnimating = false
  @State private var sessionGitHubQuickAccessViewModel = SessionGitHubQuickAccessViewModel()
  @Environment(\.agentHub) private var agentHub
  @Environment(\.appVisibility) private var appVisibility

  // MARK: - Computed

  private var presentation: SessionSidebarPresentation {
    SessionSidebarPresentation(
      session: session,
      customName: customName,
      linkedPullRequests: linkedPullRequests
    )
  }

  private var statusColor: Color {
    if attention != nil { return .orange }
    guard let sessionStatus else { return .secondary }
    switch sessionStatus {
    case .thinking: return .blue
    case .executingTool: return .orange
    case .waitingForUser: return .green
    case .awaitingApproval: return .orange
    case .idle: return .secondary
    }
  }

  private var attention: SidebarSessionAttention? {
    SidebarSessionAttention(status: sessionStatus)
  }

  private var isActiveStatus: Bool {
    guard let sessionStatus else { return false }
    switch sessionStatus {
    case .thinking, .executingTool: return true
    default: return false
    }
  }

  /// A `repeatForever` animation keeps the SwiftUI display link — and the
  /// per-frame CoreAnimation commit — alive for as long as it runs, so it stops
  /// while the app is occluded. There is always at least one active session in
  /// a working hub, which is exactly when this would otherwise never idle.
  private var shouldPulse: Bool {
    StatusPulsePolicy.shouldPulse(
      isActiveStatus: isActiveStatus,
      isAppVisible: appVisibility?.isVisible ?? true
    )
  }

  private func statusDisplayText(_ status: SessionStatus) -> String {
    switch status {
    case .thinking: return "working"
    case .executingTool(let name): return name.lowercased()
    case .waitingForUser: return "ready"
    case .awaitingApproval(let tool):
      return SessionInteractiveInputTool.matches(tool) ? "Input needed" : "Approval needed"
    case .idle: return "idle"
    }
  }

  private var gitHubObservationTaskID: String {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: session.projectPath,
      branchName: session.branchName,
      linkedPullRequests: linkedPullRequests
    )
    return "\(repositoryKey)|\(isPending)|\(agentHub != nil)"
  }

  private var observationStartupDelayMilliseconds: Int {
    let bucket = session.id.unicodeScalars.reduce(0) { partialResult, scalar in
      (partialResult + Int(scalar.value)) % 1_500
    }
    return 250 + bucket
  }

  // MARK: - Body

  @State private var isRowHovered = false

  var body: some View {
    HStack(spacing: 8) {
      statusIndicator

      // Content
      VStack(alignment: .leading, spacing: 2) {
        // Row 1: the human work item, not the repeated launch prompt.
        HStack(spacing: 4) {
          Text(presentation.title)
            .font(.secondaryDefault)
            .foregroundColor(.primary)
            .lineLimit(1)
            .layoutPriority(1)

          Spacer(minLength: 4)

          if let onArchive, !isPending {
            SessionRowArchiveButton(isVisible: isRowHovered, action: onArchive)
          }
        }

        // Row 2: repository, pull request and branch context, followed by live state.
        HStack(spacing: 6) {
          if !presentation.context.isEmpty {
            if presentation.linkedPullRequest != nil {
              Label(presentation.context, systemImage: "arrow.triangle.pull")
                .font(.secondarySmall)
                .foregroundColor(.blue.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(presentation.context)
            } else {
              Text(presentation.context)
                .font(.secondarySmall)
                .foregroundColor(.secondary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            }
          }

          Spacer(minLength: 4)

          Text(providerKind.rawValue)
            .font(.secondaryCaption)
            .foregroundColor(isPrimary ? .white : .brandPrimary(for: providerKind).opacity(0.8))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

          statusLabel
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.statusLabelMaxWidth, alignment: .trailing)
            .animation(.easeInOut(duration: 0.3), value: isPending)
            .animation(.easeInOut(duration: 0.3), value: sessionStatus)

          Text(timestamp.timeAgoDisplay())
            .font(.secondaryCaption)
            .foregroundColor(.secondary.opacity(0.7))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        SessionWorkflowAssociationBadge(
          session: session,
          providerKind: providerKind
        )

        if let pullRequest = sessionGitHubQuickAccessViewModel.currentBranchPR {
          GitHubSessionRowStatusLine(
            pullRequest: pullRequest,
            summary: sessionGitHubQuickAccessViewModel.ciSummary,
            observationState: sessionGitHubQuickAccessViewModel.observationState,
            lastRefreshedAt: sessionGitHubQuickAccessViewModel.lastRefreshedAt
          )
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) { isRowHovered = hovering }
    }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(rowBackground)
        .animation(.easeInOut(duration: 0.3), value: isPending)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(
          attention == nil ? Color.clear : Color.orange.opacity(colorScheme == .dark ? 0.42 : 0.32),
          lineWidth: 1
        )
    }
    .onAppear { startPulseAnimation() }
    .onChange(of: sessionStatus) { _, _ in startPulseAnimation() }
    .onChange(of: isPending) { _, _ in startPulseAnimation() }
    .onChange(of: appVisibility?.isVisible ?? true) { _, _ in startPulseAnimation() }
    .task(id: gitHubObservationTaskID) {
      await observeGitHubIfAvailable()
    }
    .onDisappear {
      sessionGitHubQuickAccessViewModel.stopPolling()
    }
    .onChange(of: timestamp) { _, newValue in
      Task {
        await sessionGitHubQuickAccessViewModel.notifySessionActivity(at: newValue)
      }
    }
    .sessionManagementActions(
      session: session,
      providerKind: providerKind,
      customName: customName,
      isPending: isPending,
      isPinned: isPinned,
      onPin: onPin,
      onArchive: onArchive
    )
  }

  @ViewBuilder
  private var statusLabel: some View {
    if let attention {
      Label(attention.displayName, systemImage: attention.systemImage)
        .font(.secondaryCaption)
        .foregroundColor(statusColor)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .id("attention-\(attention.rawValue)")
        .accessibilityLabel(attention.displayName)
    } else if let sessionStatus {
      Text(statusDisplayText(sessionStatus))
        .font(.secondaryCaption)
        .foregroundColor(statusColor)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .id("status-\(statusDisplayText(sessionStatus))")
    } else if isPending {
      Text("starting")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .id("status-pending")
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var statusIndicator: some View {
    if let attention {
      Image(systemName: attention.systemImage)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(statusColor)
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    } else {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .scaleEffect(shouldPulse ? pulseScale : 1.0)
        .animation(.easeInOut(duration: 0.35), value: statusColor)
        .accessibilityHidden(true)
    }
  }

  private var rowBackground: Color {
    if isPrimary {
      return Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.2 : 0.75)
    }
    if attention != nil {
      return Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.07)
    }
    return .clear
  }

  // MARK: - Animations

  private func startPulseAnimation() {
    guard shouldPulse else {
      guard isPulseAnimating else { return }
      isPulseAnimating = false
      withAnimation(.easeOut(duration: 0.2)) {
        pulseScale = 1.0
      }
      return
    }

    guard !isPulseAnimating else { return }
    isPulseAnimating = true
    pulseScale = 1.0

    withAnimation(
      .easeInOut(duration: 1.0)
        .repeatForever(autoreverses: true)
    ) {
      pulseScale = 1.4
    }
  }

  private func observeGitHubIfAvailable() async {
    guard !isPending, let observationService = agentHub?.gitHubPRObservationService else {
      sessionGitHubQuickAccessViewModel.stopPolling()
      return
    }

    if linkedPullRequests.isEmpty {
      try? await Task.sleep(for: .milliseconds(observationStartupDelayMilliseconds))
      guard !Task.isCancelled else { return }
    }

    if let notifier = agentHub?.gitHubCIFailureNotifier {
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
      observationService: observationService,
      refreshOnSubscribe: false,
      recordInitialActivity: false,
      forceRefreshLinkedPullRequest: !linkedPullRequests.isEmpty
    )
    await sessionGitHubQuickAccessViewModel.notifySessionActivity(at: timestamp)
  }
}


// MARK: - Preview

#Preview("CollapsibleSessionRow — Flat Design") {
  let sessions = [
    CLISession(
      id: "abc12345-6789-0def-ghij-klmnopqrstuv",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "feature/multi-session",
      lastActivityAt: Date(),
      messageCount: 12,
      isActive: true,
      firstMessage: "Help me refactor the authentication module to use async/await patterns",
      slug: "cryptic-orbiting-flame"
    ),
    CLISession(
      id: "def98765-4321-0abc-wxyz-abcdefghijkl",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "main",
      lastActivityAt: Date().addingTimeInterval(-3600),
      messageCount: 5,
      isActive: true,
      firstMessage: "Write unit tests for the session manager",
      slug: "bright-wandering-star"
    ),
    CLISession(
      id: "fff11111-2222-3333-4444-555566667777",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "fix/login-bug",
      lastActivityAt: Date().addingTimeInterval(-86400),
      messageCount: 0,
      isActive: false,
      slug: "silent-morning-dew"
    ),
    CLISession(
      id: "aaa22222-3333-4444-5555-666677778888",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "refactor/db-layer",
      lastActivityAt: Date().addingTimeInterval(-7200),
      messageCount: 8,
      isActive: true,
      firstMessage: "Migrate the persistence layer from CoreData to GRDB",
      slug: nil
    ),
  ]

  let statuses: [(SessionStatus?, Bool, Bool)] = [
    (.thinking, false, true),
    (.executingTool(name: "Bash"), false, false),
    (.idle, false, false),
    (.waitingForUser, false, true),
    (.awaitingApproval(tool: "Edit"), false, false),
    (nil, true, false),
  ]

  ScrollView {
    VStack(alignment: .leading, spacing: 24) {

      // --- All states ---
      sectionHeader("All States")
      VStack(spacing: 1) {
        ForEach(Array(statuses.enumerated()), id: \.offset) { idx, state in
          let s = sessions[idx % sessions.count]
          CollapsibleSessionRow(
            session: s,
            providerKind: idx % 2 == 0 ? .claude : .codex,
            timestamp: s.lastActivityAt,
            isPending: state.1,
            isPrimary: state.2,
            customName: idx == 3 ? "Auth Refactor" : nil,
            sessionStatus: state.0,
            colorScheme: .dark,
            isPinned: idx == 0,
            onPin: {},
            onArchive: state.1 ? nil : {}, onSelect: {}
          )
        }
      }

      Divider().padding(.vertical, 4)

      // --- List feel ---
      sectionHeader("List — multiple sessions")
      VStack(spacing: 1) {
        ForEach(Array(sessions.enumerated()), id: \.1.id) { idx, s in
          CollapsibleSessionRow(
            session: s,
            providerKind: idx < 2 ? .claude : .codex,
            timestamp: s.lastActivityAt,
            isPending: false,
            isPrimary: idx == 0,
            customName: nil,
            sessionStatus: idx == 0 ? .thinking : (idx == 1 ? .executingTool(name: "Read") : .idle),
            colorScheme: .dark,
            isPinned: false,
            onPin: {},
            onArchive: {}, onSelect: {}
          )
        }
      }

      Divider().padding(.vertical, 4)

      // --- Light mode ---
      sectionHeader("Light Mode")
      VStack(spacing: 1) {
        CollapsibleSessionRow(
          session: sessions[0],
          providerKind: .claude,
          timestamp: Date(),
          isPending: false,
          isPrimary: true,
          customName: nil,
          sessionStatus: .thinking,
          colorScheme: .light,
          isPinned: false,
          onPin: {},
          onArchive: {}, onSelect: {}
        )
        .environment(\.colorScheme, .light)

        CollapsibleSessionRow(
          session: sessions[1],
          providerKind: .claude,
          timestamp: Date().addingTimeInterval(-3600),
          isPending: false,
          isPrimary: false,
          customName: nil,
          sessionStatus: .idle,
          colorScheme: .light,
          isPinned: false,
          onPin: {},
          onArchive: {}, onSelect: {}
        )
        .environment(\.colorScheme, .light)

        CollapsibleSessionRow(
          session: sessions[2],
          providerKind: .codex,
          timestamp: Date().addingTimeInterval(-86400),
          isPending: false,
          isPrimary: false,
          customName: nil,
          sessionStatus: .waitingForUser,
          colorScheme: .light,
          isPinned: false,
          onPin: {},
          onArchive: {}, onSelect: {}
        )
        .environment(\.colorScheme, .light)
      }
      .background(Color(white: 0.96))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .padding()
  }
  .frame(width: 340, height: 800)
  .background(Color(nsColor: .windowBackgroundColor))
  .preferredColorScheme(.dark)
}

@ViewBuilder
private func sectionHeader(_ title: String) -> some View {
  Text(title)
    .font(.secondaryCaption)
    .foregroundColor(.secondary)
    .textCase(.uppercase)
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - SessionRowArchiveButton

/// Hover-only archive action on a sidebar session row. Kept in the layout (just
/// transparent) when hidden so the title doesn't shift as the pointer moves.
private struct SessionRowArchiveButton: View {
  let isVisible: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "archivebox")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isHovered ? .primary : .secondary)
        .frame(width: 20, height: 18)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.12 : 0))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .onHover { isHovered = $0 }
    .help("Archive session")
    .accessibilityLabel("Archive session")
  }
}
