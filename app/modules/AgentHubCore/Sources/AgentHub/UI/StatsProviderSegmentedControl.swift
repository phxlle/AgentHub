//
//  StatsProviderSegmentedControl.swift
//  AgentHub
//
//  Compact segmented control for switching between Claude, Codex and Antigravity stats.
//

import SwiftUI

/// A compact segmented control for the stats view with underline indicator
public struct StatsProviderSegmentedControl: View {
  @Binding var selectedProvider: SessionProviderKind
  let claudeSessionCount: Int
  let codexSessionCount: Int
  let antigravitySessionCount: Int

  public init(
    selectedProvider: Binding<SessionProviderKind>,
    claudeSessionCount: Int = 0,
    codexSessionCount: Int = 0,
    antigravitySessionCount: Int = 0
  ) {
    self._selectedProvider = selectedProvider
    self.claudeSessionCount = claudeSessionCount
    self.codexSessionCount = codexSessionCount
    self.antigravitySessionCount = antigravitySessionCount
  }

  public var body: some View {
    UnderlineSegmentedControl(tint: Color.brandPrimary(for: selectedProvider), spacing: 10) {
      segmentButton(for: .claude, count: claudeSessionCount)
      segmentButton(for: .codex, count: codexSessionCount)
      segmentButton(for: .antigravity, count: antigravitySessionCount)
    }
    .padding(.horizontal, 4)
  }

  private func segmentButton(for provider: SessionProviderKind, count: Int) -> some View {
    Button {
      selectedProvider = provider
    } label: {
      // Three tabs must fit the 280pt stats menu, so no Beta pill here; the
      // label shrinks a little instead of truncating.
      Text("\(provider.rawValue) (\(count))")
        .font(.geist(size: 13, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .foregroundColor(
          selectedProvider == provider
            ? Color.brandPrimary(for: provider)
            : .secondary
        )
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
