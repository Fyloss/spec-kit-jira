# Feature Specification: Summary Record Edges Demo
<!-- speckit-jira spec=1111111111111111 ticket=PRSV-1 -->

We need to prove the summary-record decision table's edge rows.

### User Story 1 - Retitled By The Specification (Priority: P1)
<!-- speckit-jira story=2222222222222222 ticket=PRSV-2 -->

As a user, I want a silent retitle when nobody touched the ticket.

- **Given** a mirrored story
- **When** the specification's title changes
- **Then** the retitle lands with no warning

### User Story 2 - Exact Match Title (Priority: P2)
<!-- speckit-jira story=3333333333333333 ticket=PRSV-3 -->

As a user, I want no write when my rename already matches the specification.

- **Given** a mirrored story a human renamed
- **When** the rename matches the specification's title
- **Then** nothing is written and nothing is warned

### User Story 3 - Feature Task Renamed (Priority: P3)
<!-- speckit-jira story=4444444444444444 ticket=PRSV-4 -->

As a user, I want whitespace differences ignored.

- **Given** a recorded summary that differs from the current one only by whitespace
- **When** the specification's title changes
- **Then** the retitle lands with no warning
