//
//  MainThreadStallMonitor.swift
//  AgentHub
//
//  Logs when the main thread stops responding (a beach ball), with what the app
//  was doing just before. Read with:
//  log show --last 1h --predicate 'subsystem == "com.agenthub" AND category == "Performance"'
//

import Foundation
import os

public final class MainThreadStallMonitor: @unchecked Sendable {
  public static let shared = MainThreadStallMonitor()

  private let queue = DispatchQueue(label: "com.agenthub.stall-monitor", qos: .utility)
  private let lock = OSAllocatedUnfairLock(initialState: State())
  private var timer: DispatchSourceTimer?

  struct State {
    var lastBeat = Date()
    var stallStartedAt: Date?
    var breadcrumbs: [String] = []
  }

  /// Stalls shorter than this are not logged.
  let threshold: TimeInterval = 1.0

  /// Records what the app is doing ("chat open: <session>"); the last few are
  /// logged with a stall so the cause can be traced.
  public static func breadcrumb(_ text: String) {
    shared.lock.withLock { state in
      state.breadcrumbs.append("\(Date().formatted(date: .omitted, time: .standard)) \(text)")
      if state.breadcrumbs.count > 8 { state.breadcrumbs.removeFirst() }
    }
  }

  public func start() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 2, repeating: 0.25)
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    self.timer = timer
  }

  private func tick() {
    let now = Date()
    let snapshot = lock.withLock { $0 }
    let silence = now.timeIntervalSince(snapshot.lastBeat)
    if silence > threshold, snapshot.stallStartedAt == nil {
      lock.withLock { $0.stallStartedAt = snapshot.lastBeat }
      AppLogger.performance.error(
        "Main thread stalled for >\(self.threshold, privacy: .public)s. Recent: \(snapshot.breadcrumbs.joined(separator: " | "), privacy: .public)"
      )
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let beat = Date()
      let stalledSince = self.lock.withLock { state -> Date? in
        let started = state.stallStartedAt
        state.lastBeat = beat
        state.stallStartedAt = nil
        return started
      }
      if let stalledSince {
        AppLogger.performance.error(
          "Main thread recovered after \(beat.timeIntervalSince(stalledSince), format: .fixed(precision: 1), privacy: .public)s")
      }
    }
  }
}
