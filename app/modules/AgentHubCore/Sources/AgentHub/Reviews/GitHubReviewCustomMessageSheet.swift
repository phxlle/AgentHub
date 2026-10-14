//
//  GitHubReviewCustomMessageSheet.swift
//  AgentHub
//
//  Starts a new session for a pull request with a message the user writes,
//  e.g. a question, instead of one of the prompt templates.
//

import AgentHubGitHub
import SwiftUI

struct GitHubReviewCustomMessageContext: Identifiable {
  let pullRequest: GitHubProjectPullRequest
  let provider: SessionProviderKind

  var id: String { "\(pullRequest.id)-\(provider.rawValue)" }
}

struct GitHubReviewCustomMessageSheet: View {
  let context: GitHubReviewCustomMessageContext
  let onCancel: () -> Void
  let onStart: (_ message: String, _ includePullRequestContext: Bool) -> Void

  @State private var message = ""
  @State private var includePullRequestContext = true
  @FocusState private var isMessageFocused: Bool

  private var trimmedMessage: String {
    message.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: 3) {
        Text("New \(context.provider.rawValue) session")
          .font(.geist(size: 15, weight: .semibold))
        Text(verbatim: "#\(context.pullRequest.number) · \(context.pullRequest.title)")
          .font(.secondaryDefault)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      TextField("Ask a question or describe what to do", text: $message, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(4...10)
        .focused($isMessageFocused)
        .accessibilityLabel("Message for the new session")

      Toggle(isOn: $includePullRequestContext) {
        Text("Tell the agent which pull request this is about")
          .font(.secondaryDefault)
      }
      .toggleStyle(.checkbox)
      .help("Prefixes the message with the pull request number, title, URL, and repository")

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Start \(context.provider.rawValue)") {
          onStart(trimmedMessage, includePullRequestContext)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(trimmedMessage.isEmpty)
        .help("Start the session (⌘↩)")
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 520)
    .onAppear { isMessageFocused = true }
  }
}
