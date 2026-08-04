//
//  AgentHubViews.swift
//  AgentHub
//
//  Pre-configured view components for AgentHub
//

import AgentHubGitHub
import SwiftUI

// MARK: - RemoveTitleToolbarModifier

/// A view modifier that removes the toolbar title on macOS 15+
private struct RemoveTitleToolbarModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.toolbar(removing: .title)
    } else {
      content
    }
  }
}

// MARK: - AgentHubOperationsView

/// The application-level workspace for structured ticket workflows and raw sessions.
public struct AgentHubOperationsView: View {
  private enum Section: String, CaseIterable, Identifiable {
    case workflows = "Workflows"
    case reviews = "Reviews"
    case sessions = "Sessions"

    var id: Self { self }
  }

  @Environment(\.agentHub) private var agentHub
  @State private var section = Section.workflows

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Workspace", selection: $section) {
          ForEach(Section.allCases) { section in
            Text(section.rawValue).tag(section)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 320)
        .accessibilityLabel("AgentHub workspace")

        Spacer()

        if section == .workflows {
          Label(
            "Workflow policy: approval before commit, push, or pull request",
            systemImage: "hand.raised"
          )
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: AgentHubLayout.topBarHeight)

      Divider()

      Group {
        switch section {
        case .workflows:
          if let agentHub {
            AgentWorkflowDashboardView(
              viewModel: agentHub.workflowDashboardViewModel,
              onOpenSession: { assignment in
                agentHub.globalSessionSelectionRouter.select(
                  providerKind: assignment.provider,
                  sessionId: assignment.session.id,
                  projectPath: assignment.session.projectPath
                )
                section = .sessions
              },
              onCloseSession: { assignment in
                let sessionsViewModel =
                  assignment.provider == .claude
                  ? agentHub.claudeSessionsViewModel
                  : agentHub.codexSessionsViewModel
                sessionsViewModel.stopMonitoring(session: assignment.session)
              },
              onStartSession: { workflowID, provider in
                startSession(
                  in: workflowID,
                  provider: provider,
                  agentHub: agentHub
                )
              }
            )
          } else {
            ContentUnavailableView(
              "AgentHub provider not found",
              systemImage: "exclamationmark.triangle"
            )
          }
        case .reviews:
          if let agentHub {
            GitHubReviewsView(
              viewModel: agentHub.gitHubReviewsViewModel,
              onReview: { pullRequest, provider in
                startReview(
                  pullRequest,
                  provider: provider,
                  agentHub: agentHub
                )
              }
            )
          } else {
            ContentUnavailableView(
              "AgentHub provider not found",
              systemImage: "exclamationmark.triangle"
            )
          }
        case .sessions:
          AgentHubSessionsView()
        }
      }
    }
    .frame(minWidth: 1200, minHeight: 750)
    .modifier(RemoveTitleToolbarModifier())
  }

  private func startSession(
    in workflowID: String,
    provider: SessionProviderKind,
    agentHub: AgentHubProvider
  ) {
    guard
      let workflow = agentHub.workflowDashboardViewModel.prepareManualSessionLaunch(
        workflowID: workflowID,
        provider: provider
      )
    else {
      return
    }

    let sessionsViewModel =
      provider == .claude
      ? agentHub.claudeSessionsViewModel
      : agentHub.codexSessionsViewModel
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(workflow.repositoryPath)
    let existingWorktree = sessionsViewModel.selectedRepositories
      .flatMap(\.worktrees)
      .first {
        WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalizedPath
      }
    let launchTarget =
      existingWorktree
      ?? WorktreeBranch(
        name: workflow.branchName
          ?? URL(fileURLWithPath: normalizedPath).lastPathComponent,
        path: normalizedPath,
        isWorktree: workflow.branchName != nil
      )

    sessionsViewModel.addRepository(at: normalizedPath)
    sessionsViewModel.startNewSessionInHub(
      launchTarget,
      initialPrompt: "Work on \(workflow.name)."
    )
    if let pendingSessionID = sessionsViewModel.lastCreatedPendingId {
      agentHub.workflowDashboardViewModel.associateManualSessionLaunch(
        workflowID: workflowID,
        provider: provider,
        pendingSessionID: pendingSessionID
      )
    }
    section = .sessions
  }

  private func startReview(
    _ pullRequest: GitHubProjectPullRequest,
    provider: SessionProviderKind,
    agentHub: AgentHubProvider
  ) {
    guard let project = agentHub.gitHubReviewsViewModel.selectedProject,
      let view = agentHub.gitHubReviewsViewModel.selectedView
    else { return }

    let repositories = WorktreeModuleResolver.mergedRepositories(
      agentHub.claudeSessionsViewModel.selectedRepositories
        + agentHub.codexSessionsViewModel.selectedRepositories
    )
    guard
      let repositoryPath = localRepositoryPath(
        named: pullRequest.repositoryName,
        repositories: repositories
      )
    else {
      agentHub.gitHubReviewsViewModel.presentLaunchError(
        "No local checkout found for \(pullRequest.repositoryNameWithOwner). Add that repository in Sessions first."
      )
      return
    }

    let sessionsViewModel =
      provider == .claude
      ? agentHub.claudeSessionsViewModel
      : agentHub.codexSessionsViewModel
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    let target = WorktreeBranch(
      name: pullRequest.repositoryName,
      path: normalizedPath,
      isWorktree: false,
      isExpanded: true
    )
    let prompt = GitHubProjectReviewPromptBuilder.prompt(
      pullRequest: pullRequest,
      project: project,
      view: view
    )

    sessionsViewModel.addRepository(at: normalizedPath)
    guard sessionsViewModel.startAutomatedSessionInHub(target, initialPrompt: prompt) != nil else {
      agentHub.gitHubReviewsViewModel.presentLaunchError(
        "Could not start the \(provider.rawValue) review session."
      )
      return
    }
    section = .sessions
  }

  private func localRepositoryPath(
    named repositoryName: String,
    repositories: [SelectedRepository]
  ) -> String? {
    if let repository = repositories.first(where: {
      $0.name.localizedCaseInsensitiveCompare(repositoryName) == .orderedSame
        || URL(fileURLWithPath: $0.path).lastPathComponent
          .localizedCaseInsensitiveCompare(repositoryName) == .orderedSame
    }) {
      return repository.path
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/LocalDocuments/Github/\(repositoryName)",
      "\(home)/Documents/GitHub/\(repositoryName)",
      "\(home)/Developer/\(repositoryName)",
      "\(home)/Projects/\(repositoryName)",
    ]
    return candidates.first { candidate in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
        && isDirectory.boolValue
        && FileManager.default.fileExists(atPath: "\(candidate)/.git")
    }
  }
}

