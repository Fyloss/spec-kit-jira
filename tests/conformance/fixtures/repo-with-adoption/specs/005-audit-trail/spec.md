# Feature Specification: Audit Trail

Every privileged action is recorded so a reviewer can reconstruct what happened.

### User Story 1 - Record a privileged action (Priority: P2)

- **Given** an administrator changing a permission
- **When** the change is saved
- **Then** the audit trail carries the actor and the change
