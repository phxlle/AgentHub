import Foundation
import Testing

@testable import AgentHubGitHub

@Suite("GitHub Project review service")
struct GitHubProjectReviewServiceTests {
  @Test("OR is its own argument so gh does not quote the query as one phrase")
  func orTerms() {
    #expect(GitHubProjectReviewService.orTerms(["A-1", "A-2", "A-3"]) == ["A-1", "OR", "A-2", "OR", "A-3"])
    #expect(GitHubProjectReviewService.orTerms(["A-1"]) == ["A-1"])
  }

  @Test("Ticket keys match exactly in title or body")
  func ticketKeyMentions() {
    #expect(GitHubProjectReviewService.mentions("XFA-12: fix", key: "XFA-12"))
    #expect(GitHubProjectReviewService.mentions("Fixes xfa-12.", key: "XFA-12"))
    #expect(!GitHubProjectReviewService.mentions("XFA-123: other", key: "XFA-12"))
    #expect(!GitHubProjectReviewService.mentions("AXFA-12", key: "XFA-12"))
  }

  @Test("Ticket pull requests list open ones first, then most recently updated")
  func ticketPullRequestOrder() {
    func pr(_ id: String, _ state: String, _ updated: Double) -> GitHubProjectPullRequest {
      GitHubProjectPullRequest(
        id: id, number: 1, title: id, url: "u", repositoryName: "r", repositoryNameWithOwner: "o/r",
        authorLogin: nil, updatedAt: Date(timeIntervalSince1970: updated), isDraft: false,
        state: state, projectStatus: nil, projectPriority: nil)
    }
    let sorted = GitHubProjectReviewService.sortedForTicket([
      pr("merged-new", "MERGED", 300), pr("open-old", "OPEN", 100), pr("open-new", "open", 200),
    ])
    #expect(sorted.map(\.id) == ["open-new", "open-old", "merged-new"])
  }

  @Test("Rate-limit reset prefers the exhausted bucket")
  func rateLimitResetPrefersExhaustedBucket() {
    let json = """
      {"resources": {
        "core": {"limit": 5000, "remaining": 4900, "reset": 1791400000},
        "graphql": {"limit": 5000, "remaining": 0, "reset": 1791401234},
        "search": {"limit": 30, "remaining": 30, "reset": 1791399000}
      }}
      """
    #expect(
      GitHubProjectReviewService.rateLimitResetDate(fromRateLimitJSON: json)
        == Date(timeIntervalSince1970: 1_791_401_234))
    #expect(GitHubProjectReviewService.rateLimitResetDate(fromRateLimitJSON: "not json") == nil)
  }

  @Test("Project status is separated from the GitHub pull request search")
  func buildsSearchPlan() {
    let plan = GitHubProjectReviewService.searchPlan(
      for: #"is:pr -is:closed -is:merged status:"Code Review 🔎" -is:draft"#
    )

    #expect(plan.query.isEmpty)
    #expect(plan.statusPredicates.count == 1)
    #expect(plan.statusPredicates[0].value == "Code Review 🔎")
    #expect(!plan.statusPredicates[0].isNegated)
    #expect(plan.state == "open")
    #expect(plan.merged == false)
  }

  @Test("Draft PRs are always excluded")
  func alwaysExcludesDrafts() {
    let plan = GitHubProjectReviewService.searchPlan(for: "is:pr label:backend is:draft")

    #expect(plan.query == "label:backend")
  }

  @Test("Decodes open projects and their saved views")
  func decodesProjects() throws {
    let json = #"""
      {
        "data": {
          "viewer": {
            "login": "phxlle",
            "projectsV2": { "nodes": [] },
            "organizations": {
              "nodes": [
                {
                  "login": "gl-ventures",
                  "projectsV2": {
                    "nodes": [
                      {
                        "id": "project-3",
                        "number": 3,
                        "title": "XFA",
                        "url": "https://github.com/orgs/gl-ventures/projects/3",
                        "closed": false,
                        "views": {
                          "nodes": [
                            {
                              "id": "view-48",
                              "number": 48,
                              "name": "Code review",
                              "filter": "is:pr status:\"Code Review 🔎\" -is:draft",
                              "layout": "TABLE_LAYOUT"
                            }
                          ]
                        }
                      },
                      {
                        "id": "closed-project",
                        "number": 9,
                        "title": "Closed",
                        "url": "https://example.com/closed",
                        "closed": true,
                        "views": { "nodes": [] }
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
      """#

    let projects = try GitHubProjectReviewService.decodeProjects(json)

    #expect(projects.count == 1)
    #expect(projects[0].displayName == "gl-ventures / XFA")
    #expect(projects[0].views.first?.name == "Code review")
    #expect(projects[0].views.first?.filter?.contains("Code Review") == true)
  }

  @Test("Decodes the selected project's status and priority for a PR")
  func decodesProjectFields() throws {
    let json = #"""
      {
        "data": {
          "nodes": [
            {
              "id": "pr-1",
              "projectItems": {
                "nodes": [
                  {
                    "project": { "id": "other-project" },
                    "status": { "name": "Done" },
                    "priority": null
                  },
                  {
                    "project": { "id": "project-3" },
                    "status": { "name": "Code Review 🔎" },
                    "priority": { "name": "Urgent ‼️" }
                  }
                ]
              }
            }
          ]
        }
      }
      """#

    let values = try GitHubProjectReviewService.decodeProjectFieldValues(
      json,
      projectID: "project-3"
    )

    #expect(values["pr-1"]?.status == "Code Review 🔎")
    #expect(values["pr-1"]?.priority == "Urgent ‼️")
  }
}