// MARK: - AgentHubSessionsView

/// Pre-configured sessions view that reads from the environment
///
/// This view automatically gets its dependencies from the AgentHub provider
/// in the environment. Make sure to apply `.agentHub()` modifier to a parent view.
///
/// ## Example
/// ```swift
/// WindowGroup {
///   AgentHubSessionsView()
///     .agentHub(provider)
/// }
/// ```
public struct AgentHubSessionsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  public init() {}

  public var body: some View {
    if let provider = agentHub {
      sessionsListView(provider: provider)
    } else {
      missingProviderView
    }
  }

  @ViewBuilder
  private func sessionsListView(provider: AgentHubProvider) -> some View {
    MultiProviderSessionsListView(
      claudeViewModel: provider.claudeSessionsViewModel,
      codexViewModel: provider.codexSessionsViewModel,
      workspaceViewModel: provider.agentWorkspacesViewModel,
      columnVisibility: $columnVisibility,
      intelligenceViewModel: provider.intelligenceViewModel,
      worktreeBranchNamingService: provider.worktreeBranchNamingService,
      worktreeSuccessSoundService: provider.worktreeSuccessSoundService
    )
    .frame(minWidth: 1200, minHeight: 750)
    .modifier(RemoveTitleToolbarModifier())
    .task {
      provider.startWorktreeLaunchRequestMonitoring()
    }
  }

  private var missingProviderView: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("AgentHub provider not found")
        .font(.headline)
      Text("Add .agentHub() modifier to a parent view")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - AgentHubMenuBarContent

/// Pre-configured menu bar content for MenuBarExtra
///
/// Use this as the content of a MenuBarExtra to show global stats.
///
/// ## Example
/// ```swift
/// MenuBarExtra("Stats", systemImage: "sparkle") {
///   AgentHubMenuBarContent()
///     .environment(\.agentHub, provider)
/// }
/// ```
public struct AgentHubMenuBarContent: View {
  @Environment(\.agentHub) private var agentHub

  public init() {}

  public var body: some View {
    if let provider = agentHub {
      GlobalStatsMenuView(
        claudeService: provider.statsService,
        codexService: provider.codexStatsService,
        sessionsViewModel: provider.sessionsViewModel
      )
    } else {
      Text("AgentHub provider not found")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - AgentHubMenuBarLabel

/// Pre-configured label for MenuBarExtra
///
/// Shows an icon with token count in the menu bar.
///
/// ## Example
/// ```swift
/// @State private var provider = AgentHubProvider()
///
/// MenuBarExtra {
///   AgentHubMenuBarContent()
///     .environment(\.agentHub, provider)
/// } label: {
///   AgentHubMenuBarLabel(provider: provider)
/// }
/// ```
public struct AgentHubMenuBarLabel: View {
  let provider: AgentHubProvider

  public init(provider: AgentHubProvider) {
    self.provider = provider
  }

  public var body: some View {
    Image("AgentHubMenuBarIcon", bundle: .main)
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: 18, height: 18)
  }
}
