//
//  JiraVisuals.swift
//  AgentHub
//
//  Small shared visuals for the Sprint board: issue type, priority, status, avatars.
//

import SwiftUI

enum JiraVisuals {
  static func typeSymbol(_ issueType: String?) -> (name: String, color: Color) {
    switch issueType?.lowercased() ?? "" {
    case "bug": return ("ladybug.fill", .red)
    case "story": return ("bookmark.fill", .green)
    case "task": return ("checkmark.square.fill", .blue)
    case "epic": return ("bolt.fill", .purple)
    case "sub-task", "subtask": return ("square.split.2x1.fill", .teal)
    default: return ("circle.fill", .secondary)
    }
  }

  static func prioritySymbol(_ priority: String?) -> (name: String, color: Color)? {
    switch priority?.lowercased() ?? "" {
    case "highest", "blocker", "critical": return ("chevron.up.2", .red)
    case "high": return ("chevron.up", .orange)
    case "medium": return ("equal", .yellow)
    case "low": return ("chevron.down", .blue)
    case "lowest", "trivial": return ("chevron.down.2", .teal)
    default: return nil
    }
  }

  static func categoryColor(_ category: String?) -> Color {
    switch category {
    case "new": return .gray
    case "indeterminate": return .blue
    case "done": return .green
    default: return .secondary
    }
  }
}

// MARK: - JiraIssueTypeIcon

struct JiraIssueTypeIcon: View {
  let issueType: String?
  var size: CGFloat = 12

  var body: some View {
    let symbol = JiraVisuals.typeSymbol(issueType)
    Image(systemName: symbol.name)
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(symbol.color)
      .help(issueType ?? "Unknown type")
  }
}

// MARK: - JiraPriorityIcon

struct JiraPriorityIcon: View {
  let priority: String?

  var body: some View {
    if let symbol = JiraVisuals.prioritySymbol(priority) {
      Image(systemName: symbol.name)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(symbol.color)
        .help("Priority: \(priority ?? "")")
    }
  }
}

// MARK: - JiraStatusPill

struct JiraStatusPill: View {
  let status: String
  let category: String?

  var body: some View {
    let color = JiraVisuals.categoryColor(category)
    Text(status.uppercased())
      .font(.geist(size: 10, weight: .semibold))
      .tracking(0.4)
      .foregroundStyle(category == "new" ? Color.primary.opacity(0.75) : color)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
  }
}

// MARK: - JiraAvatar

/// Jira avatar with an initials fallback while loading or when there is no image.
struct JiraAvatar: View {
  let name: String?
  let url: URL?
  var size: CGFloat = 22

  var body: some View {
    Group {
      if let name {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          initials(for: name)
        }
      } else {
        Image(systemName: "person.crop.circle.badge.questionmark")
          .font(.system(size: size * 0.7))
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
          .background(Color.surfaceOverlay)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .help(name ?? "Unassigned")
  }

  private func initials(for name: String) -> some View {
    let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    // Stable across launches (String.hashValue is seeded per process).
    let hue = Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
    return Text(letters.uppercased())
      .font(.geist(size: size * 0.4, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Color(hue: hue, saturation: 0.45, brightness: 0.7))
  }
}
