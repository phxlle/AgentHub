//
//  AntigravitySearchService.swift
//  AgentHub
//
//  Lightweight search across Antigravity CLI conversations, indexed from
//  conversation_summaries.db (title, preview, workspace).
//

import AgentHubSessionGraph
import Foundation
import os

public actor AntigravitySearchService {

  private let dataPath: String
  private var sessionIndex: [String: SessionIndexEntry] = [:]
  private var isIndexBuilt = false
  private var lastIndexedModTime: Date?

  public init(antigravityDataPath: String? = nil) {
    self.dataPath = AntigravitySessionFileScanner.expandedDataPath(
      antigravityDataPath ?? AntigravitySessionFileScanner.defaultDataPath)
  }

  public func search(query: String, filterPath: String? = nil) async -> [SessionSearchResult] {
    if !isIndexBuilt || shouldRebuildIndex() {
      await buildIndex()
    }
    guard !query.isEmpty else { return [] }

    var results: [SessionSearchResult] = []
    for (_, entry) in sessionIndex {
      if let filterPath, !(entry.projectPath.hasPrefix(filterPath) || entry.projectPath == filterPath) {
        continue
      }

      var bestScore = 0
      var bestField: SearchMatchField = .slug
      var bestText = ""
      let candidates: [(String?, SearchMatchField, Int)] = [
        (entry.slug, .slug, 5),
        (entry.firstMessage, .firstMessage, 3),
        (entry.gitBranch, .gitBranch, 2),
        (entry.projectPath, .path, 0),
      ]
      for (text, field, fieldBonus) in candidates {
        guard let text, !text.isEmpty, let match = SearchScoring.score(query: query, against: text) else { continue }
        let total = match.score + fieldBonus
        if total > bestScore {
          bestScore = total
          bestField = field
          bestText = text
        }
      }

      if bestScore > 0 {
        results.append(
          SessionSearchResult(
            id: entry.sessionId,
            slug: entry.slug,
            projectPath: entry.projectPath,
            gitBranch: entry.gitBranch,
            firstMessage: entry.firstMessage,
            summaries: entry.summaries,
            lastActivityAt: entry.lastActivityAt,
            matchedField: bestField,
            matchedText: bestText,
            relevanceScore: bestScore
          ))
      }
    }

    results.sort { lhs, rhs in
      if lhs.relevanceScore != rhs.relevanceScore { return lhs.relevanceScore > rhs.relevanceScore }
      return lhs.lastActivityAt > rhs.lastActivityAt
    }
    AppLogger.search.info("[AntigravitySearch] query=\(query) results=\(results.count)")
    return results
  }

  public func rebuildIndex() async {
    isIndexBuilt = false
    await buildIndex()
  }

  public func indexedSessionCount() async -> Int {
    sessionIndex.count
  }

  // MARK: - Index Building

  private func buildIndex() async {
    sessionIndex.removeAll()
    let summaries = AntigravityConversationSummaryIndex.shared.summaries(dataPath: dataPath)
    for path in AntigravitySessionFileScanner.listSessionFiles(antigravityDataPath: dataPath) {
      guard let meta = AntigravitySessionFileScanner.readSessionMeta(from: path, antigravityDataPath: dataPath) else { continue }
      let summary = summaries[meta.sessionId]
      let title = summary?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let preview = summary?.preview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let lastActivity = [summary?.lastModifiedAt, meta.startedAt, fileModificationDate(path)].compactMap { $0 }.max() ?? Date()
      sessionIndex[meta.sessionId] = SessionIndexEntry(
        sessionId: meta.sessionId,
        projectPath: meta.projectPath,
        slug: title.isEmpty ? String(meta.sessionId.prefix(8)) : title,
        gitBranch: meta.branch,
        firstMessage: preview.isEmpty ? nil : preview,
        summaries: [],
        lastActivityAt: lastActivity
      )
    }
    isIndexBuilt = true
    lastIndexedModTime = summariesModificationDate()
    AppLogger.search.info("[AntigravitySearch] index built: \(self.sessionIndex.count) sessions")
  }

  private func fileModificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  private func summariesModificationDate() -> Date? {
    let dbPath = dataPath + "/conversation_summaries.db"
    return [dbPath, dbPath + "-wal"].compactMap(fileModificationDate).max()
  }

  private func shouldRebuildIndex() -> Bool {
    guard let modTime = summariesModificationDate() else { return true }
    guard let last = lastIndexedModTime else { return true }
    return modTime > last
  }
}

extension AntigravitySearchService: SessionSearchServiceProtocol {}
