//
//  GitHubReviewSessionCommandSheet.swift
//  AgentHub
//

import SwiftUI

struct GitHubReviewSessionCommandSheet: View {
  let context: GitHubReviewSessionCommandContext
  let onCancel: () -> Void
  let onSend: (String) -> Void

  @State private var command = ""
  @FocusState private var commandIsFocused: Bool

  private var trimmedCommand: String {
    command.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Send command to \(context.link.provider.rawValue)")
          .font(.primaryLarge)
        Text("#\(context.pullRequest.number) · \(context.pullRequest.title)")
          .font(.secondaryDefault)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text("Session: \(context.link.displayName)")
          .font(.secondaryCaption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }

      TextField("What should this session do next?", text: $command, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(3...8)
        .focused($commandIsFocused)
        .accessibilityLabel("Follow-up command")

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)

        Button("Send") {
          onSend(trimmedCommand)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(trimmedCommand.isEmpty)
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 500)
    .onAppear {
      commandIsFocused = true
    }
  }
}
