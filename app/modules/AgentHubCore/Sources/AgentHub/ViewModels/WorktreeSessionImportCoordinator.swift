import Foundation

@MainActor
@Observable
final class WorktreeSessionImportCoordinator {
  private let pageSize: Int
  private(set) var importingWorktreePaths: Set<String> = []
  private(set) var hasMoreByWorktreePath: [String: Bool] = [:]

  init(pageSize: Int = 3) {
    self.pageSize = pageSize
  }

  func isImporting(_ worktree: WorktreeSettingsWorktree) -> Bool {
    importingWorktreePaths.contains(normalized(worktree.path))
  }

  func canShowMore(_ worktree: WorktreeSettingsWorktree) -> Bool {
    hasMoreByWorktreePath[normalized(worktree.path)] ?? true
  }

  func importInitial(
    _ worktree: WorktreeSettingsWorktree,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    antigravityViewModel: CLISessionsViewModel? = nil
  ) async {
    await importNextPage(
      worktree,
      pageSize: 1,
      shouldFocusWorktree: true,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      antigravityViewModel: antigravityViewModel
    )
  }

  func showMore(
    _ worktree: WorktreeSettingsWorktree,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    antigravityViewModel: CLISessionsViewModel? = nil
  ) async {
    await importNextPage(
      worktree,
      pageSize: pageSize,
      shouldFocusWorktree: true,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      antigravityViewModel: antigravityViewModel
    )
  }

  private func importNextPage(
    _ worktree: WorktreeSettingsWorktree,
    pageSize: Int,
    shouldFocusWorktree: Bool,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    antigravityViewModel: CLISessionsViewModel?
  ) async {
    let key = normalized(worktree.path)
    guard importingWorktreePaths.insert(key).inserted else { return }
    defer {
      importingWorktreePaths.remove(key)
    }

    if shouldFocusWorktree {
      await focus(worktree, in: claudeViewModel)
      await focus(worktree, in: codexViewModel)
      if let antigravityViewModel { await focus(worktree, in: antigravityViewModel) }
    }

    let requestLimit = pageSize + 1
    let loadedClaudePage = await claudeViewModel.loadLatestSessionsForImport(
      inWorktreePath: key,
      excludingSessionIds: excludedSessionIds(in: key, for: claudeViewModel),
      limit: requestLimit
    )
    let loadedCodexPage = await codexViewModel.loadLatestSessionsForImport(
      inWorktreePath: key,
      excludingSessionIds: excludedSessionIds(in: key, for: codexViewModel),
      limit: requestLimit
    )

    var providerPages = [
      ProviderImportPage(providerKind: .claude, page: loadedClaudePage),
      ProviderImportPage(providerKind: .codex, page: loadedCodexPage),
    ]
    if let antigravityViewModel {
      let loadedAntigravityPage = await antigravityViewModel.loadLatestSessionsForImport(
        inWorktreePath: key,
        excludingSessionIds: excludedSessionIds(in: key, for: antigravityViewModel),
        limit: requestLimit
      )
      providerPages.append(ProviderImportPage(providerKind: .antigravity, page: loadedAntigravityPage))
    }
    let candidates = providerPages
      .flatMap { providerPage in
        providerPage.page.sessions.map {
          ProviderSessionImportCandidate(providerKind: providerPage.providerKind, session: $0)
        }
      }
      .sorted {
        if $0.session.lastActivityAt == $1.session.lastActivityAt {
          return $0.session.id < $1.session.id
        }
        return $0.session.lastActivityAt > $1.session.lastActivityAt
      }

    let selectedCandidates = Array(candidates.prefix(pageSize))
    let claudeSessions = selectedCandidates.sessions(for: .claude)
    let codexSessions = selectedCandidates.sessions(for: .codex)
    let antigravitySessions = selectedCandidates.sessions(for: .antigravity)

    await claudeViewModel.importMonitoredSessions(claudeSessions)
    await codexViewModel.importMonitoredSessions(codexSessions)
    if let antigravityViewModel, !antigravitySessions.isEmpty {
      await antigravityViewModel.importMonitoredSessions(antigravitySessions)
      await antigravityViewModel.refreshImportedWorktreeSessions()
    }

    if !claudeSessions.isEmpty {
      await claudeViewModel.refreshImportedWorktreeSessions()
    }
    if !codexSessions.isEmpty {
      await codexViewModel.refreshImportedWorktreeSessions()
    }

    hasMoreByWorktreePath[key] = candidates.count > pageSize || providerPages.contains { $0.page.hasMore }
  }

  private func focus(_ worktree: WorktreeSettingsWorktree, in viewModel: CLISessionsViewModel) async {
    await viewModel.focusExistingWorktree(
      worktree.worktree,
      parentRepositoryPath: worktree.parentModulePath
    )
  }

  private func excludedSessionIds(in worktreePath: String, for viewModel: CLISessionsViewModel) -> Set<String> {
    Set(viewModel.monitoredSessions(inWorktreePath: worktreePath).map(\.id))
  }

  private func normalized(_ path: String) -> String {
    WorktreeModuleResolver.normalizedDirectoryPath(path)
  }
}

private struct ProviderImportPage {
  let providerKind: SessionProviderKind
  let page: WorktreeSessionImportPage
}

private struct ProviderSessionImportCandidate {
  let providerKind: SessionProviderKind
  let session: CLISession
}

private extension Array where Element == ProviderSessionImportCandidate {
  func sessions(for providerKind: SessionProviderKind) -> [CLISession] {
    filter { $0.providerKind == providerKind }.map(\.session)
  }
}
