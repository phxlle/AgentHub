import AppKit
import SwiftUI

struct SessionManagementActionsModifier: ViewModifier {
  let session: CLISession
  let providerKind: SessionProviderKind
  let customName: String?
  let isPending: Bool
  let isPinned: Bool
  let onPin: (() -> Void)?
  let onArchive: (() -> Void)?

  @Environment(\.agentHub) private var agentHub
  @State private var isNamingSession = false
  @State private var isCreatingWorkflow = false

  func body(content: Content) -> some View {
    content
      .contextMenu {
        if isPending, let onArchive {
          // A launch that never resolved still needs a way out.
          Button("Stop Starting Session", systemImage: "xmark.circle") { onArchive() }
        }
        if !isPending {
          if let onPin {
            Button(
              isPinned ? "Unpin Session" : "Pin Session",
              systemImage: isPinned ? "pin.slash" : "pin"
            ) {
              onPin()
            }
          }
          if onArchive != nil {
            Button("Archive Session", systemImage: "archivebox") {
              onArchive?()
            }
          }
          if onPin != nil || onArchive != nil {
            Divider()
          }

          Button("Copy Session ID", systemImage: "doc.on.doc") {
            copySessionID()
          }

          Button("Rename Session…", systemImage: "pencil") {
            isNamingSession = true
          }

          if let comparisonRequest = workflowAssociation?.comparisonRequest {
            Button("Open Workflow Side by Side", systemImage: "rectangle.split.2x1") {
              agentHub?.openWorkflowSessionComparison(comparisonRequest)
            }
          }

          Divider()

          Menu("Add to Workflow", systemImage: "rectangle.stack.badge.plus") {
            if workflowDestinations.isEmpty {
              Button("No active workflows") {}
                .disabled(true)
            } else {
              ForEach(workflowDestinations) { destination in
                Button {
                  Task {
                    await workflowViewModel?.moveSession(scopedSessionID, to: destination.id)
                  }
                } label: {
                  Label(
                    destination.title,
                    systemImage: destination.id == currentWorkflowID
                      ? "checkmark" : "rectangle.stack"
                  )
                }
                .disabled(destination.id == currentWorkflowID)
              }
              Divider()
            }

            Button("New Workflow…", systemImage: "plus") {
              isCreatingWorkflow = true
            }
          }
        }
      }
      .sheet(isPresented: $isNamingSession) {
        NameSessionSheet(
          session: session,
          currentName: customName,
          onSave: saveName,
          onDismiss: { isNamingSession = false }
        )
      }
      .sheet(isPresented: $isCreatingWorkflow) {
        CreateWorkflowForSessionSheet(
          session: session,
          suggestedName: customName,
          onCreate: createWorkflow,
          onDismiss: { isCreatingWorkflow = false }
        )
      }
  }

  private var sessionsViewModel: CLISessionsViewModel? {
    switch providerKind {
    case .claude: agentHub?.claudeSessionsViewModel
    case .codex: agentHub?.codexSessionsViewModel
    }
  }

  private var workflowViewModel: AgentWorkflowDashboardViewModel? {
    agentHub?.workflowDashboardViewModel
  }

  private var workflowDestinations: [SessionWorkflowDestination] {
    workflowViewModel?.activeWorkflowDestinations ?? []
  }

  private var scopedSessionID: String {
    "\(providerKind.rawValue.lowercased()):\(session.id)"
  }

  private var currentWorkflowID: String? {
    workflowViewModel?.workflowID(containing: scopedSessionID)
  }

  private var workflowAssociation: SessionWorkflowAssociation? {
    workflowViewModel?.workflowAssociation(for: scopedSessionID)
  }

  private func copySessionID() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(session.id, forType: .string)
  }

  private func saveName(_ name: String?) {
    sessionsViewModel?.setCustomName(name, for: session)
  }

  private func createWorkflow(name: String) {
    guard let workflowViewModel else { return }
    Task {
      await workflowViewModel.createManualWorkflowAndMoveSession(
        name: name,
        repositoryPath: session.projectPath,
        branchName: session.branchName,
        sessionID: scopedSessionID
      )
    }
  }
}

struct SessionWorkflowAssociationBadge: View {
  let session: CLISession
  let providerKind: SessionProviderKind

  @Environment(\.agentHub) private var agentHub

  var body: some View {
    if let association {
      HStack(spacing: DesignTokens.Spacing.xs) {
        Label(association.title, systemImage: "rectangle.stack")
          .lineLimit(1)
        Text(association.role == .implementer ? "Implementation" : "Review")
          .foregroundStyle(.tertiary)
      }
      .font(.secondaryCaption)
      .foregroundStyle(.secondary)
      .help(
        association.comparisonRequest == nil
          ? "Related to workflow \(association.title)"
          : "Related to workflow \(association.title). Right-click to open both sessions side by side."
      )
    }
  }

  private var association: SessionWorkflowAssociation? {
    agentHub?.workflowDashboardViewModel.workflowAssociation(
      for: "\(providerKind.rawValue.lowercased()):\(session.id)"
    )
  }
}

extension View {
  func sessionManagementActions(
    session: CLISession,
    providerKind: SessionProviderKind,
    customName: String?,
    isPending: Bool = false,
    isPinned: Bool = false,
    onPin: (() -> Void)? = nil,
    onArchive: (() -> Void)? = nil
  ) -> some View {
    modifier(
      SessionManagementActionsModifier(
        session: session,
        providerKind: providerKind,
        customName: customName,
        isPending: isPending,
        isPinned: isPinned,
        onPin: onPin,
        onArchive: onArchive
      )
    )
  }
}

private struct CreateWorkflowForSessionSheet: View {
  let session: CLISession
  let onCreate: (String) -> Void
  let onDismiss: () -> Void

  @State private var name: String
  @FocusState private var isNameFocused: Bool

  init(
    session: CLISession,
    suggestedName: String?,
    onCreate: @escaping (String) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.session = session
    self.onCreate = onCreate
    self.onDismiss = onDismiss
    let suggestedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let initialName =
      suggestedName.flatMap { $0.isEmpty ? nil : $0 }
      ?? session.branchName
      ?? session.slug
      ?? "New workflow"
    _name = State(initialValue: initialName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text("New Workflow")
          .font(.headline)
        Text("This session will be added immediately.")
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
      }

      TextField("Workflow name or ticket", text: $name)
        .textFieldStyle(.roundedBorder)
        .focused($isNameFocused)
        .onSubmit(create)

      LabeledContent("Repository") {
        Text(session.projectPath)
          .font(.jetBrainsMono(size: 10))
          .lineLimit(1)
          .truncationMode(.middle)
      }
      if let branchName = session.branchName {
        LabeledContent("Branch") {
          Text(branchName)
            .font(.jetBrainsMono(size: 10))
            .lineLimit(1)
        }
      }

      HStack {
        Spacer()
        Button("Cancel", action: onDismiss)
          .keyboardShortcut(.cancelAction)
        Button("Create", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedName.isEmpty)
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 400)
    .onAppear { isNameFocused = true }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func create() {
    guard !trimmedName.isEmpty else { return }
    onCreate(trimmedName)
    onDismiss()
  }
}
