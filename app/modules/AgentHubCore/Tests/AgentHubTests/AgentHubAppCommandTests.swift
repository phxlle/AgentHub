import Foundation
import Testing

@testable import AgentHubCore

@Suite("AgentHub app commands")
struct AgentHubAppCommandTests {
  @Test("Workspace selection notifications preserve the requested section")
  func workspaceNotificationRoundTrip() {
    for section in AgentHubWorkspaceSection.allCases {
      let notification = Notification(
        name: AgentHubAppCommand.selectWorkspaceNotification,
        object: section.rawValue
      )

      #expect(AgentHubAppCommand.workspaceSection(from: notification) == section)
    }
  }

  @Test("Invalid workspace selection notifications are ignored")
  func invalidWorkspaceNotification() {
    let notification = Notification(
      name: AgentHubAppCommand.selectWorkspaceNotification,
      object: "Unknown"
    )

    #expect(AgentHubAppCommand.workspaceSection(from: notification) == nil)
  }
}
