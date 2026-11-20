//
//  AntigravitySessionFileWatcher.swift
//  AgentHub
//
//  Watches Antigravity CLI transcript JSONL files for real-time monitoring.
//  Same byte-offset kqueue design as CodexSessionFileWatcher; only the parser
//  and the session-file lookup differ.
//

import AgentHubSessionGraph
import Combine
import Darwin
import Foundation
import os

public actor AntigravitySessionFileWatcher {

  private var watchedSessions: [String: FileWatcherInfo] = [:]
  private nonisolated let stateSubject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  private let dataPath: String
  private nonisolated let processingQueue = DispatchQueue(label: "com.agenthub.antigravitywatcher.processing")
  private var approvalTimeoutSeconds: Int = 0

  public nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    stateSubject.eraseToAnyPublisher()
  }

  public init(antigravityDataPath: String = AntigravitySessionFileScanner.defaultDataPath) {
    self.dataPath = AntigravitySessionFileScanner.expandedDataPath(antigravityDataPath)
  }

  public func setApprovalTimeout(_ seconds: Int) async {
    approvalTimeoutSeconds = max(1, seconds)
  }

  public func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String? = nil) async {
    if let existing = watchedSessions[sessionId] {
      stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: buildMonitorState(from: existing.parseResult)))
      return
    }

    let filePath = sessionFilePath
      ?? AntigravitySessionFileScanner.transcriptPath(dataPath: dataPath, conversationId: sessionId)
    guard FileManager.default.fileExists(atPath: filePath) else {
      AppLogger.watcher.error("[Antigravity] Could not find transcript for: \(sessionId)")
      return
    }

    var parseResult = AntigravitySessionJSONLParser.parseSessionFile(at: filePath, approvalTimeoutSeconds: approvalTimeoutSeconds)
    stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: buildMonitorState(from: parseResult)))

    let fileDescriptor = open(filePath, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      let openErrno = errno
      AppLogger.watcher.error(
        "[Antigravity] Could not open file for watching: \(filePath) errno=\(openErrno) (\(String(cString: strerror(openErrno)), privacy: .public))"
      )
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend],
      queue: DispatchQueue.global(qos: .utility)
    )

    var filePosition = getFileSize(filePath)
    let timeout = approvalTimeoutSeconds
    var lastFileEventTime = Date()
    var lastKnownFileSize = filePosition
    var lastEmittedStatus: SessionStatus = parseResult.currentStatus
    let statusTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))

    func rescheduleStatusTimer() {
      guard
        let nextInterval = SessionWatcherTimerPolicy.nextInterval(
          lastActivity: parseResult.recentActivities.last,
          currentStatus: parseResult.currentStatus,
          lastFileEventTime: lastFileEventTime,
          approvalTimeoutSeconds: timeout
        )
      else {
        statusTimer.schedule(deadline: .distantFuture, leeway: SessionWatcherTimerPolicy.timerLeeway)
        return
      }
      statusTimer.schedule(deadline: .now() + nextInterval, leeway: SessionWatcherTimerPolicy.timerLeeway)
    }

    source.setEventHandler { [weak self] in
      guard let self else { return }
      self.processingQueue.async {
        lastFileEventTime = Date()
        let newLines = self.readNewLines(from: filePath, startingAt: &filePosition)
        lastKnownFileSize = filePosition
        guard !newLines.isEmpty else {
          rescheduleStatusTimer()
          return
        }
        AntigravitySessionJSONLParser.parseNewLines(newLines, into: &parseResult, approvalTimeoutSeconds: timeout)
        lastEmittedStatus = parseResult.currentStatus

        let updatedState = self.buildMonitorState(from: parseResult)
        Task { @MainActor in
          self.stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: updatedState))
        }

        let parseResultSnapshot = parseResult
        let lastFileEventSnapshot = lastFileEventTime
        let lastKnownFileSizeSnapshot = lastKnownFileSize
        Task {
          await self.updateStoredWatcherInfo(
            sessionId: sessionId,
            parseResult: parseResultSnapshot,
            lastFileEventTime: lastFileEventSnapshot,
            lastKnownFileSize: lastKnownFileSizeSnapshot
          )
        }
        rescheduleStatusTimer()
      }
    }

    source.setCancelHandler {
      close(fileDescriptor)
    }
    source.resume()

    statusTimer.setEventHandler { [weak self] in
      guard let self else { return }
      self.processingQueue.async {
        let timeSinceLastEvent = Date().timeIntervalSince(lastFileEventTime)
        let currentFileSize = self.getFileSize(filePath)
        var storedInfoNeedsUpdate = false

        if timeSinceLastEvent > 5 && currentFileSize > lastKnownFileSize {
          var tempPosition = lastKnownFileSize
          let newLines = self.readNewLines(from: filePath, startingAt: &tempPosition)
          if !newLines.isEmpty {
            AntigravitySessionJSONLParser.parseNewLines(newLines, into: &parseResult, approvalTimeoutSeconds: timeout)
            lastKnownFileSize = tempPosition
            lastFileEventTime = Date()
          } else {
            lastKnownFileSize = currentFileSize
          }
          storedInfoNeedsUpdate = true
        }

        AntigravitySessionJSONLParser.updateCurrentStatus(&parseResult, approvalTimeoutSeconds: timeout)

        if parseResult.currentStatus != lastEmittedStatus {
          lastEmittedStatus = parseResult.currentStatus
          storedInfoNeedsUpdate = true
          let updatedState = self.buildMonitorState(from: parseResult)
          Task { @MainActor in
            self.stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: updatedState))
          }
        }

        if storedInfoNeedsUpdate {
          let parseResultSnapshot = parseResult
          let lastFileEventSnapshot = lastFileEventTime
          let lastKnownFileSizeSnapshot = lastKnownFileSize
          Task {
            await self.updateStoredWatcherInfo(
              sessionId: sessionId,
              parseResult: parseResultSnapshot,
              lastFileEventTime: lastFileEventSnapshot,
              lastKnownFileSize: lastKnownFileSizeSnapshot
            )
          }
        }
        rescheduleStatusTimer()
      }
    }
    rescheduleStatusTimer()
    statusTimer.resume()

    watchedSessions[sessionId] = FileWatcherInfo(
      filePath: filePath,
      source: source,
      statusTimer: statusTimer,
      parseResult: parseResult,
      lastFileEventTime: lastFileEventTime,
      lastKnownFileSize: lastKnownFileSize
    )
  }

  public func stopMonitoring(sessionId: String) async {
    guard let info = watchedSessions.removeValue(forKey: sessionId) else { return }
    info.source.cancel()
    info.statusTimer.cancel()
  }

  public func getState(sessionId: String) async -> SessionMonitorState? {
    guard let info = watchedSessions[sessionId] else { return nil }
    return buildMonitorState(from: info.parseResult)
  }

  public func refreshState(sessionId: String) async {
    guard var info = watchedSessions[sessionId] else { return }
    var filePosition = info.lastKnownFileSize
    var parseResult = info.parseResult
    let newLines = readNewLines(from: info.filePath, startingAt: &filePosition)
    if !newLines.isEmpty {
      AntigravitySessionJSONLParser.parseNewLines(newLines, into: &parseResult, approvalTimeoutSeconds: approvalTimeoutSeconds)
      info.lastKnownFileSize = filePosition
      info.lastFileEventTime = Date()
    } else {
      AntigravitySessionJSONLParser.updateCurrentStatus(&parseResult, approvalTimeoutSeconds: approvalTimeoutSeconds)
    }
    info.parseResult = parseResult
    watchedSessions[sessionId] = info
    stateSubject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: buildMonitorState(from: parseResult)))
  }

  // MARK: - Helpers

  private nonisolated func getFileSize(_ path: String) -> UInt64 {
    var st = stat()
    guard stat(path, &st) == 0 else { return 0 }
    return UInt64(st.st_size)
  }

  private nonisolated func readNewLines(from path: String, startingAt position: inout UInt64) -> [String] {
    guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }
    let currentSize = getFileSize(path)
    guard currentSize > position else { return [] }
    do {
      try handle.seek(toOffset: position)
      let data = handle.readDataToEndOfFile()
      position = currentSize
      guard let content = String(data: data, encoding: .utf8) else { return [] }
      return content.components(separatedBy: .newlines).filter { !$0.isEmpty }
    } catch {
      return []
    }
  }

  private nonisolated func buildMonitorState(from result: AntigravitySessionJSONLParser.ParseResult) -> SessionMonitorState {
    SessionMonitorState(
      status: result.currentStatus,
      currentTool: result.pendingToolUses.first?.toolName,
      lastActivityAt: result.lastActivityAt ?? Date(),
      inputTokens: result.lastInputTokens,
      outputTokens: result.lastOutputTokens,
      totalOutputTokens: result.totalOutputTokens,
      cacheReadTokens: result.cacheReadTokens,
      cacheCreationTokens: result.cacheCreationTokens,
      messageCount: result.messageCount,
      sessionStartedAt: result.sessionStartedAt,
      model: result.model,
      gitBranch: nil,
      pendingToolUse: nil,
      recentActivities: result.recentActivities,
      lastAssistantMessage: result.lastAssistantMessage,
      hasMermaidContent: result.hasMermaidContent,
      detectedResourceLinks: result.detectedResourceLinks,
      detectedMCPAppResources: result.detectedMCPAppResources,
      detectedMCPAppInvocations: result.detectedMCPAppInvocations,
      detectedLocalhostURL: result.detectedLocalhostURL
    )
  }

  private func updateStoredWatcherInfo(
    sessionId: String,
    parseResult: AntigravitySessionJSONLParser.ParseResult,
    lastFileEventTime: Date,
    lastKnownFileSize: UInt64
  ) {
    guard var info = watchedSessions[sessionId] else { return }
    info.parseResult = parseResult
    info.lastFileEventTime = lastFileEventTime
    info.lastKnownFileSize = lastKnownFileSize
    watchedSessions[sessionId] = info
  }
}

private struct FileWatcherInfo {
  let filePath: String
  let source: DispatchSourceFileSystemObject
  let statusTimer: DispatchSourceTimer
  var parseResult: AntigravitySessionJSONLParser.ParseResult
  var lastFileEventTime: Date
  var lastKnownFileSize: UInt64
}

extension AntigravitySessionFileWatcher: SessionFileWatcherProtocol {}
