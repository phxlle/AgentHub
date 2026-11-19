//
//  AntigravityGlobalStatsService.swift
//  AgentHub
//
//  Aggregates global Antigravity CLI usage from every conversation transcript
//  under <data>/brain/. Same shape as CodexGlobalStatsService so the stats
//  menu can render either.
//

import AgentHubSessionGraph
import Foundation
import Observation
import os

@Observable
public final class AntigravityGlobalStatsService: @unchecked Sendable {

  public private(set) var totalTokens: Int = 0
  public private(set) var totalSessions: Int = 0
  public private(set) var totalMessages: Int = 0
  public private(set) var modelStats: [String: CodexModelUsage] = [:]
  public private(set) var isAvailable: Bool = false
  public private(set) var isLoading: Bool = false
  public private(set) var lastUpdated: Date?

  private let dataPath: String
  private let brainDirectoryPath: String
  private var directoryWatcher: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private var isLoadingInProgress = false
  private var pendingReload = false
  private var debounceWorkItem: DispatchWorkItem?
  private var loadingTask: Task<Void, Never>?

  public var formattedTotalTokens: String {
    formatTokenCount(totalTokens)
  }

  public var sortedModelStats: [(name: String, usage: CodexModelUsage)] {
    modelStats.map { (name: $0.key, usage: $0.value) }
      .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
  }

  public init(antigravityDataPath: String = AntigravitySessionFileScanner.defaultDataPath) {
    dataPath = AntigravitySessionFileScanner.expandedDataPath(antigravityDataPath)
    brainDirectoryPath = dataPath + "/brain"
    isAvailable = FileManager.default.fileExists(atPath: brainDirectoryPath)
    loadStatsAsync()
    startWatching()
  }

  deinit {
    loadingTask?.cancel()
    directoryWatcher?.cancel()
  }

  public func refresh() {
    loadStatsAsync()
  }

  public func cancelLoading() {
    loadingTask?.cancel()
    loadingTask = nil
    DispatchQueue.main.async { [weak self] in
      self?.isLoading = false
      self?.isLoadingInProgress = false
    }
  }

  private func loadStatsAsync() {
    guard FileManager.default.fileExists(atPath: brainDirectoryPath) else {
      DispatchQueue.main.async { [weak self] in self?.isAvailable = false }
      return
    }
    if isLoadingInProgress {
      pendingReload = true
      return
    }
    loadingTask?.cancel()
    isLoadingInProgress = true
    DispatchQueue.main.async { [weak self] in self?.isLoading = true }

    let dataPath = self.dataPath
    loadingTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      let files = AntigravitySessionFileScanner.listSessionFiles(antigravityDataPath: dataPath)
      var aggregatedTokens = 0
      var aggregatedMessages = 0
      var aggregatedModelStats: [String: CodexModelUsage] = [:]

      for filePath in files {
        if Task.isCancelled { return }
        let parseResult = AntigravitySessionJSONLParser.parseForGlobalStats(at: filePath)
        aggregatedTokens += parseResult.totalInputTokens + parseResult.totalOutputTokens
        aggregatedMessages += parseResult.messageCount
        if let model = parseResult.model {
          var existing = aggregatedModelStats[model] ?? CodexModelUsage()
          existing.inputTokens += parseResult.totalInputTokens
          existing.outputTokens += parseResult.totalOutputTokens
          existing.cacheReadTokens += parseResult.cacheReadTokens
          existing.messageCount += parseResult.messageCount
          existing.sessionCount += 1
          aggregatedModelStats[model] = existing
        }
      }
      if Task.isCancelled { return }

      let sessionCount = files.count
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.totalTokens = aggregatedTokens
        self.totalSessions = sessionCount
        self.totalMessages = aggregatedMessages
        self.modelStats = aggregatedModelStats
        self.isAvailable = true
        self.lastUpdated = Date()
        self.isLoading = false
        self.isLoadingInProgress = false
        if self.pendingReload {
          self.pendingReload = false
          self.loadStatsAsync()
        }
      }
    }
  }

  private func startWatching() {
    guard directoryWatcher == nil else { return }
    guard FileManager.default.fileExists(atPath: brainDirectoryPath) else {
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.startWatching() }
      return
    }

    fileDescriptor = open(brainDirectoryPath, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      AppLogger.stats.error("Could not open Antigravity brain directory for watching")
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend, .attrib, .link],
      queue: DispatchQueue.global(qos: .utility)
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      self.debounceWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in self?.loadStatsAsync() }
      self.debounceWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }
    let watchedFd = fileDescriptor
    source.setCancelHandler { close(watchedFd) }
    source.resume()
    directoryWatcher = source
  }

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000_000 { return String(format: "%.1fB", Double(count) / 1_000_000_000) }
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
  }
}
