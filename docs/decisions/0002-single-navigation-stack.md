# 0002 — One navigation stack with typed routes; no tab bar in v1

Date: 2026-10-21 · Status: accepted (2026-10-23; the code follows it since PR #62, and PR #63's Settings and onboarding sheets keep to it)

## Context

Phase 3 added three screens (topics settings, topics browse, a topic's examples), and the plan's literal text said "Topics tab". The word list was one `NavigationStack` whose path was `[Word]` (1.5), so a non-word screen could not be pushed. 5.3 (#45) had already chosen a sheet with its own stack for Settings for that reason. A `TabView` would need a second stack for topics, move the add field's home and duplicate the card destination. The question: how do new screens join the app's navigation for the rest of v1?

## Decision

The app keeps **one `NavigationStack` on the word list** with a typed path `[Route]` (`enum Route: Hashable { case word(Word), topicSettings, topics, topic(GrammarTopicID) }`, app target). Every full-screen destination is a `Route` case handled by one `.navigationDestination(for: Route.self)`. Screens that need their own stack and a Done button are sheets: Settings (5.3), with its own typed `SettingsRoute`, and onboarding (5.2). No `TabView` in v1. `NavigationPath` is not used because it is not `Equatable`, and the list relies on `onChange(of: path)` to reload when the stack unwinds.

## Consequences

- Easier: a card can be reached from the list, from a topic and later from Siri or a widget by appending one value. Back always returns to where the user came from. Screens do not depend on how they are presented: the topics screen is pushed on the list's stack (from Topics → Choose topics) and inside the Settings sheet without change.
- Harder: there is no persistent second tab for Topics, so browse is one tap behind a toolbar button. A deep stack (list → card → topic → card) is possible and accepted.
- Revisit: when the app gains a learning mode (v2 flashcards, plan "Later"), a tab bar is the natural home for "Words / Topics / Review". `Route` and the screens move unchanged. Decide then, not before.
