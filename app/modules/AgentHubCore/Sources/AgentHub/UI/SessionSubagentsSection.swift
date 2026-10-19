//
//  SessionSubagentsSection.swift
//  AgentHub
//
//  Collapsible list of the subagents the current agent started. Hidden when there
//  are none. Refreshes when the parent session writes (spawning or finishing a
//  subagent always shows up in the parent transcript), not on a timer.
//

import AppKit
import SwiftUI

struct SessionSubagentsSection: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  /// The parent's last activity: changes when a subagent starts or reports back.
  let refreshTrigger: Date?
  let service: (any SubagentDiscoveryServiceProtocol)?

  @State private var subagents: [SessionSubagent] = []
  @State private var isExpanded = false

  private var runningCount: Int { subagents.filter { $0.status == .running }.count }

  var body: some View {
    Group {
      if !subagents.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          header
          if isExpanded {
            VStack(spacing: 0) {
              ForEach(subagents) { subagent in
                SessionSubagentRow(subagent: subagent)
              }
            }
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

// MARK: - SessionSubagentRow

private struct SessionSubagentRow: View {
  let subagent: SessionSubagent
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      statusIcon
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(subagent.name)
          .font(.secondaryDefault)
          .lineLimit(1)
        if let detail {
          Text(detail)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 6)
      if isHovered {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: subagent.transcriptPath)])
        } label: {
          Image(systemName: "doc.text.magnifyingglass").font(.system(size: 10))
        }
        .buttonStyle(.borderless)
        .help("Show transcript in Finder")
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, 4)
    .background(isHovered ? Color.primary.opacity(0.04) : .clear)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(subagent.name), \(subagent.status == .running ? "running" : "done")")
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch subagent.status {
    case .running:
      ProgressView().controlSize(.mini)
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 11))
        .foregroundStyle(.green)
    }
  }

  private var detail: String? {
    var parts: [String] = []
    if let kind = subagent.kind { parts.append(kind) }
    parts.append(subagent.status == .running ? "running" : "done")
    if let start = subagent.startedAt {
      let end = subagent.status == .running ? Date.now : (subagent.lastActivityAt ?? start)
      parts.append(Self.duration(end.timeIntervalSince(start)))
    }
    return parts.joined(separator: " · ")
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \(total % 3600 / 60)m"
  }
}
