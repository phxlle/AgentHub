import Foundation

public struct JiraCLICommandResult: Equatable, Sendable {
  public let standardOutput: Data
  public let standardError: Data
  public let exitCode: Int32

  public init(standardOutput: Data, standardError: Data, exitCode: Int32) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitCode = exitCode
  }
}

public protocol JiraCLICommandRunning: Sendable {
  func run(arguments: [String]) async throws -> JiraCLICommandResult
}

public actor JiraCLIProcessRunner: JiraCLICommandRunning {
  private let executableURL: URL
  private let argumentPrefix: [String]

  public init(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
    argumentPrefix: [String] = ["acli"]
  ) {
    self.executableURL = executableURL
    self.argumentPrefix = argumentPrefix
  }

  public func run(arguments: [String]) async throws -> JiraCLICommandResult {
    let executableURL = executableURL
    let fullArguments = argumentPrefix + arguments
    return try await Task.detached(priority: .userInitiated) {
      try Self.runSynchronously(
        executableURL: executableURL,
        arguments: fullArguments
      )
    }.value
  }

  private nonisolated static func runSynchronously(
    executableURL: URL,
    arguments: [String]
  ) throws -> JiraCLICommandResult {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-jira-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let outputURL = temporaryDirectory.appendingPathComponent("stdout")
    let errorURL = temporaryDirectory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)

    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
      try? outputHandle.close()
      try? errorHandle.close()
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    try process.run()
    process.waitUntilExit()
    try outputHandle.synchronize()
    try errorHandle.synchronize()

    return JiraCLICommandResult(
      standardOutput: try Data(contentsOf: outputURL),
      standardError: try Data(contentsOf: errorURL),
      exitCode: process.terminationStatus
    )
  }
}
