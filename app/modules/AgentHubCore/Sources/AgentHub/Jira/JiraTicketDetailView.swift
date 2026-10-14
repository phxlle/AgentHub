//
//  JiraTicketDetailView.swift
//  AgentHub
//
//  Inspector panel for one ticket: details, description, and handing it to an agent.
//

import AgentHubGitHub
import AgentWorkflowJiraCLI
import AppKit
import SwiftUI

struct JiraTicketDetailView: View {
  let ticket: JiraTicketSnapshot
  let sprintName: String?
  let isLoadingDetail: Bool
  let browseURL: URL?
  @Binding var repositoryPath: String?
  let repositories: [SelectedRepository]
  let linkedSessions: [JiraLinkedSession]
  let pullRequests: [GitHubProjectPullRequest]?
  let isLoadingPullRequests: Bool
  let onRefreshPullRequests: () -> Void
  let onStart: (SessionProviderKind) -> Void
  let onOpenSession: (JiraLinkedSession) -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
          titleBlock
          JiraTicketFields(ticket: ticket, sprintName: sprintName)
          if !linkedSessions.isEmpty {
            JiraLinkedSessionsSection(sessions: linkedSessions, onOpen: onOpenSession)
          }
          JiraPullRequestsSection(
            ticketKey: ticket.key,
            pullRequests: pullRequests,
            isLoading: isLoadingPullRequests,
            onRefresh: onRefreshPullRequests
          )
          JiraPickUpCard(
            repositoryPath: $repositoryPath,
            repositories: repositories,
            onStart: onStart
          )
          descriptionBlock
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      JiraIssueTypeIcon(issueType: ticket.issueType, size: 13)
      Text(ticket.key)
        .font(.jetBrainsMono(size: 12, weight: .semibold))
        .textSelection(.enabled)
      Spacer()
      if let browseURL {
        Button {
          NSWorkspace.shared.open(browseURL)
        } label: {
          Label("Open in Jira", systemImage: "arrow.up.right.square")
            .font(.secondaryDefault)
        }
        .buttonStyle(.borderless)
      }
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(.cancelAction)
      .help("Close")
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .frame(height: 44)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text(ticket.summary)
        .font(.geist(size: 18, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if let status = ticket.status {
        JiraStatusPill(status: status, category: ticket.statusCategory)
      }
    }
  }

  private var descriptionBlock: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Description")
        .font(.heading)
      if let description = ticket.description, !description.isEmpty {
        Text(description)
          .font(.geist(size: 13))
          .lineSpacing(4)
          .foregroundStyle(.primary.opacity(0.9))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } else if isLoadingDetail {
        ProgressView().controlSize(.small)
      } else {
        Text("No description")
          .font(.secondaryDefault)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

// MARK: - JiraTicketFields

private struct JiraTicketFields: View {
  let ticket: JiraTicketSnapshot
  let sprintName: String?

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.lg, verticalSpacing: 10) {
      row("Assignee") {
        HStack(spacing: 6) {
          JiraAvatar(
            name: ticket.assignee,
            url: ticket.assigneeAvatarURL.flatMap(URL.init(string:)),
            size: 20
          )
          Text(ticket.assignee ?? "Unassigned")
            .foregroundStyle(ticket.assignee == nil ? .secondary : .primary)
        }
      }
      row("Priority") {
        HStack(spacing: 6) {
          JiraPriorityIcon(priority: ticket.priority)
          Text(ticket.priority ?? "None")
        }
      }
      row("Type") {
        HStack(spacing: 6) {
          JiraIssueTypeIcon(issueType: ticket.issueType)
          Text(ticket.issueType ?? "Unknown")
        }
      }
      if let sprintName {
        row("Sprint") { Text(sprintName) }
      }
    }
    .font(.secondaryDefault)
  }

  private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
        .frame(width: 70, alignment: .leading)
      content()
    }
  }
}

// MARK: - JiraPickUpCard

