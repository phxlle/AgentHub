//
//  GitHubPromptSettingsView.swift
//  AgentHub
//

import SwiftUI

struct GitHubPromptSettingsView: View {
  @Bindable var library: GitHubPromptLibrary
  @State private var selectedTemplateID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sharedInstructionsSection
      Divider()
      templateEditor
    }
    .task {
      selectAvailableTemplate()
    }
    .onChange(of: library.templates.map(\.id)) { _, _ in
      selectAvailableTemplate()
    }
  }

  private var sharedInstructionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Instructions for every prompt")
        .font(.headline)
      Text(
        "These instructions are appended to every GitHub prompt. Use them for logging rules, safety constraints, or team conventions."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      TextEditor(text: $library.sharedInstructions)
        .font(.system(.caption, design: .monospaced))
        .frame(minHeight: 64, maxHeight: 82)
        .padding(5)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
    .padding(16)
  }

  private var templateEditor: some View {
    HSplitView {
      VStack(spacing: 0) {
        List(selection: $selectedTemplateID) {
          ForEach(library.templates) { template in
            HStack(spacing: 7) {
              Image(systemName: template.isBuiltIn ? "text.badge.checkmark" : "text.badge.plus")
                .foregroundStyle(.secondary)
              Text(template.name)
                .lineLimit(1)
            }
            .tag(Optional(template.id))
          }
        }
        .listStyle(.sidebar)

        Divider()

        HStack(spacing: 10) {
          Button {
            let template = library.addCustomTemplate()
            selectedTemplateID = template.id
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.plain)
          .help("Add a custom prompt")

          Button {
            guard let selectedTemplateID else { return }
            library.deleteTemplate(id: selectedTemplateID)
          } label: {
            Image(systemName: "minus")
          }
          .buttonStyle(.plain)
          .disabled(selectedTemplate?.isBuiltIn != false)
          .help("Delete the selected custom prompt")

          Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
      }
      .frame(minWidth: 180, idealWidth: 205, maxWidth: 240)

      if let selectedTemplate {
        promptDetail(selectedTemplate)
          .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "Select a prompt",
          systemImage: "text.badge.plus",
          description: Text("Choose a prompt template or create your own.")
        )
        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func promptDetail(_ template: GitHubPromptTemplate) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        TextField("Prompt name", text: selectedNameBinding)
          .textFieldStyle(.roundedBorder)

        if template.isBuiltIn {
          Button("Restore default") {
            library.restoreBuiltIn(id: template.id)
          }
          .controlSize(.small)
        }
      }

      Text("Prompt")
        .font(.caption)
        .foregroundStyle(.secondary)

      TextEditor(text: selectedPromptBinding)
        .font(.system(size: 12, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(7)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }

      DisclosureGroup("Available variables") {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
          ForEach(GitHubPromptLibrary.variables) { variable in
            GridRow {
              Text(variable.token)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
              Text(variable.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.top, 7)
      }
      .font(.caption)
    }
    .padding(16)
  }

  private var selectedTemplate: GitHubPromptTemplate? {
    guard let selectedTemplateID else { return nil }
    return library.templates.first { $0.id == selectedTemplateID }
  }

  private var selectedNameBinding: Binding<String> {
    Binding(
      get: { selectedTemplate?.name ?? "" },
      set: { newValue in updateSelectedTemplate { $0.name = newValue } }
    )
  }

  private var selectedPromptBinding: Binding<String> {
    Binding(
      get: { selectedTemplate?.prompt ?? "" },
      set: { newValue in updateSelectedTemplate { $0.prompt = newValue } }
    )
  }

  private func updateSelectedTemplate(_ update: (inout GitHubPromptTemplate) -> Void) {
    guard let selectedTemplateID,
      let index = library.templates.firstIndex(where: { $0.id == selectedTemplateID })
    else { return }
    update(&library.templates[index])
  }

  private func selectAvailableTemplate() {
    guard selectedTemplate == nil else { return }
    selectedTemplateID = library.templates.first?.id
  }
}
