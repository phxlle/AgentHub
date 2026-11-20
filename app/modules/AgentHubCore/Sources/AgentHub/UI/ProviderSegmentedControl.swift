//
//  ProviderSegmentedControl.swift
//  AgentHub
//
//  Custom segmented control for switching between Claude, Codex and Antigravity providers.
//  Always shows all tabs regardless of installation status.
//

import SwiftUI

public struct ProviderSegmentedControl: View {
  @Binding var selectedProvider: SessionProviderKind
  let claudeSessionCount: Int
  let codexSessionCount: Int
  let antigravitySessionCount: Int

  public init(
    selectedProvider: Binding<SessionProviderKind>,
    claudeSessionCount: Int,
    codexSessionCount: Int,
    antigravitySessionCount: Int = 0,
    claudeEnabled: Bool = true,
    codexEnabled: Bool = true
  ) {
    self._selectedProvider = selectedProvider
    self.claudeSessionCount = claudeSessionCount
    self.codexSessionCount = codexSessionCount
    self.antigravitySessionCount = antigravitySessionCount
  }

  public var body: some View {
    UnderlineSegmentedControl(tint: Color.brandPrimary(for: selectedProvider)) {
      segmentButton(for: .claude, count: claudeSessionCount)
      segmentButton(for: .codex, count: codexSessionCount)
      segmentButton(for: .antigravity, count: antigravitySessionCount)
    }
  }

  private func segmentButton(for provider: SessionProviderKind, count: Int) -> some View {
    Button {
      selectedProvider = provider
    } label: {
      HStack(spacing: 4) {
        Text(provider.rawValue)
          .font(.geist(size: 13, weight: .semibold))
        if count > 0 {
          Text("(\(count))")
            .font(.secondaryDefault)
        }
        if provider != .claude {
          Text("Beta")
            .font(.secondaryCaption)
            .foregroundColor(selectedProvider == provider ? .white : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(selectedProvider == provider ? Color.brandPrimary(for: provider).opacity(0.8) : Color.gray.opacity(0.2))
            .clipShape(Capsule())
        }
      }
      .foregroundColor(selectedProvider == provider ? Color.brandPrimary(for: provider) : .secondary)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
