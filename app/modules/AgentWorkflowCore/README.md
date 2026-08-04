# AgentWorkflowCore

Provider-neutral workflow and policy layer for local agent orchestration.

## Invariants

- Every ticket has one non-writing coordinator.
- Every branch run has exactly one implementer and one reviewer.
- The reviewer has no workspace-write or test-execution capability.
- A review is bound to the tested diff hash.
- A branch gets at most two automated review cycles.
- Commit, push, and draft pull request actions require a diff-bound human approval.
- Workflow events are append-only.

## Products

- `AgentWorkflowCore`: domain models, state machine, approvals, and SQLite persistence.
- `AgentWorkflowJiraCLI`: read-only Jira ticket lookup through `acli jira workitem view`.

The package deliberately does not launch agents or perform Git and GitHub mutations. Those actions
belong in provider adapters and a privileged action broker in AgentHubCore.
