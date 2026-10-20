//
//  InheritedAgentSessionEnvironment.swift
//  AgentHub
//
//  When AgentHub is launched from inside a Claude Code session (e.g. `open` run by
//  an agent), it inherits that session's identity variables. Every Claude session
//  AgentHub then starts believes it is that session's child: it saves no
//  transcript, so AgentHub never detects it and it stays "starting" forever.
//  It also hands children the parent's messaging socket and token.
//  These markers are dropped at launch. User configuration (CLAUDE_CODE_USE_BEDROCK,
//  CLAUDE_CODE_MAX_OUTPUT_TOKENS, …) is kept.
//

import Foundation

public enum InheritedAgentSessionEnvironment {
  /// Variables that identify a running Claude Code session, not user settings.
  static let sessionMarkers: Set<String> = [
    "CLAUDECODE",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_SSE_PORT",
    "CLAUDE_PID",
  ]

  /// The inherited session markers present in `environment`.
  static func markers(in environment: [String: String]) -> [String] {
    environment.keys.filter(sessionMarkers.contains).sorted()
  }

  /// Removes the markers from this process, so every child (terminals, CLIs) starts clean.
  /// Call before any terminal or subprocess is spawned.
  public static func scrubFromProcess() {
    for name in markers(in: ProcessInfo.processInfo.environment) {
      unsetenv(name)
    }
  }
}
