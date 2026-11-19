//
//  AntigravitySessionMonitorService.swift
//  AgentHub
//
//  Service for discovering Antigravity CLI conversations from
//  ~/.gemini/antigravity-cli and grouping them per tracked repository.
//  Mirrors CodexSessionMonitorService; the scanner and summary source differ.
//

import AgentHubSessionGraph
import Combine
import Foundation

public actor AntigravitySessionMonitorService {

  private let dataPath: String
  private let metadataStore: SessionMetadataStore?

  private nonisolated(unsafe) let repositoriesSubject = CurrentValueSubject<[SelectedRepository], Never>([])
  public nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    repositoriesSubject.eraseToAnyPublisher()
  }

  private var selectedRepositories: [SelectedRepository] = []
  private var ownedWorktreePaths: Set<String> = []
  private var focusedSessionIds: Set<String> = []
  private var ignoredWorktreePathsByRepository: [String: Set<String>] = [:]

  public init(antigravityDataPath: String? = nil, metadataStore: SessionMetadataStore? = nil) {
    self.dataPath = AntigravitySessionFileScanner.expandedDataPath(
      antigravityDataPath ?? AntigravitySessionFileScanner.defaultDataPath)
    self.metadataStore = metadataStore
  }

  // MARK: - Repository Management

  @discardableResult
  public func addRepository(_ path: String) async -> SelectedRepository? {
    await markInputWorktreeAsOwnedIfNeeded(path)
    let repositoryPath = await normalizedRepositoryPath(for: path)
    guard !selectedRepositories.contains(where: { $0.path == repositoryPath }) else { return nil }

    let worktrees = await detectWorktrees(at: repositoryPath)
    let repository = SelectedRepository(path: repositoryPath, worktrees: worktrees, isExpanded: true)
    selectedRepositories.append(repository)
    await refreshSessions(skipWorktreeRedetection: true)
    return repository
  }

  public func addRepositories(_ paths: [String]) async {
    for path in paths {
      await markInputWorktreeAsOwnedIfNeeded(path)
    }
    let normalizedPaths = await normalizedRepositoryPaths(paths)
    let newPaths = normalizedPaths.filter { path in !selectedRepositories.contains(where: { $0.path == path }) }
    guard !newPaths.isEmpty else { return }

    let allWorktrees = await detectWorktreesBatch(repoPaths: newPaths)
    for path in newPaths {
      selectedRepositories.append(SelectedRepository(path: path, worktrees: allWorktrees[path] ?? [], isExpanded: true))
    }
    await refreshSessions(skipWorktreeRedetection: true)
  }

  public func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] {
    for path in paths {
      await markInputWorktreeAsOwnedIfNeeded(path)
    }
    let uniquePaths = await normalizedRepositoryPaths(paths)
    guard !uniquePaths.isEmpty else {
      selectedRepositories = []
      repositoriesSubject.send([])
      return []
    }
    let allWorktrees = await detectWorktreesBatch(repoPaths: uniquePaths)
    selectedRepositories = uniquePaths.map { path in
      SelectedRepository(path: path, worktrees: allWorktrees[path] ?? [], isExpanded: true)
    }
    repositoriesSubject.send(selectedRepositories)
    return selectedRepositories
  }

  public func removeRepository(_ path: String) async {
    let repositoryPath = await normalizedRepositoryPath(for: path)
    if let repository = selectedRepositories.first(where: { $0.path == repositoryPath }) {
      ownedWorktreePaths.subtract(repository.worktrees.map(\.path))
    }
    ignoredWorktreePathsByRepository.removeValue(forKey: repositoryPath)
    selectedRepositories.removeAll { $0.path == repositoryPath }
    repositoriesSubject.send(selectedRepositories)
  }

  public func setOwnedWorktreePaths(_ paths: Set<String>) async {
    ownedWorktreePaths = Set(paths.map { WorktreeModuleResolver.normalizedDirectoryPath($0) })
  }

  public func setFocusedSessionIds(_ ids: Set<String>) async {
    focusedSessionIds = ids
  }

  public func registerWorktree(_ worktree: WorktreeBranch, parentRepositoryPath: String) async {
    let repositoryPath = await normalizedRepositoryPath(for: parentRepositoryPath)
    let normalizedWorktree = WorktreeBranch(
      name: worktree.name,
      path: WorktreeModuleResolver.normalizedDirectoryPath(worktree.path),
      isWorktree: worktree.isWorktree,
      sessions: worktree.sessions,
      isExpanded: true
    )
    if normalizedWorktree.isWorktree {
      ownedWorktreePaths.insert(normalizedWorktree.path)
      ignoredWorktreePathsByRepository[repositoryPath]?.remove(normalizedWorktree.path)
    }

    if let index = selectedRepositories.firstIndex(where: { $0.path == repositoryPath }) {
      upsertWorktree(normalizedWorktree, inRepositoryAt: index)
      repositoriesSubject.send(selectedRepositories)
      return
    }

    var worktrees = await detectWorktrees(at: repositoryPath)
    if !worktrees.contains(where: { $0.path == normalizedWorktree.path }) {
      worktrees.append(normalizedWorktree)
    }
    selectedRepositories.append(SelectedRepository(path: repositoryPath, worktrees: worktrees, isExpanded: true))
    repositoriesSubject.send(selectedRepositories)
  }

  public func getSelectedRepositories() async -> [SelectedRepository] {
    selectedRepositories
  }

  public func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    selectedRepositories = repositories
    await refreshSessions()
  }

  private func normalizedRepositoryPath(for path: String) async -> String {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    guard let info = await GitWorktreeDetector.detectWorktreeInfo(for: normalizedPath),
      info.isWorktree,
      let mainRepoPath = info.mainRepoPath,
      !mainRepoPath.isEmpty
    else {
      return normalizedPath
    }
    return WorktreeModuleResolver.normalizedDirectoryPath(mainRepoPath)
  }

  private func markInputWorktreeAsOwnedIfNeeded(_ path: String) async {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    guard let info = await GitWorktreeDetector.detectWorktreeInfo(for: normalizedPath), info.isWorktree else { return }
    ownedWorktreePaths.insert(normalizedPath)
  }

  private func normalizedRepositoryPaths(_ paths: [String]) async -> [String] {
    var seen: Set<String> = []
    var normalizedPaths: [String] = []
    for path in paths {
      let normalizedPath = await normalizedRepositoryPath(for: path)
      guard seen.insert(normalizedPath).inserted else { continue }
      normalizedPaths.append(normalizedPath)
    }
    return normalizedPaths
  }

  private func upsertWorktree(_ worktree: WorktreeBranch, inRepositoryAt index: Int) {
    if let worktreeIndex = selectedRepositories[index].worktrees.firstIndex(where: { $0.path == worktree.path }) {
      let existing = selectedRepositories[index].worktrees[worktreeIndex]
      selectedRepositories[index].worktrees[worktreeIndex] = WorktreeBranch(
        name: worktree.name,
        path: worktree.path,
        isWorktree: worktree.isWorktree,
        sessions: worktree.sessions.isEmpty ? existing.sessions : worktree.sessions,
        isExpanded: existing.isExpanded || worktree.isExpanded
      )
    } else {
      selectedRepositories[index].worktrees.append(worktree)
    }
  }

  // MARK: - Session Loading

  public func loadSessions(ids: Set<String>) async -> [CLISession] {
    guard !ids.isEmpty else { return [] }
    var sessions: [CLISession] = []
    for sessionId in ids {
      let path = AntigravitySessionFileScanner.transcriptPath(dataPath: dataPath, conversationId: sessionId)
      guard let meta = AntigravitySessionFileScanner.readSessionMeta(from: path, antigravityDataPath: dataPath) else {
        continue
      }
      sessions.append(makeSession(meta: meta, worktree: worktreeInfo(containing: meta.projectPath)))
    }
    return sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  public func loadLatestSessions(
    inWorktreePath worktreePath: String,
    excludingSessionIds: Set<String>,
    limit: Int
  ) async -> WorktreeSessionImportPage {
    guard limit > 0 else { return WorktreeSessionImportPage(sessions: [], hasMore: false) }

    let normalizedWorktreePath = WorktreeModuleResolver.normalizedDirectoryPath(worktreePath)
    var sessions: [CLISession] = []
    for path in AntigravitySessionFileScanner.listSessionFiles(antigravityDataPath: dataPath) {
      guard let meta = AntigravitySessionFileScanner.readSessionMeta(from: path, antigravityDataPath: dataPath),
        !excludingSessionIds.contains(meta.sessionId)
      else { continue }
      let projectPath = WorktreeModuleResolver.normalizedDirectoryPath(meta.projectPath)
      guard projectPath == normalizedWorktreePath || projectPath.hasPrefix(normalizedWorktreePath + "/") else { continue }
      sessions.append(makeSession(meta: meta, worktree: worktreeInfo(containing: meta.projectPath)))
    }

    sessions.sort {
      if $0.lastActivityAt == $1.lastActivityAt { return $0.id < $1.id }
      return $0.lastActivityAt > $1.lastActivityAt
    }
    return WorktreeSessionImportPage(sessions: Array(sessions.prefix(limit)), hasMore: sessions.count > limit)
  }

  private func makeSession(meta: AntigravitySessionMeta, worktree: (branchName: String?, isWorktree: Bool)) -> CLISession {
    let summary = AntigravitySessionJSONLParser.parseSessionSummaryFile(at: meta.sessionFilePath)
    let lastActivity = [summary.lastActivityAt, meta.startedAt, fileModificationDate(meta.sessionFilePath)]
      .compactMap { $0 }.max()
    return CLISession(
      id: meta.sessionId,
      projectPath: meta.projectPath,
      branchName: worktree.branchName ?? meta.branch,
      isWorktree: worktree.isWorktree,
      lastActivityAt: lastActivity ?? Date(),
      messageCount: summary.messageCount,
      isActive: isSessionFileActive(meta.sessionFilePath),
      firstMessage: summary.firstUserMessage,
      lastMessage: summary.lastUserMessage,
      slug: nil,
      sessionFilePath: meta.sessionFilePath
    )
  }

  // MARK: - Session Scanning

  public func refreshSessions(skipWorktreeRedetection: Bool = false) async {
    guard !selectedRepositories.isEmpty else {
      repositoriesSubject.send([])
      return
    }

    if !skipWorktreeRedetection {
      let allWorktrees = await detectWorktreesBatch(repoPaths: selectedRepositories.map { $0.path })
      for index in selectedRepositories.indices {
        let repoPath = selectedRepositories[index].path
        var merged: [WorktreeBranch] = []
        for detected in allWorktrees[repoPath] ?? [] {
          if var existing = selectedRepositories[index].worktrees.first(where: { $0.path == detected.path }) {
            existing.name = detected.name
            existing.sessions = []
            merged.append(existing)
          } else {
            merged.append(detected)
          }
        }
        selectedRepositories[index].worktrees = merged
      }
    }

    let discoveryScope = makeSessionDiscoveryScope()
    let summaries = AntigravityConversationSummaryIndex.shared.summaries(dataPath: dataPath)
    let sessionMetas = AntigravitySessionFileScanner.listSessionFiles(antigravityDataPath: dataPath)
      .compactMap { AntigravitySessionFileScanner.readSessionMeta(from: $0, antigravityDataPath: dataPath) }
      .filter { discoveryScope.includes(projectPath: $0.projectPath, sessionId: $0.sessionId) }

    var updatedRepositories = selectedRepositories
    var assignedSessionIds: Set<String> = []

    for repoIndex in updatedRepositories.indices {
      let orderedWorktreeIndices = updatedRepositories[repoIndex].worktrees.indices.sorted {
        updatedRepositories[repoIndex].worktrees[$0].path.count > updatedRepositories[repoIndex].worktrees[$1].path.count
      }

      for worktreeIndex in orderedWorktreeIndices {
        let worktree = updatedRepositories[repoIndex].worktrees[worktreeIndex]
        var sessions: [CLISession] = []

        for meta in sessionMetas {
          guard !assignedSessionIds.contains(meta.sessionId) else { continue }
          guard meta.projectPath == worktree.path || meta.projectPath.hasPrefix(worktree.path + "/") else { continue }

          let summary = summaries[meta.sessionId]
          let preview = summary?.preview.trimmingCharacters(in: .whitespacesAndNewlines)
          let lastActivityAt = [summary?.lastModifiedAt, fileModificationDate(meta.sessionFilePath)].compactMap { $0 }.max()

          sessions.append(
            CLISession(
              id: meta.sessionId,
              projectPath: meta.projectPath,
              branchName: worktree.name.isEmpty ? meta.branch : worktree.name,
              isWorktree: worktree.isWorktree,
              lastActivityAt: lastActivityAt ?? meta.startedAt ?? Date(),
              messageCount: summary?.stepCount ?? 0,
              isActive: summary?.runStatus == "CASCADE_RUN_STATUS_RUNNING" || isSessionFileActive(meta.sessionFilePath),
              firstMessage: (preview?.isEmpty == false) ? preview : nil,
              lastMessage: nil,
              slug: (summary?.title.isEmpty == false) ? summary?.title : nil,
              sessionFilePath: meta.sessionFilePath
            ))
          assignedSessionIds.insert(meta.sessionId)
        }

        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        updatedRepositories[repoIndex].worktrees[worktreeIndex].sessions = sessions
      }
    }

    selectedRepositories = updatedRepositories
    repositoriesSubject.send(selectedRepositories)
  }

  // MARK: - Helpers

  private func isSessionFileActive(_ path: String) -> Bool {
    guard let modDate = fileModificationDate(path) else { return false }
    return Date().timeIntervalSince(modDate) < 60
  }

  private func fileModificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  private func worktreeInfo(containing projectPath: String) -> (branchName: String?, isWorktree: Bool) {
    let matchingWorktree = selectedRepositories
      .flatMap(\.worktrees)
      .filter { projectPath == $0.path || projectPath.hasPrefix($0.path + "/") }
      .max { $0.path.count < $1.path.count }
    return (matchingWorktree?.name, matchingWorktree?.isWorktree ?? false)
  }

  // MARK: - Worktree Detection

  private func detectWorktrees(at repoPath: String) async -> [WorktreeBranch] {
    let worktrees = await GitWorktreeDetector.listWorktrees(at: repoPath)
    if worktrees.isEmpty {
      ignoredWorktreePathsByRepository[repoPath] = []
      let info = await GitWorktreeDetector.detectWorktreeInfo(for: repoPath)
      return [WorktreeBranch(name: info?.branch ?? "main", path: repoPath, isWorktree: false, sessions: [])]
    }

    let allWorktrees = worktrees.map { info in
      WorktreeBranch(
        name: info.branch ?? URL(fileURLWithPath: info.path).lastPathComponent,
        path: WorktreeModuleResolver.normalizedDirectoryPath(info.path),
        isWorktree: info.isWorktree,
        sessions: []
      )
    }
    ignoredWorktreePathsByRepository[repoPath] = Set(
      allWorktrees.filter { $0.isWorktree && !ownedWorktreePaths.contains($0.path) }.map(\.path))
    return allWorktrees.filter { !$0.isWorktree || ownedWorktreePaths.contains($0.path) }
  }

  private func detectWorktreesBatch(repoPaths: [String]) async -> [String: [WorktreeBranch]] {
    await withTaskGroup(of: (String, [WorktreeBranch]).self) { group in
      for repoPath in repoPaths {
        group.addTask { (repoPath, await self.detectWorktrees(at: repoPath)) }
      }
      var results: [String: [WorktreeBranch]] = [:]
      for await (path, worktrees) in group {
        results[path] = worktrees
      }
      return results
    }
  }

  private func makeSessionDiscoveryScope() -> SessionDiscoveryScope {
    var repositoryPaths = Set<String>()
    var ownedPaths = Set<String>()
    for repo in selectedRepositories {
      repositoryPaths.insert(repo.path)
      for worktree in repo.worktrees where worktree.isWorktree {
        ownedPaths.insert(worktree.path)
      }
    }
    let ignoredPaths = ignoredWorktreePathsByRepository.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    return SessionDiscoveryScope(
      repositoryPaths: repositoryPaths,
      ownedWorktreePaths: ownedPaths.union(ownedWorktreePaths),
      ignoredWorktreePaths: ignoredPaths,
      focusedSessionIds: focusedSessionIds
    )
  }
}

extension AntigravitySessionMonitorService: SessionMonitorServiceProtocol {}
