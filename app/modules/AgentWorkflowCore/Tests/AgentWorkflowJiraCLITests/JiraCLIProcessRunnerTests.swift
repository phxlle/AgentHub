import Foundation
import Testing

@testable import AgentWorkflowJiraCLI

@Suite("Jira CLI process runner")
struct JiraCLIProcessRunnerTests {
  @Test("Finds a Homebrew acli even when the app PATH is the minimal Dock PATH")
  func findsHomebrewACLIWithMinimalPATH() {
    let url = JiraCLIProcessRunner.locateACLI(
      environmentPATH: "/usr/bin:/bin:/usr/sbin:/sbin",
      homeDirectory: "/Users/me",
      isExecutable: { $0 == "/opt/homebrew/bin/acli" }
    )
    #expect(url?.path == "/opt/homebrew/bin/acli")
  }

  @Test("PATH entries win over the standard directories")
  func prefersPATH() {
    let url = JiraCLIProcessRunner.locateACLI(
      environmentPATH: "/custom/bin:/usr/bin",
      homeDirectory: "/Users/me",
      isExecutable: { $0 == "/custom/bin/acli" || $0 == "/opt/homebrew/bin/acli" }
    )
    #expect(url?.path == "/custom/bin/acli")
  }

  @Test("Returns nil when acli is not installed anywhere")
  func notInstalled() {
    #expect(
      JiraCLIProcessRunner.locateACLI(
        environmentPATH: "/usr/bin", homeDirectory: "/Users/me", isExecutable: { _ in false }
      ) == nil)
  }

  @Test("Child PATH gains the standard directories without duplicates")
  func childPATH() {
    let environment = JiraCLIProcessRunner.childEnvironment(
      ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"], homeDirectory: "/Users/me")
    #expect(
      environment["PATH"]
        == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin")
    #expect(environment["HOME"] == "/Users/me")
  }
}

@Suite("Jira CLI timeouts")
struct JiraCLITimeoutTests {
  @Test("Commands time out after a minute; the browser login gets five")
  func timeouts() {
    #expect(JiraCLIProcessRunner.timeout(for: ["jira", "workitem", "search"]) == 60)
    #expect(JiraCLIProcessRunner.timeout(for: ["jira", "auth", "login", "--web"]) == 300)
  }
}
