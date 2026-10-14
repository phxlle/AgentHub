//
//  ArchiveUndoToast.swift
//  AgentHub
//
//  Archiving is immediate; this toast offers a short window to undo it.
//

import SwiftUI

/// What an archive removed, so Undo can put it back exactly (pin included).
struct ArchivedSessionsUndo: Identifiable, Equatable {
  struct Entry {
    let provider: SessionProviderKind
    let session: CLISession
    let wasPinned: Bool
  }

  let id = UUID()
  let entries: [Entry]
  let title: String

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct ArchiveUndoToast: View {
  let undo: ArchivedSessionsUndo
  let onUndo: () -> Void
  let onDismiss: () -> Void

  @State private var isHovered = false
  @Environment(\.runtimeTheme) private var runtimeTheme

  static let visibleDuration: Duration = .seconds(6)

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      Image(systemName: "archivebox.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      Text(undo.title)
        .font(.secondaryDefault)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 260, alignment: .leading)
      Button("Undo", action: onUndo)
        .buttonStyle(.plain)
        .font(.geist(size: 12, weight: .semibold))
        .foregroundStyle(Color.brandPrimary(from: runtimeTheme))
        .help("Restore archived sessions")
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .help("Dismiss")
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .frame(height: 36)
    // Shadow is allowed here: a toast floats above content (DESIGN.md, Elevation).
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(Color.surfaceElevated)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
    )
    .onHover { isHovered = $0 }
    // Keep the toast up while the pointer rests on it.
    .task(id: isHovered) {
      guard !isHovered else { return }
      try? await Task.sleep(for: Self.visibleDuration)
      guard !Task.isCancelled else { return }
      onDismiss()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(undo.title)
    .accessibilityAction(named: "Undo", onUndo)
  }
}
