//
//  SessionFolderDiscovery.swift
//  AgentHub
//

import Foundation

struct SessionFolderSelection: Equatable, Sendable {
  let rootPath: String
  let repositoryPaths: [String]
  let isFolderGroup: Bool
}

/// Resolves a folder chosen in Sessions without recursively walking an entire
/// source tree. Git repositories keep their existing single-repository
/// behavior. A non-repository folder becomes a group whose direct, visible
/// child directories are monitored independently.
enum SessionFolderDiscovery {
  static func selection(at path: String) async -> SessionFolderSelection {
    let rootPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    if await GitWorktreeDetector.detectWorktreeInfo(for: rootPath) != nil {
      return SessionFolderSelection(
        rootPath: rootPath,
        repositoryPaths: [rootPath],
        isFolderGroup: false
      )
    }

    let childPaths = await Task.detached(priority: .userInitiated) {
      directChildDirectoryPaths(at: rootPath)
    }.value

    guard !childPaths.isEmpty else {
      return SessionFolderSelection(
        rootPath: rootPath,
        repositoryPaths: [rootPath],
        isFolderGroup: false
      )
    }

    return SessionFolderSelection(
      rootPath: rootPath,
      repositoryPaths: childPaths,
      isFolderGroup: true
    )
  }

  static func directChildDirectoryPaths(
    at rootPath: String,
    fileManager: FileManager = .default
  ) -> [String] {
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey,
      .isHiddenKey,
      .isPackageKey,
      .isSymbolicLinkKey,
    ]
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return children.compactMap { url -> String? in
      guard let values = try? url.resourceValues(forKeys: keys),
        values.isDirectory == true,
        values.isHidden != true,
        values.isPackage != true,
        values.isSymbolicLink != true
      else {
        return nil
      }
      let childPath = rootURL.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
        .path
      return WorktreeModuleResolver.normalizedDirectoryPath(childPath)
    }
    .sorted { lhs, rhs in
      URL(fileURLWithPath: lhs).lastPathComponent.localizedStandardCompare(
        URL(fileURLWithPath: rhs).lastPathComponent
      ) == .orderedAscending
    }
  }

  static func isDirectChild(_ path: String, of rootPath: String) -> Bool {
    let pathURL = URL(
      fileURLWithPath: WorktreeModuleResolver.normalizedDirectoryPath(path),
      isDirectory: true
    )
    let rootURL = URL(
      fileURLWithPath: WorktreeModuleResolver.normalizedDirectoryPath(rootPath),
      isDirectory: true
    )
    return pathURL.deletingLastPathComponent().standardizedFileURL.path
      == rootURL.standardizedFileURL.path
  }
}
