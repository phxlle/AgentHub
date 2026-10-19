//
//  JiraSprintView.swift
//  AgentHub
//
//  Jira sprint board: status columns, assignee/sprint switching, ticket details,
//  and handing a ticket to Claude or Codex.
//

import AgentWorkflowJiraCLI
import SwiftUI

struct JiraSprintView: View {
  @Bindable var viewModel: JiraSprintViewModel
  let repositories: [SelectedRepository]
  let linkedSessions: [String: [JiraLinkedSession]]
  let onStart: (JiraTicketSnapshot, SessionProviderKind, String) async -> Void
  let onOpenSession: (JiraLinkedSession) -> Void

  @FocusState private var isBoardFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      JiraSprintHeader(
        viewModel: viewModel,
        onSync: {
          let openSessionKeys = Set(
            linkedSessions.filter { $0.value.contains { $0.isMonitored } }.keys)
          viewModel.startSync(openSessionKeys: openSessionKeys)
        },
        onCancelSync: viewModel.cancelSyncPlanning
      )
      content
    }
    .overlay(alignment: .top) {
      if let notice = viewModel.statusNotice {
        JiraStatusNoticeView(notice: notice, onDismiss: viewModel.dismissStatusNotice)
          .padding(.top, DesignTokens.Spacing.sm)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: viewModel.statusNotice)
    .sheet(isPresented: isSyncPlanPresented) {
      JiraSyncPlanSheet(viewModel: viewModel)
    }
    .inspector(isPresented: isDetailPresented) {
      detail
        .inspectorColumnWidth(min: 340, ideal: 420, max: 560)
    }
    .task {
      if viewModel.state == .idle { await viewModel.load() }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.state {
    case .failed(let message):
      JiraSprintErrorView(message: message, viewModel: viewModel)
    case .idle, .loading, .loaded:
      if viewModel.sprintTickets.isEmpty && viewModel.state != .loaded {
        JiraBoardSkeleton()
      } else if viewModel.selectedSprint == nil {
        ContentUnavailableView(
          "No open sprint",
          systemImage: "calendar.badge.exclamationmark",
          description: Text("This board has no active or upcoming sprint. Pick another board above.")
        )
      } else {
        board
      }
    }
  }

  private var board: some View {
    // Columns get the exact viewport height: inside a horizontal ScrollView an
    // unbounded column is laid out taller than the screen and centered, which
    // clips the top of long columns.
    GeometryReader { geometry in
      boardColumns(height: max(geometry.size.height - DesignTokens.Spacing.lg, 200))
    }
    .focusable()
    .focused($isBoardFocused)
    .focusEffectDisabled()
    .onAppear { isBoardFocused = true }
    .onKeyPress(.upArrow) { move(.up) }
    .onKeyPress(.downArrow) { move(.down) }
    .onKeyPress(.leftArrow) { move(.left) }
    .onKeyPress(.rightArrow) { move(.right) }
    .onKeyPress(.escape) {
      guard viewModel.selectedTicketKey != nil else { return .ignored }
      viewModel.closeTicket()
      return .handled
    }
    .overlay {
      if viewModel.filteredTickets.isEmpty {
        ContentUnavailableView(
          "No matching tickets",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text("Try another assignee or clear the search.")
        )
        .allowsHitTesting(false)
      }
    }
  }

  private func boardColumns(height: CGFloat) -> some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
        ForEach(viewModel.columns) { column in
          JiraBoardColumnView(
            column: column,
            selectedTicketKey: viewModel.selectedTicketKey,
            canStart: viewModel.repositoryPath != nil,
            linkedSessions: linkedSessions,
            onOpen: {
              viewModel.openTicket($0.key)
              isBoardFocused = true
            },
            onOpenSession: onOpenSession,
            onStart: start,
            browseURL: viewModel.browseURL(for:),
            onDropTicket: { key in
              Task {
                await viewModel.moveTicket(key, toStatus: column.status, category: column.category)
              }
            }
          )
        }
      }
      .frame(height: height, alignment: .top)
      .padding(.horizontal, DesignTokens.Spacing.lg)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let ticket = viewModel.selectedTicket {
      JiraTicketDetailView(
        ticket: ticket,
        sprintName: viewModel.selectedSprint?.name,
        isLoadingDetail: viewModel.isLoadingDetail,
        browseURL: viewModel.browseURL(for: ticket),
        repositoryPath: $viewModel.repositoryPath,
        repositories: repositories,
        linkedSessions: linkedSessions[ticket.key] ?? [],
        pullRequests: viewModel.pullRequestsByTicket[ticket.key],
        isLoadingPullRequests: viewModel.loadingPullRequestKeys.contains(ticket.key),
        onRefreshPullRequests: { viewModel.loadPullRequestsIfNeeded(for: ticket.key, force: true) },
        onStart: { provider in start(ticket, provider) },
        onOpenSession: onOpenSession,
        onClose: viewModel.closeTicket
      )
    }
  }

  private func move(_ direction: JiraSprintViewModel.MoveDirection) -> KeyPress.Result {
    viewModel.moveSelection(direction)
    return .handled
  }

  private var isSyncPlanPresented: Binding<Bool> {
    Binding(
      get: { viewModel.syncPlan != nil },
      set: { if !$0 { viewModel.cancelSync() } }
    )
  }

  private var isDetailPresented: Binding<Bool> {
    Binding(
      get: { viewModel.selectedTicketKey != nil },
      set: { if !$0 { viewModel.closeTicket() } }
    )
  }

  private func start(_ ticket: JiraTicketSnapshot, _ provider: SessionProviderKind) {
    guard let path = viewModel.repositoryPath else {
      viewModel.openTicket(ticket.key)
      return
    }
    let detailed = viewModel.selectedTicket?.key == ticket.key ? viewModel.selectedTicket ?? ticket : ticket
    Task { await onStart(detailed, provider, path) }
  }
}

