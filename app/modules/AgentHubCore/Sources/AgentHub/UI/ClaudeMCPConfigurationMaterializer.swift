//
//  ClaudeMCPConfigurationMaterializer.swift
//  AgentHub
//

import CryptoKit
import Foundation

enum ClaudeMCPConfigurationMaterializer {
  static func materialize(
    arguments: [String],
    directory: URL? = nil,
    fileManager: FileManager = .default
  ) throws -> [String] {
    guard
      let flagIndex = arguments.firstIndex(of: "--mcp-config"),
      arguments.indices.contains(flagIndex + 1)
    else {
      return arguments
    }

    let configuration = arguments[flagIndex + 1]
    guard configuration.first == "{" else {
      return arguments
    }

    let data = Data(configuration.utf8)
    _ = try JSONSerialization.jsonObject(with: data)

    let targetDirectory = directory ?? defaultDirectory(fileManager: fileManager)
    try fileManager.createDirectory(
      at: targetDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: targetDirectory.path
    )

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let configurationURL = targetDirectory.appendingPathComponent(
      "\(digest).json",
      isDirectory: false
    )
    try data.write(to: configurationURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: configurationURL.path
    )

    var materializedArguments = arguments
    materializedArguments[flagIndex + 1] = configurationURL.path
    return materializedArguments
  }

  private static func defaultDirectory(fileManager: FileManager) -> URL {
    fileManager.temporaryDirectory
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("ClaudeMCPConfigurations", isDirectory: true)
  }
}
