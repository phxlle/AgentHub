//
//  GitHubReviewRecommendation.swift
//  AgentHub
//

import Foundation

enum GitHubReviewRecommendation {
  static func priorityRank(_ priority: String?) -> Int {
    guard let normalized = normalized(priority), !normalized.isEmpty else { return 5 }

    if containsAny(normalized, values: ["urgent", "critical", "highest", "p0"]) {
      return 0
    }
    if containsAny(normalized, values: ["high", "p1"]) {
      return 1
    }
    if containsAny(normalized, values: ["medium", "normal", "p2"]) {
      return 2
    }
    if containsAny(normalized, values: ["low", "p3"]) {
      return 3
    }
    return 4
  }

  static func isUrgent(_ priority: String?) -> Bool {
    priorityRank(priority) == 0
  }

  private static func normalized(_ priority: String?) -> String? {
    priority?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func containsAny(_ value: String, values: [String]) -> Bool {
    values.contains { value.contains($0) }
  }
}
