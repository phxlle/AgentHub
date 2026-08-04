//
//  GitHubReviewsView.swift
//  AgentHub
//

import AgentHubGitHub
import SwiftUI

struct GitHubReviewsView: View {
  @Bindable private var viewModel: GitHubReviewsViewModel
  @Bindable private var claudeSessionsViewModel: CLISessionsViewModel
  @Bindable private var codexSessionsViewModel: CLISessionsViewModel
  private let onReview: (GitHubProjectPullRequest, SessionProviderKind) -> Void
  private let onOpenSession: (GitHubReviewSessionLink) -> Void

  init(
    viewModel: GitHubReviewsViewModel,
    claudeSessionsViewModel: CLISessionsViewModel,
    codexSessionsViewModel: CLISessionsViewModel,
    onReview: @escaping (GitHubProjectPullRequest, SessionProviderKind) -> Void,
    onOpenSession: @escaping (GitHubReviewSessionLink) -> Void
  ) {
    self.viewModel = viewModel
    self.claudeSessionsViewModel = claudeSessionsViewModel
    self.codexSessionsViewModel = codexSessionsViewModel
    self.onReview = onReview
    self.onOpenSession = onOpenSession
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .task {
      await viewModel.load()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.md) {
        VStack(alignment: .leading, spacing: 2) {
          Text("PULL REQUEST REVIEWS")
            .font(.geist(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Text("Driven by a saved GitHub Project view")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if viewModel.isLoadingProjects || viewModel.isLoadingPullRequests {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          Task { await viewModel.reloadProjects() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingProjects || viewModel.isLoadingPullRequests)
        .help("Reload GitHub Projects and pull requests")
        .accessibilityLabel("Reload GitHub review queue")
      }

      HStack(spacing: DesignTokens.Spacing.sm) {
        Picker("Project", selection: projectBinding) {
          if viewModel.projects.isEmpty {
            Text("No projects available").tag(String?.none)
          } else {
            ForEach(viewModel.projects) { project in
              Text(project.displayName).tag(Optional(project.id))
            }
          }
        }
        .frame(minWidth: 230, idealWidth: 300)

        Picker("View", selection: viewBinding) {
          if viewModel.availableViews.isEmpty {
            Text("No views available").tag(String?.none)
          } else {
            ForEach(viewModel.availableViews) { view in
              Text(view.name).tag(Optional(view.id))
            }
          }
        }
        .frame(minWidth: 170, idealWidth: 220)

        if let project = viewModel.selectedProject,
          let url = URL(string: project.url)
        {
          Link(destination: url) {
            Label("Open project", systemImage: "arrow.up.right.square")
          }
          .buttonStyle(.borderless)
        }

        Spacer()

        Text("\(viewModel.pullRequests.count) pull requests")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }

      if !viewModel.activeFilter.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
          Text("FILTER")
            .font(.geist(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
          Text(viewModel.activeFilter)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
          Spacer()
        }
      }

      if let errorMessage = viewModel.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.secondaryCaption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(DesignTokens.Spacing.md)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoadingProjects, viewModel.projects.isEmpty {
      ContentUnavailableView {
        Label("Loading GitHub Projects", systemImage: "rectangle.3.group")
      } description: {
        Text("Reading projects and saved views through your GitHub CLI login.")
      }
    } else if viewModel.selectedProject == nil {
      ContentUnavailableView {
        Label("No GitHub Projects found", systemImage: "rectangle.3.group")
      } description: {
        Text("Make sure `gh` is authenticated with the `project` scope.")
      }
    } else if viewModel.selectedView == nil {
      ContentUnavailableView {
        Label("No project view selected", systemImage: "line.3.horizontal.decrease.circle")
      } description: {
        Text("Choose a saved view whose filter describes the review queue.")
      }
    } else if viewModel.isLoadingPullRequests, viewModel.pullRequests.isEmpty {
      ContentUnavailableView {
        Label("Loading review queue", systemImage: "arrow.triangle.pull")
      } description: {
        Text("Applying the selected project view filter.")
      }
    } else if viewModel.pullRequests.isEmpty {
      ContentUnavailableView(
        "No pull requests to review",
        systemImage: "checkmark.circle",
        description: Text("The selected GitHub Project view contains no matching non-draft PRs.")
      )
    } else {
      pullRequestTable
    }
  }

  private var pullRequestTable: some View {
    let inventories = reviewSessionInventories

    return Table(viewModel.pullRequests) {
      TableColumn("Pull request") { pullRequest in
        VStack(alignment: .leading, spacing: 2) {
          Link(pullRequest.title, destination: URL(string: pullRequest.url)!)
            .font(.primaryDefault)
            .lineLimit(2)
          Text("#\(pullRequest.number)")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
      }
      .width(min: 320, ideal: 520)

      TableColumn("Repository") { pullRequest in
        Text(pullRequest.repositoryNameWithOwner)
          .font(.secondaryDefault)
          .lineLimit(1)
      }
      .width(min: 190, ideal: 240)

      TableColumn("Author") { pullRequest in
        Text(pullRequest.authorLogin.map { "@\($0)" } ?? "Unknown")
          .font(.secondaryDefault)
          .foregroundStyle(.secondary)
      }
      .width(min: 100, ideal: 140)

      TableColumn("Updated") { pullRequest in
        if let updatedAt = pullRequest.updatedAt {
          Text(updatedAt, style: .relative)
            .font(.secondaryDefault)
            .foregroundStyle(.secondary)
        } else {
          Text("Unknown")
            .font(.secondaryDefault)
            .foregroundStyle(.secondary)
        }
      }
      .width(min: 80, ideal: 110)

      TableColumn("Session") { pullRequest in
        let links = GitHubReviewSessionLinker.links(
          for: pullRequest,
          launches: viewModel.reviewSessionLaunches(for: pullRequest),
          inventories: inventories
        )
        reviewSessionsCell(links)
      }
      .width(min: 190, ideal: 240)

      TableColumn("Review") { pullRequest in
        HStack(spacing: DesignTokens.Spacing.xs) {
          Button("Codex") {
            onReview(pullRequest, .codex)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Start a read-only Codex review")

          Button("Claude") {
            onReview(pullRequest, .claude)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Start a read-only Claude review")
        }
      }
      .width(min: 145, ideal: 160)
    }
  }

  @ViewBuilder
  private func reviewSessionsCell(_ links: [GitHubReviewSessionLink]) -> some View {
    if links.isEmpty {
      Text("No linked session")
        .font(.secondaryCaption)
        .foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        ForEach(links) { link in
          Button {
            onOpenSession(link)
          } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
              Image(systemName: link.isPending ? "hourglass" : "terminal")
                .foregroundStyle(link.isPending ? .secondary : .primary)

              VStack(alignment: .leading, spacing: 1) {
                Text("\(link.provider.rawValue) · \(link.displayName)")
                  .font(.secondaryDefault)
                  .lineLimit(1)
                HStack(spacing: 3) {
                  Text(link.statusText)
                  Text("·")
                  Text(link.session.lastActivityAt, style: .relative)
                }
                .font(.secondaryCaption)
                .foregroundStyle(.secondary)
              }

              Spacer(minLength: 2)

              Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Open \(link.provider.rawValue) session \(link.displayName)")
          .accessibilityLabel(
            "Open \(link.provider.rawValue) session \(link.displayName), \(link.statusText)"
          )
        }
      }
      .padding(.vertical, DesignTokens.Spacing.xs)
    }
  }

  private var reviewSessionInventories: [GitHubReviewSessionInventory] {
    [
      GitHubReviewSessionInventory(
        provider: .claude,
        sessions: claudeSessionsViewModel.allSessions,
        pendingSessions: claudeSessionsViewModel.pendingHubSessions,
        resolvedPendingSessionIDs: claudeSessionsViewModel.resolvedPendingSessionHistory,
        customNames: claudeSessionsViewModel.sessionCustomNames,
        statuses: claudeSessionsViewModel.sessionStatuses
      ),
      GitHubReviewSessionInventory(
        provider: .codex,
        sessions: codexSessionsViewModel.allSessions,
        pendingSessions: codexSessionsViewModel.pendingHubSessions,
        resolvedPendingSessionIDs: codexSessionsViewModel.resolvedPendingSessionHistory,
        customNames: codexSessionsViewModel.sessionCustomNames,
        statuses: codexSessionsViewModel.sessionStatuses
      ),
    ]
  }

  private var projectBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedProjectID },
      set: { id in
        if let id { viewModel.selectProject(id: id) }
      }
    )
  }

  private var viewBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedViewID },
      set: { id in
        if let id { viewModel.selectView(id: id) }
      }
    )
  }
}