private struct JiraPickUpCard: View {
  @Binding var repositoryPath: String?
  let repositories: [SelectedRepository]
  let onStart: (SessionProviderKind) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      HStack {
        Text("Pick up with an agent")
          .font(.heading)
        Spacer()
        repositoryMenu
      }
      HStack(spacing: DesignTokens.Spacing.sm) {
        providerButton(.claude, title: "Claude")
        providerButton(.codex, title: "Codex")
      }
      if repositoryPath == nil {
        Text("Choose the repository the agent should work in.")
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
      }
    }
    .padding(DesignTokens.Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color.primary.opacity(0.04))
    )
  }

  private var repositoryMenu: some View {
    Menu {
      ForEach(repositories) { repository in
        Button(repository.name) { repositoryPath = repository.path }
      }
      if repositories.isEmpty {
        Text("Add a repository in Sessions first")
      }
    } label: {
      Label(selectedRepositoryName ?? "Choose repository", systemImage: "folder")
        .font(.secondaryDefault)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var selectedRepositoryName: String? {
    guard let repositoryPath else { return nil }
    return repositories.first { $0.path == repositoryPath }?.name
      ?? URL(fileURLWithPath: repositoryPath).lastPathComponent
  }

  private func providerButton(_ provider: SessionProviderKind, title: String) -> some View {
    Button {
      onStart(provider)
    } label: {
      Label("Start \(title)", systemImage: "play.fill")
    }
    .buttonStyle(ProviderActionButtonStyle(provider: provider))
    .disabled(repositoryPath == nil)
  }
}

// MARK: - JiraLinkedSessionsSection

private struct JiraLinkedSessionsSection: View {
  let sessions: [JiraLinkedSession]
  let onOpen: (JiraLinkedSession) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Agent sessions")
        .font(.heading)
      VStack(spacing: 0) {
        ForEach(sessions) { session in
          JiraLinkedSessionRow(session: session) { onOpen(session) }
          if session.id != sessions.last?.id {
            Divider().padding(.leading, 30)
          }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color.primary.opacity(0.04))
      )
    }
  }
}

private struct JiraLinkedSessionRow: View {
  let session: JiraLinkedSession
  let onOpen: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        Circle()
          .fill(Color.brandPrimary(for: session.provider))
          .frame(width: 8, height: 8)
          .padding(.leading, 4)
        VStack(alignment: .leading, spacing: 2) {
          Text(session.title)
            .font(.secondaryDefault)
            .lineLimit(1)
          Text(subtitle)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if session.isPending {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "arrow.up.forward.square")
            .foregroundStyle(isHovered ? .primary : .tertiary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(isHovered ? Color.primary.opacity(0.05) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(session.isPending)
    .onHover { isHovered = $0 }
    .help(session.isPending ? "Session is starting" : "Open this session")
  }

  private var subtitle: String {
    var parts = [session.provider.rawValue]
    if let branch = session.branchName { parts.append(branch) }
    parts.append(session.lastActivityAt.formatted(.relative(presentation: .named)))
    if session.isMonitored && !session.isPending { parts.append("open") }
    return parts.joined(separator: " · ")
  }
}

// MARK: - JiraPullRequestsSection

/// Pull requests that mention the ticket key (title or body), open first.
private struct JiraPullRequestsSection: View {
  let ticketKey: String
  let pullRequests: [GitHubProjectPullRequest]?
  let isLoading: Bool
  let onRefresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack {
        Text("Pull requests")
          .font(.heading)
        Spacer()
        if isLoading {
          ProgressView().controlSize(.mini)
        } else {
          Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
          }
          .buttonStyle(.borderless)
          .help("Search GitHub again")
        }
      }
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if let pullRequests, !pullRequests.isEmpty {
      VStack(spacing: 0) {
        ForEach(pullRequests) { pullRequest in
          JiraPullRequestRow(pullRequest: pullRequest)
          if pullRequest.id != pullRequests.last?.id {
            Divider().padding(.leading, 10)
          }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color.primary.opacity(0.04))
      )
    } else if pullRequests != nil {
      Text("No pull requests mention \(ticketKey) yet.")
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
    } else if !isLoading {
      Text("GitHub not searched.")
        .font(.secondarySmall)
        .foregroundStyle(.tertiary)
    }
  }
}

private struct JiraPullRequestRow: View {
  let pullRequest: GitHubProjectPullRequest
  @State private var isHovered = false

  var body: some View {
    Button {
      if let url = URL(string: pullRequest.url) { NSWorkspace.shared.open(url) }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        StateChip(text: stateText, systemImage: stateIcon, tone: stateTone)
        VStack(alignment: .leading, spacing: 2) {
          Text(pullRequest.title)
            .font(.secondaryDefault)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Text(verbatim: "\(pullRequest.repositoryName) #\(pullRequest.number)")
            .font(.jetBrainsMono(size: 10))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 6)
        Image(systemName: "arrow.up.right.square")
          .foregroundStyle(isHovered ? .primary : .tertiary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(isHovered ? Color.primary.opacity(0.05) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("Open \(pullRequest.repositoryNameWithOwner)#\(pullRequest.number) on GitHub")
  }

  private var normalizedState: String {
    pullRequest.isDraft ? "draft" : pullRequest.state.lowercased()
  }

  private var stateText: String {
    switch normalizedState {
    case "open": return "Open"
    case "merged": return "Merged"
    case "closed": return "Closed"
    case "draft": return "Draft"
    default: return pullRequest.state.capitalized
    }
  }

  private var stateIcon: String {
    switch normalizedState {
    case "merged": return "arrow.triangle.merge"
    case "closed": return "xmark.circle"
    default: return "arrow.triangle.pull"
    }
  }

  private var stateTone: Color {
    switch normalizedState {
    case "open": return .green
    case "merged": return .purple
    case "closed": return .red
    default: return .secondary
    }
  }
}
