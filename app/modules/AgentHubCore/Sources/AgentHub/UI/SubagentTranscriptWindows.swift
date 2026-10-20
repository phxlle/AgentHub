//
//  SubagentTranscriptWindows.swift
//  AgentHub
//
//  Opens a subagent's conversation as a read-only chat in its own window, so
//  several can sit side by side. "Open all" tiles them across the screen.
//

import AppKit
import SwiftUI

@MainActor
enum SubagentTranscriptWindows {
  private static var windows: [String: NSWindow] = [:]
  private static var closeObservers: [String: NSObjectProtocol] = [:]

  static func open(
    _ subagent: SessionSubagent,
    providerKind: SessionProviderKind,
    reader: any ChatTranscriptReading
  ) {
    window(for: subagent, providerKind: providerKind, reader: reader).makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Opens every given subagent and lays the windows out next to each other.
  static func openSideBySide(
    _ subagents: [SessionSubagent],
    providerKind: SessionProviderKind,
    reader: any ChatTranscriptReading
  ) {
    guard !subagents.isEmpty, let screen = NSScreen.main?.visibleFrame else { return }
    let shown = Array(subagents.prefix(6))
    let columns = min(shown.count, 3)
    let rows = Int((Double(shown.count) / Double(columns)).rounded(.up))
    let width = screen.width / CGFloat(columns)
    let height = screen.height / CGFloat(rows)
    for (index, subagent) in shown.enumerated() {
      let column = index % columns
      let row = index / columns
      let frame = NSRect(
        x: screen.minX + CGFloat(column) * width,
        y: screen.maxY - CGFloat(row + 1) * height,
        width: width, height: height)
      let window = window(for: subagent, providerKind: providerKind, reader: reader)
      window.setFrame(frame, display: true, animate: false)
      window.orderFront(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private static func window(
    for subagent: SessionSubagent,
    providerKind: SessionProviderKind,
    reader: any ChatTranscriptReading
  ) -> NSWindow {
    if let existing = windows[subagent.transcriptPath] { return existing }
    let content = ChatTranscriptView(
      transcriptPath: subagent.transcriptPath,
      providerKind: providerKind,
      reader: reader,
      onSend: nil
    )
    .frame(minWidth: 360, minHeight: 300)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = subagent.name
    window.subtitle = [providerKind.rawValue, "subagent", subagent.kind].compactMap { $0 }
      .joined(separator: " · ")
    window.contentView = NSHostingView(rootView: content)
    window.isReleasedWhenClosed = false
    window.center()
    let key = subagent.transcriptPath
    windows[key] = window
    closeObservers[key] = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        windows.removeValue(forKey: key)
        if let observer = closeObservers.removeValue(forKey: key) {
          NotificationCenter.default.removeObserver(observer)
        }
      }
    }
    return window
  }
}

// MARK: - SubagentListRows

/// Rows for a session's subagents, shared by the session card and the sidebar.
/// Clicking a row opens that subagent's chat in its own window.
struct SubagentListRows: View {
  let subagents: [SessionSubagent]
  let providerKind: SessionProviderKind
  let reader: any ChatTranscriptReading
  var indent: CGFloat = 0
  var compact = false

  var body: some View {
    VStack(spacing: 0) {
      ForEach(subagents) { subagent in
        SubagentRow(subagent: subagent, compact: compact) {
          SubagentTranscriptWindows.open(subagent, providerKind: providerKind, reader: reader)
        }
        .padding(.leading, indent)
      }
      if subagents.count > 1 {
        Button {
          SubagentTranscriptWindows.openSideBySide(
            subagents.filter { $0.status == .running }.isEmpty
              ? subagents : subagents.filter { $0.status == .running },
            providerKind: providerKind, reader: reader)
        } label: {
          Label("Open all side by side", systemImage: "rectangle.split.3x1")
            .font(.secondaryCaption)
        }
        .buttonStyle(.borderless)
        .padding(.leading, indent + DesignTokens.Spacing.md)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Open the running subagents (or all of them) as chats next to each other")
      }
    }
  }
}

private struct SubagentRow: View {
  let subagent: SessionSubagent
  let compact: Bool
  let onOpen: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 8) {
        statusIcon.frame(width: 14)
        VStack(alignment: .leading, spacing: 1) {
          Text(subagent.name)
            .font(compact ? .secondarySmall : .secondaryDefault)
            .lineLimit(1)
          if !compact, let detail {
            Text(detail)
              .font(.secondaryCaption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 6)
        Image(systemName: "macwindow")
          .font(.system(size: 10))
          .foregroundStyle(isHovered ? .primary : .tertiary)
          .opacity(isHovered ? 1 : 0.6)
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, compact ? 3 : 4)
      .background(isHovered ? Color.primary.opacity(0.05) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("Open \(subagent.name) as a chat in its own window")
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
      parts.append(SubagentDuration.text(end.timeIntervalSince(start)))
    }
    return parts.joined(separator: " · ")
  }
}

enum SubagentDuration {
  static func text(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total)s" }
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \(total % 3600 / 60)m"
  }
}
