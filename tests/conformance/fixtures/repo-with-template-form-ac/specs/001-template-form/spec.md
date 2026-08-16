# Feature Specification: Template Form Acceptance Criteria

We need the spec-kit template's own default acceptance-scenario line to
reach the ticket as three distinct clauses, not one stuttered line.

### User Story 1 - Homepage login (Priority: P1)

As a visitor, I want to sign in from the homepage.

**Acceptance Scenarios**:

1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.

### User Story 2 - Wrapped scenario (Priority: P2)

As a visitor, I want the wrapped form of the template's default to read whole too.

**Acceptance Scenarios**:

1. **Given** a user who has been sitting on the homepage for a
   very long while without any interaction at all, **When** they
   finally click the Login button, **Then** the login form appears
   on the screen right away.

### User Story 3 - Unadorned form (Priority: P2)

As a visitor, I want the currently-correct unemphasised form to keep working.

**Acceptance Scenarios**:

1. Given a user arrives on the Homepage, When they click Login, Then the login form appears.

### User Story 4 - Ungrammatical line yields nothing (Priority: P2)

As a visitor, I want a line the grammar cannot read to be silently dropped rather than guessed at.

**Acceptance Scenarios**:

1. Then it opens, When they click, Given a user.
