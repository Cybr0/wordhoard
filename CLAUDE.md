# Wordhoard — project conventions

Read this before touching anything. `docs/requirements.md` says *what* we build and why; `docs/plan.md` says *in what order*; this file says *how*.

## What this is

A personal English vocabulary app for iPhone (iOS 26+). On-device only: SwiftUI, SwiftData, Foundation Models for card autofill, Image Playground for pictures, App Intents for Siri. No backend, no network calls, no analytics. See `docs/requirements.md` §1 and §11 before proposing anything that needs a server, a subscription, a web client, or another learning language — those were considered and deferred on purpose.

## Repository layout

```
Wordhoard/            app target — SwiftUI views, App Intents, DI wiring only
WordhoardCore/        Swift package — models, services, grammar catalog; no UI imports
WordhoardCore/Tests/  unit tests (Swift Testing); the bulk of all tests live here
WordhoardUITests/     a few critical end-to-end flows only
docs/requirements.md  product requirements (owned by the analyst agent)
docs/plan.md          phased plan with acceptance criteria and issue links
docs/decisions/       ADRs — one short file per decision, numbered
project.yml           XcodeGen spec; the .xcodeproj is generated, never hand-edited
```

Rule of thumb: if it can be unit-tested without a simulator, it belongs in `WordhoardCore`.

## Tooling

- Xcode project is generated: `xcodegen generate`. Never edit `Wordhoard.xcodeproj` by hand; edit `project.yml`. The `.xcodeproj` is committed so the project opens without XcodeGen installed, but regenerate after any `project.yml` change.
- Build: `xcodebuild -scheme Wordhoard -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Core tests (fast, no simulator): `cd WordhoardCore && swift test`
- All tests: `xcodebuild -scheme Wordhoard -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
- Format: `swiftformat .` (config in `.swiftformat`), lint: `swiftlint`. Run both before opening a PR.
- Adjust the simulator name to whatever `xcrun simctl list devices available` shows if the above is missing.

## Code conventions

- Swift 6 language mode, strict concurrency. Fix warnings; do not silence them with `@unchecked Sendable` or `nonisolated(unsafe)` without an ADR.
- SwiftUI + `@Observable` view models. No Combine, no third-party architecture frameworks.
- Services are protocols with one production implementation and one test double:
  - `CardGenerator` → `FoundationModelsCardGenerator` / `StubCardGenerator`
  - `ImageGenerator` → `ImagePlaygroundGenerator` / `StubImageGenerator`
  - `WordStore` wraps SwiftData; views never touch `ModelContext` directly.
- Every AI call checks availability first and has a non-AI fallback path. A device without Apple Intelligence must be able to use every screen.
- Generated fields carry provenance (`FieldSource.auto` / `.user`). Regeneration must never overwrite a `.user` field. This is tested.
- IDs are client-generated `UUID`s. Deletion is soft (`deletedAt`). Review events are append-only. These keep CloudKit sync possible later; do not "simplify" them away.
- Grammar topic keys are namespaced strings, `en.present_perfect`. The catalog is a JSON resource in `WordhoardCore`, not Swift enums, so it can grow without code changes.
- Prompts for the language model live in one place: `WordhoardCore/Sources/WordhoardCore/Services/Prompts/`. Changing a prompt means re-running the regression word list (`docs/regression-words.md`) and noting results in the PR.
- No force unwraps outside tests. No `print` in production code; use `os.Logger` with the `Wordhoard` subsystem.
- User-facing strings go through String Catalogs (`Localizable.xcstrings`), even though v1 ships English only.

## Testing conventions

- Swift Testing (`@Test`, `#expect`, `#require`), not XCTest, for new tests.
- Unit tests use in-memory SwiftData containers (`ModelConfiguration(isStoredInMemoryOnly: true)`) and the stub generators. Tests never call the real Foundation Models or Image Playground APIs.
- Name tests by behaviour: `@Test("adding a word that differs only by case opens the existing card")`.
- Every bug fix comes with a test that failed before the fix.
- UI tests are reserved for: add a word → see card; Siri intent → word appears; export → import round-trip.

## Git and PRs

- Branch per plan task: `phase-2/autofill-service`, `fix/duplicate-case-folding`.
- Commits: imperative subject ≤ 72 chars, body explains *why*. Reference the issue: `Closes #12`.
- One PR per plan task, small enough to review in ten minutes. PR description lists which acceptance criteria from `docs/plan.md` it satisfies and how it was verified (device or simulator, which iOS).
- `main` always builds and passes `swift test`.
- Do not commit: `xcuserdata`, provisioning profiles, API keys (there should be none), screenshots of the author's own word list.

## Working with the agents

Five agents are defined in `.claude/agents/`:

| Agent | Edits | Job |
|---|---|---|
| `analyst` | `docs/` only | Acceptance criteria before work starts; keeps requirements, plan and ADRs consistent; pushes back on scope creep via `requirements.md` §11; settles disputes about intended behaviour. |
| `ios-developer` | app and test code, `project.yml` | Implements one plan task on its own branch, with unit tests, and opens the PR. |
| `reviewer` | nothing | Reviews the *code* in a PR: concurrency, SwiftData, AI fallbacks, conventions, test quality. Posts a review with file:line findings. |
| `qa` | tests, plan checkboxes | Verifies the *behaviour*: runs the suite, walks every acceptance criterion, hunts edge cases, adds tests, posts a report. |
| `fixer` | the PR's branch | Addresses reviewer/qa/CI findings on an open PR, one commit per finding, replies in each thread. Does not widen the task. |

Typical flow for a task:

```
analyst confirms criteria
  → ios-developer implements, opens PR
  → reviewer reviews code   ┐  (can run in parallel)
  → qa verifies behaviour   ┘
  → fixer addresses findings, asks for re-check
  → reviewer / qa re-check → merge → qa ticks the plan
```

`reviewer` and `qa` are deliberately separate: one reads the diff, the other runs the app. `fixer` is separate from `ios-developer` so that "address review comments" stays a narrow, auditable step rather than a second round of feature work. If `fixer` and a reviewer disagree about intended behaviour, the `analyst` decides by reference to requirements and records the answer.

## Things that look like good ideas but are not (yet)

- Adding a backend "just for sync" — use CloudKit when the time comes (plan v2).
- Calling a cloud LLM because the on-device one is weak on some word — note the word in `docs/regression-words.md`, improve the prompt, keep the `CardGenerator` protocol so a cloud implementation can be added later as a user choice.
- Turning the grammar catalog into a Swift enum.
- Storing images as `Data` blobs in SwiftData — they are files in the app container, referenced by name.
- Hand-editing the `.xcodeproj`.
