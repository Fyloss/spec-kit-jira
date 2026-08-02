# Feature Specification: Consumer Onboarding

We need a deterministic reconcile bridge that mirrors specs into the consumer's Jira project.

### User Story 1 - Sign up with an email (Priority: P1)

- **Given** a visitor on the sign-up page
- **When** they submit a valid email and password
- **Then** an account is created

### User Story 2 - Verify the email address (Priority: P2)

- **Given** a newly created account
- **When** the visitor clicks the verification link
- **Then** the account is marked verified
