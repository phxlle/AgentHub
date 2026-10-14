//
//  GitHubRemoteOwner.swift
//  AgentHub
//
//  The GitHub owner (org or user) of a local checkout, read from its `origin`
//  remote in `.git/config`. Used to scope ticket → pull request searches.
//

import Foundation

enum GitHubRemoteOwner {
  static func owner(ofRepositoryAt path: String) -> String? {
    let config = URL(fileURLWithPath: path).appendingPathComponent(".git/config")
    guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
    return owner(fromGitConfig: text)
  }

  /// Owner from the `[remote "origin"]` url: `git@github.com:owner/repo.git`
  /// or `https://github.com/owner/repo.git`.
  static func owner(fromGitConfig text: String) -> String? {
    var inOrigin = false
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        inOrigin = line == "[remote \"origin\"]"
        continue
      }
      guard inOrigin, line.hasPrefix("url") else { continue }
      guard let range = line.range(of: "github.com") else { return nil }
      let rest = line[range.upperBound...].drop { $0 == ":" || $0 == "/" }
      let owner = rest.split(separator: "/").first.map(String.init)
      return owner?.isEmpty == false ? owner : nil
    }
    return nil
  }
}
