import Foundation

actor AgentSessionTranscriptEvidenceReader {
  private struct CachedEvidence {
    let modificationDate: Date?
    let fileSize: UInt64
    let text: String
  }

  private struct FileMetadata: Sendable {
    let modificationDate: Date?
    let fileSize: UInt64
  }

  private var cache: [String: CachedEvidence] = [:]

  func enrich(_ observations: [AgentSessionObservation]) async -> [AgentSessionObservation] {
    await withTaskGroup(
      of: (Int, String?).self,
      returning: [AgentSessionObservation].self
    ) { group in
      for (index, observation) in observations.enumerated() {
        guard shouldReadTranscript(for: observation),
          let path = observation.session.sessionFilePath,
          !path.isEmpty
        else {
          continue
        }
        group.addTask {
          (index, await self.evidence(at: path))
        }
      }

      var evidenceByIndex: [Int: String] = [:]
      for await (index, evidence) in group {
        if let evidence, !evidence.isEmpty {
          evidenceByIndex[index] = evidence
        }
      }

      return observations.enumerated().map { index, observation in
        guard let evidence = evidenceByIndex[index] else { return observation }
        let transcriptLinks = AgentSessionWorkflowClassifier.pullRequestReferences(in: [evidence])
        let links = Array(Set(observation.linkedPullRequests + transcriptLinks))
          .sorted { $0.number < $1.number }
        return AgentSessionObservation(
          session: observation.session,
          provider: observation.provider,
          repositoryPath: observation.repositoryPath,
          branchName: observation.branchName,
          linkedPullRequests: links,
          transcriptEvidence: evidence
        )
      }
    }
  }

  private func shouldReadTranscript(for observation: AgentSessionObservation) -> Bool {
    let ticketKey = AgentSessionWorkflowClassifier.ticketKey(
      in: [
        observation.branchName,
        observation.session.firstMessage,
        observation.session.lastMessage,
        observation.session.slug,
      ]
    )
    guard ticketKey == nil, observation.linkedPullRequests.isEmpty else {
      return false
    }
    let recentCutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
    return observation.session.isActive || observation.session.lastActivityAt >= recentCutoff
  }

  private func evidence(at path: String) async -> String? {
    guard
      let metadata = await Task.detached(
        priority: .utility,
        operation: {
          Self.readMetadata(at: path)
        }
      ).value
    else {
      return nil
    }

    if let cached = cache[path],
      cached.modificationDate == metadata.modificationDate,
      cached.fileSize == metadata.fileSize
    {
      return cached.text
    }
    guard
      let text = await Task.detached(
        priority: .utility,
        operation: {
          Self.readEvidence(at: path, fileSize: metadata.fileSize)
        }
      ).value
    else {
      return nil
    }
    cache[path] = CachedEvidence(
      modificationDate: metadata.modificationDate,
      fileSize: metadata.fileSize,
      text: text
    )
    return text
  }

  private nonisolated static func readMetadata(at path: String) -> FileMetadata? {
    let fileManager = FileManager.default
    guard let attributes = try? fileManager.attributesOfItem(atPath: path),
      let fileSizeNumber = attributes[.size] as? NSNumber
    else {
      return nil
    }
    return FileMetadata(
      modificationDate: attributes[.modificationDate] as? Date,
      fileSize: fileSizeNumber.uint64Value
    )
  }

  private nonisolated static func readEvidence(at path: String, fileSize: UInt64) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }

    let leadingByteCount = 128 * 1_024
    let trailingByteCount = 256 * 1_024
    var data = (try? handle.read(upToCount: leadingByteCount)) ?? Data()
    if fileSize > UInt64(leadingByteCount + trailingByteCount) {
      try? handle.seek(toOffset: fileSize - UInt64(trailingByteCount))
      if let trailingData = try? handle.read(upToCount: trailingByteCount) {
        data.append(trailingData)
      }
    } else if fileSize > UInt64(leadingByteCount),
      let remainingData = try? handle.readToEnd()
    {
      data.append(remainingData)
    }

    return String(decoding: data, as: UTF8.self)
  }
}
