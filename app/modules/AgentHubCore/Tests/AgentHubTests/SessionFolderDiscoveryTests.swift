import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session folder discovery")
struct SessionFolderDiscoveryTests {
  @Test("Discovers visible directories exactly one level below the selected folder")
  func discoversExactlyOneLevel() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appending(
        path: "agenthub-folder-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: root) }

    let alpha = root.appending(path: "Alpha", directoryHint: .isDirectory)
    let beta = root.appending(path: "Beta", directoryHint: .isDirectory)
    let grandchild = alpha.appending(path: "Nested", directoryHint: .isDirectory)
    let hidden = root.appending(path: ".hidden", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: grandchild, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: beta, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: hidden, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: root.appending(path: "README.md"))

    let paths = SessionFolderDiscovery.directChildDirectoryPaths(at: root.path)

    #expect(
      paths == [
        WorktreeModuleResolver.normalizedDirectoryPath(alpha.path),
        WorktreeModuleResolver.normalizedDirectoryPath(beta.path),
      ])
    #expect(!paths.contains(WorktreeModuleResolver.normalizedDirectoryPath(grandchild.path)))
  }

  @Test("Direct child matching rejects grandchildren and prefix collisions")
  func directChildMatchingIsComponentAware() {
    #expect(SessionFolderDiscovery.isDirectChild("/tmp/Projects/App", of: "/tmp/Projects"))
    #expect(!SessionFolderDiscovery.isDirectChild("/tmp/Projects/App/Sources", of: "/tmp/Projects"))
    #expect(!SessionFolderDiscovery.isDirectChild("/tmp/Projects-Old/App", of: "/tmp/Projects"))
  }
}
