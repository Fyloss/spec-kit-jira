# Feature Specification: Privacy Narrowing Demo
<!-- speckit-jira spec=6666666666666666 ticket=PRSV-1 -->

We need to prove a coordinate the mirror composes itself still blocks the run.

### User Story 1 - Trigger a block on composed content (Priority: P1)
<!-- speckit-jira story=7777777777777777 ticket=PRSV-2 -->

As a user, I want a mirror of https://acme-corp.atlassian.net/browse/PROJ-1 tracked here.

- **Given** a mirrored story
- **When** the mirror composes its own managed region
- **Then** the blocked coordinate still refuses the run
