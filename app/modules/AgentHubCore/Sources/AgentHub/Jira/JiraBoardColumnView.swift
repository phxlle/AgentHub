//
//  JiraBoardColumnView.swift
//  AgentHub
//
//  One status column of the Sprint board and its ticket cards.
//

import AgentWorkflowJiraCLI
import AppKit
import SwiftUI

struct JiraBoardColumnView: View {
  let column: JiraSprintViewModel.BoardColumn
  let selectedTicketKey: String?
  let canStart: Bool
  let linkedSessions: [String: [JiraLinkedSession]]
  let onOpen: (JiraTicketSnapshot) -> Void
  let onOpenSession: (JiraLinkedSession) -> Void
  let onStart: (JiraTicketSnapshot, SessionProviderKind) -> Void
  let browseURL: (JiraTicketSnapshot) -> URL?
  /// A ticket key dropped on this column: move it to this column's status.
  var onDropTicket: (String) -> Void = { _ in }

  @State private var isDropTargeted = false
  @Environment(\.runtimeTheme) private var runtimeTheme

  static let width: CGFloat = 280

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      header
      ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(spacing: DesignTokens.Spacing.sm) {
          ForEach(column.tickets, id: \.key) { ticket in
            // A tap gesture, not a Button: the card holds its own session link,
            // and a button nested in a button never receives the click on macOS.
            JiraTicketCard(
              ticket: ticket,
              isSelected: ticket.key == selectedTicketKey,
              isDone: column.category == "done",
              sessions: linkedSessions[ticket.key] ?? [],
              onOpenSession: onOpenSession
            )
            .onTapGesture { onOpen(ticket) }
            .draggable(ticket.key) {
              JiraTicketCard(ticket: ticket, isSelected: true, isDone: false)
                .frame(width: Self.width - DesignTokens.Spacing.lg)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(ticket) }
            .id(ticket.key)
            .contextMenu { contextMenu(for: ticket) }
          }
          if column.tickets.isEmpty {
            emptyPlaceholder
          }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
      }
      .scrollIndicators(.never)
      .onChange(of: selectedTicketKey) { _, key in
        guard let key, column.tickets.contains(where: { $0.key == key }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key) }
      }
      }
    }
    .frame(width: Self.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .fill(
          isDropTargeted
            ? Color.brandPrimary(from: runtimeTheme).opacity(0.1) : Color.primary.opacity(0.025))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(
          isDropTargeted ? Color.brandPrimary(from: runtimeTheme).opacity(0.6) : .clear,
          style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
    )
    .dropDestination(for: String.self) { keys, _ in
      guard let key = keys.first, !column.tickets.contains(where: { $0.key == key }) else {
        return false
      }
      onDropTicket(key)
      return true
    } isTargeted: { targeted in
      withAnimation(.easeOut(duration: 0.12)) { isDropTargeted = targeted }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(JiraVisuals.categoryColor(column.category))
        .frame(width: 7, height: 7)
      Text(column.status.uppercased())
        .font(.geist(size: 11, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text("\(column.tickets.count)")
        .font(.geist(size: 10, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .frame(minWidth: 18, minHeight: 16)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
      Spacer()
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.top, DesignTokens.Spacing.md)
  }

  private var emptyPlaceholder: some View {
    RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
      .strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
      .frame(height: 64)
      .overlay(
        Text("No tickets")
          .font(.secondarySmall)
          .foregroundStyle(.tertiary)
      )
  }

  @ViewBuilder
  private func contextMenu(for ticket: JiraTicketSnapshot) -> some View {
    Button("Open Details") { onOpen(ticket) }
    Divider()
    Button("Pick Up with Claude") { onStart(ticket, .claude) }
      .disabled(!canStart)
    Button("Pick Up with Codex") { onStart(ticket, .codex) }
      .disabled(!canStart)
    Divider()
    if let url = browseURL(ticket) {
      Button("Open in Jira") { NSWorkspace.shared.open(url) }
    }
    Button("Copy Key") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(ticket.key, forType: .string)
    }
  }
}

// MARK: - JiraTicketCard

struct JiraTicketCard: View {
  let ticket: JiraTicketSnapshot
  let isSelected: Bool
  let isDone: Bool
  var sessions: [JiraLinkedSession] = []
  var onOpenSession: (JiraLinkedSession) -> Void = { _ in }

  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      Text(ticket.summary)
        .font(.geist(size: 13, weight: .medium))
        .foregroundStyle(isDone ? .secondary : .primary)
        .lineLimit(3)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 6) {
        JiraIssueTypeIcon(issueType: ticket.issueType)
        Text(ticket.key)
          .font(.jetBrainsMono(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .strikethrough(isDone, color: .secondary)
        Spacer(minLength: 4)
        if !sessions.isEmpty {
          JiraSessionBadge(sessions: sessions, onOpen: onOpenSession)
        }
        JiraPriorityIcon(priority: ticket.priority)
        JiraAvatar(
          name: ticket.assignee,
          url: ticket.assigneeAvatarURL.flatMap(URL.init(string:))
        )
      }
    }
    .padding(DesignTokens.Spacing.md)
    // Flat at rest (DESIGN.md "Surface Before Shadow"): hover and selection are tonal.
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(backgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .strokeBorder(borderColor, lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(ticket.key): \(ticket.summary)")
  }

  private var backgroundColor: Color {
    if isSelected { return Color.brandPrimary(from: runtimeTheme).opacity(0.12) }
    return isHovered ? Color.primary.opacity(0.075) : Color.primary.opacity(0.045)
  }

  private var borderColor: Color {
    if isSelected { return Color.brandPrimary(from: runtimeTheme).opacity(0.75) }
    return Color.primary.opacity(isHovered ? 0.16 : 0.07)
  }
}

// MARK: - JiraSessionBadge

/// Link to the agent sessions working on a ticket: one session opens directly,
/// several open a menu. Provider dots + count, pulsing ring while one is starting.
struct JiraSessionBadge: View {
  let sessions: [JiraLinkedSession]
  let onOpen: (JiraLinkedSession) -> Void

  @State private var isHovered = false

  var body: some View {
    Group {
      if sessions.count == 1, let session = sessions.first {
        Button { onOpen(session) } label: { label }
          .buttonStyle(.plain)
          .disabled(session.isPending)
          .help(session.isPending ? "Session is starting" : "Open session: \(session.title)")
      } else {
        Menu {
          ForEach(sessions) { session in
            Button("\(session.provider.rawValue) · \(session.title)") { onOpen(session) }
              .disabled(session.isPending)
          }
        } label: {
          label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(sessions.count) agent sessions work on this ticket")
      }
    }
    .onHover { isHovered = $0 }
    .accessibilityLabel(
      sessions.count == 1 ? "Open linked session" : "Open one of \(sessions.count) linked sessions")
  }

  private var label: some View {
    let providers = Array(Set(sessions.map(\.provider))).sorted { $0.rawValue < $1.rawValue }
    return HStack(spacing: 4) {
      HStack(spacing: -3) {
        ForEach(providers, id: \.self) { provider in
          Circle()
            .fill(Color.brandPrimary(for: provider))
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(Color.surfaceCard, lineWidth: 1.5))
        }
      }
      Image(systemName: "terminal")
        .font(.system(size: 9, weight: .semibold))
      Text(verbatim: "\(sessions.count)")
        .font(.geist(size: 10, weight: .semibold))
    }
    .foregroundStyle(isHovered ? .primary : .secondary)
    .padding(.horizontal, 6)
    .frame(height: 18)
    .background(Capsule().fill(Color.primary.opacity(isHovered ? 0.12 : 0.07)))
    .contentShape(Capsule())
  }
}
