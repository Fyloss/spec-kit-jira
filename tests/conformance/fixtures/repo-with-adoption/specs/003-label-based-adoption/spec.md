# Feature Specification: Label-Based Adoption

An operator labels an already-populated backlog so each label names the spec it
belongs to, and the bridge binds those tickets without rewriting a single byte.

### User Story 1 - Adopt a hierarchy discovered by label (Priority: P1)

- **Given** a ticket carrying a spec-naming adoption label
- **When** the operator confirms the adoption plan
- **Then** the ticket carries the spec's identity marker

### User Story 2 - Adoption is fail-closed on ambiguity (Priority: P1)

- **Given** two tickets carrying the same adoption label
- **When** the operator runs adopt
- **Then** the binding is refused with zero writes
