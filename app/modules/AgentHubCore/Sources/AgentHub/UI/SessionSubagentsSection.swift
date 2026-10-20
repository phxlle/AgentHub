//
//  SessionSubagentsSection.swift
//  AgentHub
//
//  Collapsible list of the subagents the current agent started. Hidden when there
//  are none. Refreshes when the parent session writes (spawning or finishing a
//  subagent always shows up in the parent transcript), not on a timer.
//

import SwiftUI

struct SessionSubagentsSection: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  /// The parent's last activity: changes when a subagent starts or reports back.
  let refreshTrigger: Date?
  let service: (any SubagentDiscoveryServiceProtocol)?
  let reader: any ChatTranscriptReading

  @State private var subagents: [SessionSubagent] = []
  @State private var isExpanded = false

  private var runningCount: Int { subagents.filter { $0.status == .running }.count }

  var body: some View {
    Group {
      if !subagents.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          header
          if isExpanded {
            SubagentListRows(subagents: subagents, providerKind: providerKind, reader: reader)
              .padding(.bottom, DesignTokens.Spacing.xs)
            .transition(.opacity)
          }
          Divider()
        }
      }
    }
    .task(id: TaskKey(sessionID: session.id, trigger: refreshTrigger)) {
      await refresh()
    }
  }

  private var header: some View {
    Button {
      withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .foregroundStyle(.secondary)
        Image(systemName: "person.2.wave.2")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.brandPrimary(for: providerKind))
        Text(subagents.count == 1 ? "1 subagent" : "\(subagents.count) subagents")
          .font(.secondaryDefault)
        if runningCount > 0 {
          StateChip(text: "\(runningCount) running", systemImage: "circle.fill", tone: .blue)
        }
        Spacer()
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: 26)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isExpanded ? "Hide subagents" : "Show the subagents this agent started")
    .accessibilityLabel("\(subagents.count) subagents, \(runningCount) running")
  }

  private func refresh() async {
    guard let service else { return }
    // Coalesce bursts of parent activity while the agent streams.
    try? await Task.sleep(for: .milliseconds(400))
    guard !Task.isCancelled else { return }
    let found = await service.subagents(for: session, provider: providerKind)
    guard !Task.isCancelled else { return }
    if found != subagents {
      withAnimation(.easeOut(duration: 0.15)) { subagents = found }
    }
  }

  private struct TaskKey: Equatable {
    let sessionID: String
    let trigger: Date?
  }
}

// MARK: - SidebarSubagentsDisclosure

/// Under a sidebar session row: appears while the session has subagents running
/// (or after you opened it), and folds out to list them. Rows open each subagent
/// as a chat window; several can be opened side by side.
struct SidebarSubagentsDisclosure: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  /// The row's last activity: a subagent starting or finishing always changes it.
  let refreshTrigger: Date

  @Environment(\.agentHub) private var agentHub
  @State private var subagents: [SessionSubagent] = []
  @State private var isExpanded = false

  private var runningCount: Int { subagents.filter { $0.status == .running }.count }

  var body: some View {
    Group {
      if runningCount > 0 || (isExpanded && !subagents.isEmpty) {
        VStack(alignment: .leading, spacing: 0) {
          Button {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
              Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9))
              Text(label)
                .font(.secondaryCaption)
              Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 26)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(isExpanded ? "Hide subagents" : "Show this session's subagents")
          if isExpanded, let reader = agentHub?.chatTranscriptReader {
            SubagentListRows(
              subagents: subagents, providerKind: providerKind, reader: reader, indent: 22,
              compact: true)
          }
        }
        .transition(.opacity)
      }
    }
    .task(id: refreshTrigger) {
      guard let service = agentHub?.subagentDiscoveryService else { return }
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      let found = await service.subagents(for: session, provider: providerKind)
      if found != subagents {
        withAnimation(.easeOut(duration: 0.15)) { subagents = found }
      }
    }
  }

  private var label: String {
    let total = subagents.count == 1 ? "1 subagent" : "\(subagents.count) subagents"
    return runningCount > 0 ? "\(total) · \(runningCount) running" : total
  }
}
