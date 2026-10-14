//
//  WorkspaceChrome.swift
//  AgentHub
//
//  Shared chrome for the Workflows / Reviews / Sprint / Sessions workspaces:
//  the workspace switcher, search field, state chips, and provider action buttons.
//  Flat by default (DESIGN.md "Surface Before Shadow"): depth comes from tone.
//

import SwiftUI

// MARK: - WorkspaceSwitcher

struct WorkspaceSwitcherItem: Identifiable {
  let section: AgentHubWorkspaceSection
  let systemImage: String
  let shortcut: Character
  /// Live operational count (e.g. reviews waiting). Hidden when nil or zero.
  let count: Int?
  var id: AgentHubWorkspaceSection { section }
}

/// Quiet tab strip: icon + label + live count, with a tonal selection that glides
/// between tabs. Each tab names its ⌘ shortcut in the tooltip.
struct WorkspaceSwitcher: View {
  @Binding var selection: AgentHubWorkspaceSection
  let items: [WorkspaceSwitcherItem]

  @Namespace private var selectionNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 2) {
      ForEach(items) { item in
        WorkspaceSwitcherTab(
          item: item,
          isSelected: selection == item.section,
          namespace: selectionNamespace
        ) {
          withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) {
            selection = item.section
          }
        }
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(Color.primary.opacity(0.045))
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AgentHub workspace")
  }
}

private struct WorkspaceSwitcherTab: View {
  let item: WorkspaceSwitcherItem
  let isSelected: Bool
  let namespace: Namespace.ID
  let action: () -> Void

  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: item.systemImage)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(isSelected ? Color.brandPrimary(from: runtimeTheme) : .secondary)
        Text(item.section.rawValue)
          .font(.geist(size: 12, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(isSelected ? .primary : .secondary)
        if let count = item.count, count > 0 {
          Text(count > 99 ? "99+" : "\(count)")
            .font(.geist(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(
              Capsule().fill(Color.primary.opacity(isSelected ? 0.12 : 0.07))
            )
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 1, style: .continuous)
            .fill(Color.surfaceCard)
            .overlay(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 1, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .matchedGeometryEffect(id: "selection", in: namespace)
        } else if isHovered {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 1, style: .continuous)
            .fill(Color.primary.opacity(0.05))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("\(item.section.rawValue) (⌘\(item.shortcut))")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityValue(item.count.map { "\($0)" } ?? "")
  }
}

// MARK: - WorkspaceSearchField

/// Search field shared by the workspaces; ⌘F focuses it.
struct WorkspaceSearchField: View {
  let prompt: String
  @Binding var text: String
  var width: CGFloat = 240

  @FocusState private var isFocused: Bool
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .font(.secondaryDefault)
        .focused($isFocused)
        .onExitCommand { isFocused = false }
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      } else if !isFocused {
        Text("⌘F")
          .font(.geist(size: 10, weight: .medium))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 9)
    .frame(width: width, height: 28)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        .fill(Color.primary.opacity(isFocused ? 0.07 : 0.045))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        .strokeBorder(
          isFocused ? Color.brandPrimary(from: runtimeTheme).opacity(0.7) : Color.primary.opacity(0.08),
          lineWidth: 1)
    )
    .animation(.easeOut(duration: 0.15), value: isFocused)
    .background(
      Button("") { isFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    )
  }
}

// MARK: - StateChip

/// Compact state label: tone + text (never color alone, DESIGN.md "State Has Words").
struct StateChip: View {
  let text: String
  var systemImage: String?
  var tone: Color = .secondary

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 9, weight: .bold))
      }
      Text(text)
        .font(.geist(size: 11, weight: .medium))
        .lineLimit(1)
    }
    .foregroundStyle(tone == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone))
    .padding(.horizontal, 7)
    .frame(height: 20)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        .fill((tone == .secondary ? Color.primary : tone).opacity(tone == .secondary ? 0.06 : 0.14))
    )
  }
}

// MARK: - ProviderActionButtonStyle

/// Provider-tinted action: tonal fill with the provider color as text, so it stays
/// readable on every theme (white-on-pastel prominent buttons don't).
struct ProviderActionButtonStyle: ButtonStyle {
  let provider: SessionProviderKind
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    ProviderActionButtonBody(
      configuration: configuration, provider: provider, isEnabled: isEnabled)
  }
}

private struct ProviderActionButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let provider: SessionProviderKind
  let isEnabled: Bool
  @State private var isHovered = false

  var body: some View {
    let tint = Color.brandPrimary(for: provider)
    configuration.label
      .font(.geist(size: 12, weight: .semibold))
      .foregroundStyle(isEnabled ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
      .frame(maxWidth: .infinity)
      .frame(height: 32)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
          .fill(
            (isEnabled ? tint : Color.primary).opacity(
              configuration.isPressed ? 0.28 : isHovered ? 0.2 : 0.12))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
          .strokeBorder((isEnabled ? tint : Color.primary).opacity(0.25), lineWidth: 1)
      )
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}
