//
//  JiraSprintHeader.swift
//  AgentHub
//
//  Sprint board header: board + sprint switcher, search, and the assignee filter bar.
//

import AgentWorkflowJiraCLI
import SwiftUI

struct JiraSprintHeader: View {
  @Bindable var viewModel: JiraSprintViewModel
  var onSync: () -> Void = {}
  var onCancelSync: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
        JiraSprintSwitcher(viewModel: viewModel)
        Spacer()
        WorkspaceSearchField(prompt: "Search tickets", text: $viewModel.searchText, width: 220)
        syncButton
        refreshButton
      }
      JiraAssigneeBar(viewModel: viewModel)
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.top, DesignTokens.Spacing.lg)
    .padding(.bottom, DesignTokens.Spacing.md)
  }

  @ViewBuilder
  private var syncButton: some View {
    if viewModel.isPlanningSync {
      Button(action: onCancelSync) {
        HStack(spacing: 5) {
          ProgressView().controlSize(.mini)
          Text("Cancel sync")
        }
        .font(.geist(size: 12, weight: .medium))
      }
      .buttonStyle(.bordered)
      .help("Stop checking pull requests; you can start Sync again")
    } else {
      Button(action: onSync) {
        HStack(spacing: 5) {
          Image(systemName: "arrow.triangle.2.circlepath")
          Text("Sync")
        }
        .font(.geist(size: 12, weight: .medium))
      }
      .buttonStyle(.bordered)
      .disabled(viewModel.state != .loaded)
      .help(
        "Move the tickets you see to match their pull requests and open sessions. You review the changes before anything moves in Jira."
      )
    }
  }

  private var refreshButton: some View {
    Button {
      Task { await viewModel.load() }
    } label: {
      if viewModel.state == .loading {
        ProgressView().controlSize(.small).frame(width: 16, height: 16)
      } else {
        Image(systemName: "arrow.clockwise")
          .frame(width: 16, height: 16)
      }
    }
    .buttonStyle(.borderless)
    .disabled(viewModel.state == .loading)
    .help("Refresh sprint")
    .keyboardShortcut("r", modifiers: .command)
  }
}

// MARK: - JiraSprintSwitcher

private struct JiraSprintSwitcher: View {
  @Bindable var viewModel: JiraSprintViewModel

  var body: some View {
    Menu {
      if !viewModel.sprints.isEmpty {
        Section("Sprints") {
          ForEach(viewModel.sprints) { sprint in
            Button {
              Task { await viewModel.selectSprint(sprint.id) }
            } label: {
              menuLabel(
                sprint.isActive ? "\(sprint.name) · active" : sprint.name,
                isSelected: sprint.id == viewModel.selectedSprintID
              )
            }
          }
        }
      }
      if viewModel.boards.count > 1 {
        Section("Boards") {
          ForEach(viewModel.boards) { board in
            Button {
              Task { await viewModel.selectBoard(board.id) }
            } label: {
              menuLabel(board.name, isSelected: board.id == viewModel.selectedBoardID)
            }
          }
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(viewModel.selectedSprint?.name ?? "No open sprint")
            .font(.geist(size: 17, weight: .semibold))
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        Text(subtitle)
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .fixedSize()
  }

  private var subtitle: String {
    var parts = [viewModel.selectedBoard?.name ?? "Jira"]
    if let sprint = viewModel.selectedSprint {
      if let start = sprint.startDate, let end = sprint.endDate {
        let style = Date.FormatStyle().day().month(.abbreviated)
        parts.append("\(start.formatted(style)) – \(end.formatted(style))")
        let days = Calendar.current.dateComponents([.day], from: .now, to: end).day ?? 0
        switch days {
        case ..<0: parts.append("ended")
        case 0: parts.append("ends today")
        case 1: parts.append("1 day left")
        default: parts.append("\(days) days left")
        }
      } else if !sprint.isActive {
        parts.append("not started")
      }
    }
    parts.append("\(viewModel.sprintTickets.count) tickets")
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func menuLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }
}

// MARK: - JiraAssigneeBar

/// Jira-style quick filter: everyone, me, each assignee in the sprint, unassigned.
private struct JiraAssigneeBar: View {
  @Bindable var viewModel: JiraSprintViewModel

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        JiraFilterChip(
          title: "Everyone",
          count: viewModel.sprintTickets.count,
          isSelected: viewModel.assigneeFilter == .everyone
        ) { viewModel.assigneeFilter = .everyone }

        JiraFilterChip(
          title: "Only mine",
          count: viewModel.assignees.first(where: viewModel.isMe)?.ticketCount ?? 0,
          isSelected: viewModel.assigneeFilter == .me
        ) { viewModel.assigneeFilter = .me }

        Divider().frame(height: 18).padding(.horizontal, 4)

        ForEach(viewModel.assignees) { assignee in
          JiraAssigneeChip(
            assignee: assignee,
            isMe: viewModel.isMe(assignee),
            isSelected: viewModel.assigneeFilter == .person(accountId: assignee.accountId)
          ) {
            viewModel.assigneeFilter = .person(accountId: assignee.accountId)
          }
        }

        if viewModel.unassignedCount > 0 {
          JiraFilterChip(
            title: "Unassigned",
            count: viewModel.unassignedCount,
            isSelected: viewModel.assigneeFilter == .unassigned
          ) { viewModel.assigneeFilter = .unassigned }
        }
      }
      .padding(.vertical, 2)
    }
    .scrollIndicators(.never)
  }
}

private struct JiraFilterChip: View {
  let title: String
  let count: Int?
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
        if let count {
          Text("\(count)").foregroundStyle(.secondary)
        }
      }
      .font(.geist(size: 12, weight: isSelected ? .semibold : .medium))
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        Capsule().fill(
          isSelected ? Color.brandPrimary(from: runtimeTheme).opacity(0.18) : Color.primary.opacity(0.05))
      )
      .overlay(
        Capsule().strokeBorder(
          isSelected ? Color.brandPrimary(from: runtimeTheme).opacity(0.6) : .clear, lineWidth: 1)
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

private struct JiraAssigneeChip: View {
  let assignee: JiraSprintViewModel.Assignee
  let isMe: Bool
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    Button(action: action) {
      JiraAvatar(name: assignee.name, url: assignee.avatarURL, size: 26)
        .padding(2)
        .overlay(
          Circle().strokeBorder(
            isSelected ? Color.brandPrimary(from: runtimeTheme) : .clear, lineWidth: 2)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help("\(assignee.name)\(isMe ? " (you)" : "") · \(assignee.ticketCount) tickets")
  }
}
