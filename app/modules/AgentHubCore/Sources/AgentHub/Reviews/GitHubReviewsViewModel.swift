//
//  GitHubReviewsViewModel.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation
import Observation

@MainActor
@Observable
public final class GitHubReviewsViewModel {
  private enum DefaultsKey {
    static let projectID = "agenthub.reviews.github-project-id"
    static let viewID = "agenthub.reviews.github-project-view-id"
  }

  private let service: any GitHubProjectReviewServiceProtocol
  private let defaults: UserDefaults
  private var didLoad = false
  private var refreshGeneration = 0

  public private(set) var projects: [GitHubReviewProject] = []
  public private(set) var selectedProjectID: String?
  public private(set) var selectedViewID: String?
  public private(set) var pullRequests: [GitHubProjectPullRequest] = []
  public private(set) var isLoadingProjects = false
  public private(set) var isLoadingPullRequests = false
  public private(set) var errorMessage: String?

  public init(
    service: any GitHubProjectReviewServiceProtocol,
    userDefaults: UserDefaults = .standard
  ) {
    self.service = service
    defaults = userDefaults
    selectedProjectID = userDefaults.string(forKey: DefaultsKey.projectID)
    selectedViewID = userDefaults.string(forKey: DefaultsKey.viewID)
  }

  public var selectedProject: GitHubReviewProject? {
    projects.first { $0.id == selectedProjectID }
  }

  public var availableViews: [GitHubProjectView] {
    selectedProject?.views ?? []
  }

  public var selectedView: GitHubProjectView? {
    availableViews.first { $0.id == selectedViewID }
  }

  public var activeFilter: String {
    selectedView?.filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  public func load() async {
    guard !didLoad else { return }
    didLoad = true
    await loadProjects()
  }

  public func reloadProjects() async {
    await loadProjects()
  }

  public func selectProject(id: String) {
    guard selectedProjectID != id, projects.contains(where: { $0.id == id }) else { return }
    selectedProjectID = id
    defaults.set(id, forKey: DefaultsKey.projectID)
    selectedViewID = preferredView(in: selectedProject)?.id
    persistSelectedView()
    pullRequests = []
    Task { await refreshPullRequests() }
  }

  public func selectView(id: String) {
    guard selectedViewID != id, availableViews.contains(where: { $0.id == id }) else { return }
    selectedViewID = id
    persistSelectedView()
    pullRequests = []
    Task { await refreshPullRequests() }
  }

  public func refreshPullRequests() async {
    guard let project = selectedProject, let view = selectedView else {
      pullRequests = []
      return
    }

    refreshGeneration += 1
    let generation = refreshGeneration
    isLoadingPullRequests = true
    errorMessage = nil
    do {
      let requests = try await service.listPullRequests(
        project: project,
        view: view,
        limit: 1_000
      )
      guard generation == refreshGeneration,
        selectedProjectID == project.id,
        selectedViewID == view.id
      else { return }
      pullRequests = requests.filter { !$0.isDraft }
      isLoadingPullRequests = false
    } catch {
      guard generation == refreshGeneration else { return }
      pullRequests = []
      isLoadingPullRequests = false
      errorMessage = error.localizedDescription
    }
  }

  public func presentLaunchError(_ message: String) {
    errorMessage = message
  }

  private func loadProjects() async {
    isLoadingProjects = true
    errorMessage = nil
    do {
      projects = try await service.listProjects()
      normalizeSelection()
      isLoadingProjects = false
      await refreshPullRequests()
    } catch {
      projects = []
      pullRequests = []
      isLoadingProjects = false
      errorMessage = error.localizedDescription
    }
  }

  private func normalizeSelection() {
    if !projects.contains(where: { $0.id == selectedProjectID }) {
      selectedProjectID =
        projects.first {
          $0.views.contains {
            $0.name.localizedCaseInsensitiveContains("code review")
          }
        }?.id ?? projects.first?.id
    }
    if !availableViews.contains(where: { $0.id == selectedViewID }) {
      selectedViewID = preferredView(in: selectedProject)?.id
    }
    if let selectedProjectID {
      defaults.set(selectedProjectID, forKey: DefaultsKey.projectID)
    }
    persistSelectedView()
  }

  private func preferredView(in project: GitHubReviewProject?) -> GitHubProjectView? {
    guard let project else { return nil }
    return project.views.first {
      $0.name.localizedCaseInsensitiveContains("code review")
    } ?? project.views.first {
      let filter = $0.filter?.lowercased() ?? ""
      return filter.contains("is:pr") && filter.contains("status:")
    } ?? project.views.first {
      $0.filter?.localizedCaseInsensitiveContains("is:pr") == true
    } ?? project.views.first
  }

  private func persistSelectedView() {
    if let selectedViewID {
      defaults.set(selectedViewID, forKey: DefaultsKey.viewID)
    } else {
      defaults.removeObject(forKey: DefaultsKey.viewID)
    }
  }
}
