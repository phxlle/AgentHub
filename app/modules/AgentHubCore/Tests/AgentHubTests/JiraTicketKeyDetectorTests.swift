import Foundation
import Testing

@testable import AgentHubCore

@Suite("Jira ticket key detection for sessions")
struct JiraTicketKeyDetectorTests {
  private let known: Set<String> = ["XFA"]

  @Test("Branch names starting with a known project key link to the ticket")
  func branchNames() {
    #expect(keys(branch: "codex/xfa-3515-guide-routing") == ["XFA-3515"])
    #expect(keys(branch: "XFA-12") == ["XFA-12"])
    #expect(keys(branch: "release-2").isEmpty)
    #expect(keys(branch: "main").isEmpty)
  }

  @Test("Unknown project prefixes in branches are ignored")
  func unknownPrefixes() {
    #expect(keys(branch: "feature/abc-12-thing").isEmpty)
  }

  @Test("Browse URLs and the pick-up prompt always count")
  func explicitReferences() {
    #expect(keys(prompt: "Check https://xfatech.atlassian.net/browse/XFA-2516 please") == ["XFA-2516"])
    #expect(keys(prompt: "Pick up Jira ticket COM-7: Do it") == ["COM-7"])
    #expect(keys(prompt: "Fix the UTF-8 bug").isEmpty)
  }

  @Test("Custom names starting with a key link; duplicates collapse")
  func customNames() {
    #expect(
      JiraTicketKeyDetector.keys(
        branchName: "xfa-9-login",
        customName: "XFA-9 login fix",
        prompt: "Pick up Jira ticket XFA-9: Login",
        knownProjectKeys: known
      ) == ["XFA-9"])
  }

  private func keys(branch: String? = nil, prompt: String? = nil) -> [String] {
    JiraTicketKeyDetector.keys(
      branchName: branch, customName: nil, prompt: prompt, knownProjectKeys: known)
  }
}

@Suite("GitHub remote owner")
struct GitHubRemoteOwnerTests {
  @Test("Reads the owner from SSH and HTTPS origin remotes only")
  func owner() {
    let ssh = """
      [core]
      \tbare = false
      [remote "upstream"]
      \turl = git@github.com:someone-else/repo.git
      [remote "origin"]
      \turl = git@github.com:gl-ventures/xfa-api.git
      """
    #expect(GitHubRemoteOwner.owner(fromGitConfig: ssh) == "gl-ventures")
    #expect(
      GitHubRemoteOwner.owner(
        fromGitConfig: "[remote \"origin\"]\n\turl = https://github.com/phxlle/AgentHub.git") == "phxlle")
    #expect(
      GitHubRemoteOwner.owner(fromGitConfig: "[remote \"origin\"]\n\turl = https://gitlab.com/x/y.git") == nil)
  }
}
