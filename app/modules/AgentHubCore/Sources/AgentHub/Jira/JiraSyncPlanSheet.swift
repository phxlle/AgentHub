//
//  JiraSyncPlanSheet.swift
//  AgentHub
//
//  Review the ticket moves Sync proposes before anything changes in Jira.
//

import SwiftUI

struct JiraSyncPlanSheet: View {
  @Bindable var viewModel: JiraSprintViewModel

  private var plan: [JiraSprintViewModel.SyncChange] { viewModel.syncPlan ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: 3) {
        Text(plan.isEmpty ? "Everything is in sync" : "Sync \(plan.count) tickets")
          .font(.geist(size: 15, weight: .semibold))
        Text(
          "Based on pull requests that mention each ticket and on open agent sessions. Only the tickets currently shown are checked."
        )
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      if !plan.isEmpty {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(plan) { change in
              JiraSyncChangeRow(change: change)
              if change.id != plan.last?.id { Divider() }
            }
          }
        }
        .frame(maxHeight: 360)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color.primary.opacity(0.04)))
      }

      if !viewModel.syncSkipped.isEmpty {
        Label(viewModel.syncSkipped.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
          .font(.secondarySmall)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button(plan.isEmpty ? "Close" : "Cancel", role: .cancel) { viewModel.cancelSync() }
          .keyboardShortcut(.cancelAction)
        if !plan.isEmpty {
          Button {
            Task { await viewModel.applySync() }
          } label: {
            if viewModel.isApplyingSync {
              ProgressView().controlSize(.small)
            } else {
              Text("Apply \(plan.count) changes")
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(viewModel.isApplyingSync)
        }
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 560)
  }
}

private struct JiraSyncChangeRow: View {
  let change: JiraSprintViewModel.SyncChange

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
      Text(change.key)
        .font(.jetBrainsMono(size: 11, weight: .semibold))
        .frame(width: 78, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text(change.summary)
          .font(.secondaryDefault)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(change.fromStatus).foregroundStyle(.secondary)
          Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
          Text(change.toStatus).fontWeight(.semibold)
          Text("· \(change.reason)").foregroundStyle(.secondary)
        }
        .font(.secondarySmall)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
  }
}
