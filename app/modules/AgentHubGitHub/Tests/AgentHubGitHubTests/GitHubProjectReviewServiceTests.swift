import Foundation
import Testing

@testable import AgentHubGitHub

@Suite("GitHub Project review service")
struct GitHubProjectReviewServiceTests {
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

  @Test("Decodes the selected project's status for a PR")
  func decodesProjectStatus() throws {
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
                    "fieldValueByName": { "name": "Done" }
                  },
                  {
                    "project": { "id": "project-3" },
                    "fieldValueByName": { "name": "Code Review 🔎" }
                  }
                ]
              }
            }
          ]
        }
      }
      """#

    let statuses = try GitHubProjectReviewService.decodeProjectStatuses(
      json,
      projectID: "project-3"
    )

    #expect(statuses["pr-1"] == "Code Review 🔎")
  }
}
