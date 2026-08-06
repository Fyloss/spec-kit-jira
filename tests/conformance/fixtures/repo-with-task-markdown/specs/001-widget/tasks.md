# Tasks: Widget Management

Every task line below carries the markup a real spec-kit tasks.md carries.
Feature 012 shipped these straight through to the Jira reader as literal
punctuation; feature 016 FR-017 renders them.

## Phase 1: Setup

- [ ] T001 Scaffold the project under `src/widget/` before anything else

## Phase 2: Foundational

- [ ] T002 Wire the data store in `src/widget/store.ts`

## Phase 3: User Story 1

- [ ] T003 [US1] Implement the **create** endpoint in `src/widget/create.ts`
- [ ] T004 [US1] Reject a duplicate slug with `409 Conflict`, per the
      [API guide](https://example.invalid/api/widgets)
- [ ] T005 [US1] Drop the ~~legacy~~ validation path and its `*.bak` files

## Phase 4: User Story 2

- [ ] T006 [US2] Implement the *rename* endpoint (depends on T003)
- [x] T007 [US2] Add rename validation in `src/widget/rename.ts`

## Phase 5: User Story 3

- [ ] T008 [US3] Handle an unbalanced ** delimiter and a lone [bracket( safely
- [ ] T009 [US3] Escape a literal \*not bold\* and a `mailto:ops@example.invalid`
      target that must never become a live link

## Phase 6: Polish

- [ ] T010 Update `docs/widgets.md` with the accented café and 日本語 sections