// MARK: - JiraSprintErrorView

private struct JiraSprintErrorView: View {
  let message: String
  @Bindable var viewModel: JiraSprintViewModel

  var body: some View {
    ContentUnavailableView {
      Label("Could not load Jira", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
      Text("AgentHub reads Jira through the Atlassian CLI (`acli`).")
    } actions: {
      HStack {
        Button(viewModel.isConnecting ? "Waiting for browser…" : "Connect Jira") {
          Task { await viewModel.connect() }
        }
        .disabled(viewModel.isConnecting)
        Button("Retry") {
          Task { await viewModel.load() }
        }
      }
    }
  }
}

// MARK: - JiraBoardSkeleton

/// Column-shaped placeholder while the sprint loads, so the board doesn't jump.
private struct JiraBoardSkeleton: View {
  @State private var isPulsing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let cardCounts = [4, 3, 2, 3]

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
      ForEach(cardCounts.indices, id: \.self) { column in
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
          RoundedRectangle(cornerRadius: 3)
            .frame(width: 90, height: 10)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
          ForEach(0..<cardCounts[column], id: \.self) { _ in
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
              .frame(height: 84)
          }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(width: JiraBoardColumnView.width, alignment: .top)
      }
    }
    .foregroundStyle(Color.primary.opacity(isPulsing ? 0.07 : 0.04))
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isPulsing = true }
    }
    .accessibilityLabel("Loading sprint")
  }
}

// MARK: - JiraStatusNoticeView

/// Short confirmation (or failure) of a status move; dismisses itself.
private struct JiraStatusNoticeView: View {
  let notice: JiraSprintViewModel.StatusNotice
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        .foregroundStyle(notice.isError ? .orange : .green)
      Text(notice.text)
        .font(.secondaryDefault)
        .lineLimit(2)
      Button(action: onDismiss) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .help("Dismiss")
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .frame(minHeight: 34)
    .frame(maxWidth: 520)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(Color.surfaceElevated)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
    )
    .task(id: notice) {
      try? await Task.sleep(for: .seconds(notice.isError ? 8 : 4))
      guard !Task.isCancelled else { return }
      onDismiss()
    }
  }
}
