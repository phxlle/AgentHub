import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentHubCore

/// Opens the chat on a real, large transcript in a window and checks the main
/// thread keeps turning. Runs only with TEST_RUNNER_AGENTHUB_CHAT_STRESS_TRANSCRIPT
/// (and optional ..._PROVIDER=claude|codex) set; otherwise it is skipped.
@MainActor
@Suite("Chat stress")
struct ChatTranscriptStressTests {
  @Test("Opening a large transcript does not freeze the main thread")
  func largeTranscriptStaysResponsive() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["AGENTHUB_CHAT_STRESS_TRANSCRIPT"] else { return }
    let provider: SessionProviderKind =
      environment["AGENTHUB_CHAT_STRESS_PROVIDER"] == "codex" ? .codex : .claude

    let view = ChatTranscriptView(
      transcriptPath: path, providerKind: provider, reader: ChatTranscriptReader(),
      onSend: { _ in true })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: view)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }

    // Count main-loop turns for 8 s; a layout loop starves them.
    var longestGap: TimeInterval = 0
    var last = Date()
    let end = Date().addingTimeInterval(8)
    while Date() < end {
      try await Task.sleep(for: .milliseconds(20))
      let now = Date()
      longestGap = max(longestGap, now.timeIntervalSince(last))
      last = now
    }
    print("CHAT_STRESS longest main-thread gap: \(longestGap)s")
    #expect(longestGap < 2.0)
  }
}
