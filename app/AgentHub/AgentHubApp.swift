//
//  AgentHubApp.swift
//  AgentHub
//
//  Created by James Rochabrun on 1/11/26.
//

import AgentHubCore
import AgentHubGlobalSessionPanel
import AgentHubVoicePanel
import CoreText
import Ghostty
import SwiftUI
import UserNotifications

// MARK: - App Delegate

/// Handles app lifecycle events for process cleanup
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// Shared provider instance - created here so it's available for lifecycle events.
  /// Wires the Ghostty-aware terminal surface factory; `AgentHubCore` falls back
  /// to the regular SwiftTerm surface when no provider is supplied.
  let provider = AgentHubProvider(
    terminalSurfaceFactory: DefaultEmbeddedTerminalSurfaceFactory(
      ghosttyProvider: { AgentHubGhosttyTerminalSurface() }
    ),
    globalSessionControlPanelPresenterFactory: { provider, defaults in
      AppKitGlobalSessionControlPanelPresenter(provider: provider, defaults: defaults)
    },
    voiceHUDPresenterFactory: { provider, defaults in
      AppKitVoiceHUDPresenter(
        host: AgentHubVoiceHUDHost(provider: provider, defaults: defaults),
        engine: provider.realtimeVoiceEngine,
        configuration: .agentHub,
        defaults: defaults
      )
    }
  )

  /// Update controller for Sparkle auto-updates
  let updateController = UpdateController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().setNotificationCategories([
      GitHubCIFailureNotification.category()
    ])
    registerBundledFonts()
    // Sweep any approval hooks left installed by a previous crash/force-quit
    // before sessions start restoring. Re-installs happen naturally as each
    // session begins monitoring.
    provider.reconcileClaudeHooksOnLaunch()
    provider.cleanupOrphanedProcesses()
    provider.purgeStaleWindowAutosaveDefaults()
    provider.startWorktreeLaunchRequestMonitoring()
    provider.globalSessionControlPanelCoordinator.start()
    provider.voiceControlCoordinator.start()
  }

  /// Register all bundled fonts (Geist, GeistMono, JetBrains Mono)
  private func registerBundledFonts() {
    let otfFonts = [
      "Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold",
      "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold", "GeistMono-Bold",
      "SourceCodePro-Regular",
    ]
    let ttfFonts = [
      "JetBrainsMono-Regular", "JetBrainsMono-Medium",
      "JetBrainsMono-SemiBold", "JetBrainsMono-Bold",
      "FiraCode-Regular",
      "CascadiaMono-Regular",
    ]
    for name in otfFonts {
      if let url = Bundle.main.url(forResource: name, withExtension: "otf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
    for name in ttfFonts {
      if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    provider.stopWorktreeLaunchRequestMonitoring()
    provider.globalSessionControlPanelCoordinator.stop()
    provider.voiceControlCoordinator.stop()
    // Terminate all active terminal processes on app quit
    provider.terminateAllTerminals()
    // Stop all dev servers spawned for web preview
    DevServerManager.shared.stopAllServers()
    // Close pooled MCP clients, including stdio subprocesses and HTTP sessions.
    provider.shutdownMCPAppDiscoveryService()
    // Remove every approval hook we installed and clear claims so external
    // Claude Code sessions after quit run vanilla.
    provider.flushClaudeHooksOnTerminate()
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let ciFailurePayload = GitHubCIFailureNotificationPayload(
      userInfo: response.notification.request.content.userInfo
    )
    let isFixCIAction = response.actionIdentifier == GitHubCIFailureNotification.fixActionIdentifier
    Task { @MainActor in
      NSApp.activate(ignoringOtherApps: true)
      if let ciFailurePayload, let providerKind = ciFailurePayload.providerKind {
        provider.globalSessionSelectionRouter.select(
          providerKind: providerKind,
          sessionId: ciFailurePayload.sessionId,
          projectPath: ciFailurePayload.projectPath
        )
        provider.gitHubCIFailureActionRouter.request(
          payload: ciFailurePayload,
          action: isFixCIAction ? .fixCI : .openGitHubPanel
        )
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}

// MARK: - App

@main
struct AgentHubApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  init() {
    // Must run before any terminal/watcher/subprocess spawns: Finder-launched
    // apps inherit a 256 open-file soft limit, which a busy hub exhausts.
    FileDescriptorLimits.raiseSoftLimit()
    // Launched from inside a Claude Code session? Drop its identity markers, or
    // every Claude session started here skips its transcript and never resolves.
    InheritedAgentSessionEnvironment.scrubFromProcess()
    // Logs beach balls with recent activity (category "Performance").
    MainThreadStallMonitor.shared.start()
  }

  var body: some Scene {
    WindowGroup {
      AgentHubOperationsView()
        .agentHub(appDelegate.provider)
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesView(updateController: appDelegate.updateController)
      }

      CommandMenu("Navigate") {
        Button("Workflows") {
          AgentHubAppCommand.selectWorkspace(.workflows)
        }
        .keyboardShortcut("1", modifiers: .command)

        Button("Reviews") {
          AgentHubAppCommand.selectWorkspace(.reviews)
        }
        .keyboardShortcut("2", modifiers: .command)

        Button("Sessions") {
          AgentHubAppCommand.selectWorkspace(.sessions)
        }
        .keyboardShortcut("3", modifiers: .command)

        Button("Sprint") {
          AgentHubAppCommand.selectWorkspace(.sprint)
        }
        .keyboardShortcut("4", modifiers: .command)

        Divider()

        Button("Resume Session by ID…") {
          AgentHubAppCommand.resumeSessionByID()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Archive Current Session") {
          AgentHubAppCommand.archiveCurrentSession()
        }
        .keyboardShortcut("a", modifiers: [.command, .option])
      }
    }

    MenuBarExtra(
      isInserted: Binding(
        get: { appDelegate.provider.displaySettings.isMenuBarMode },
        set: { _ in }
      )
    ) {
      AgentHubMenuBarContent()
        .environment(\.agentHub, appDelegate.provider)
    } label: {
      AgentHubMenuBarLabel(provider: appDelegate.provider)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .agentHub(appDelegate.provider)
    }
  }
}
