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
  private let executableURL: URL?
  private let argumentPrefix: [String]

  /// With no executable, `acli` is located on run. Apps launched from the Dock or
  /// a shortcut get `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so `/usr/bin/env acli`
  /// would miss a Homebrew install.
  public init(executableURL: URL? = nil, argumentPrefix: [String] = []) {
    self.executableURL = executableURL
    self.argumentPrefix = argumentPrefix
  }

  public func run(arguments: [String]) async throws -> JiraCLICommandResult {
    guard
      let executableURL = executableURL
        ?? Self.locateACLI(
          environmentPATH: ProcessInfo.processInfo.environment["PATH"],
          homeDirectory: NSHomeDirectory())
    else {
      throw JiraTicketReaderError.commandFailed(
        exitCode: 127,
        message: "The Atlassian CLI (acli) was not found. Install it with `brew install acli`."
      )
    }
    let fullArguments = argumentPrefix + arguments
    return try await Task.detached(priority: .userInitiated) {
      try Self.runSynchronously(
        executableURL: executableURL,
        arguments: fullArguments
      )
    }.value
  }

  /// Directories searched besides `PATH`, in order.
  static func standardDirectories(homeDirectory: String) -> [String] {
    ["/opt/homebrew/bin", "/usr/local/bin", "\(homeDirectory)/.local/bin", "/usr/bin"]
  }

  static func locateACLI(
    environmentPATH: String?,
    homeDirectory: String,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> URL? {
    let pathDirectories = (environmentPATH ?? "").split(separator: ":").map(String.init)
    for directory in pathDirectories + standardDirectories(homeDirectory: homeDirectory) {
      let candidate = (directory as NSString).appendingPathComponent("acli")
      if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
    }
    return nil
  }

  /// The child's PATH also gets the standard directories, for anything acli spawns.
  static func childEnvironment(
    _ environment: [String: String],
    homeDirectory: String
  ) -> [String: String] {
    var environment = environment
    let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let extra = standardDirectories(homeDirectory: homeDirectory).filter { !existing.contains($0) }
    environment["PATH"] = (existing + extra).joined(separator: ":")
    return environment
  }

  /// The browser login waits for the user, so it gets longer.
  static func timeout(for arguments: [String]) -> TimeInterval {
    arguments.starts(with: ["jira", "auth", "login"]) ? 300 : 60
  }

  private nonisolated static func runSynchronously(
    executableURL: URL,
    arguments: [String]
  ) throws -> JiraCLICommandResult {
    let timeout = timeout(for: Array(arguments.drop { $0 != "jira" }))
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
    process.environment = childEnvironment(
      ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory())
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    try process.run()
    // Bounded wait instead of `waitUntilExit()`, which never returns when another
    // part of the host app reaps the child (embedded terminals do).
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      throw JiraTicketReaderError.commandFailed(
        exitCode: -1, message: "acli did not respond within \(Int(timeout)) seconds")
    }
    try outputHandle.synchronize()
    try errorHandle.synchronize()

    return JiraCLICommandResult(
      standardOutput: try Data(contentsOf: outputURL),
      standardError: try Data(contentsOf: errorURL),
      exitCode: process.terminationStatus
    )
  }
}
