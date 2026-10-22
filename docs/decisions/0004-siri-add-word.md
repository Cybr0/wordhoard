# 0004 — Add a word with Siri through one App Intent

Date: 2026-10-23 · Status: proposed (Russian Siri recognition and free-team signing wait for the owner's #6 and #7 tables)

## Context

C2 asks for "Hey Siri, add a word to Wordhoard". Phase 0 did not run the Siri checks (§10 Q3: does Siri catch an English word when Siri's language is Russian, and is the two-step dialog acceptable?) or the App Intents part of the free-team signing check (§10 Q7) (#6, #7, ADR 0001). Plan 5.1 built the intent in PR #63. Real Siri cannot run on the simulator or in a UI test, so only the in-process path is verified.

## Decision

The app target has one `AddWordIntent`. Its single free-text `word` parameter is asked for with "Which word?". The word cannot be part of the trigger phrase, because App Shortcut parameters must be entities, so the two-step dialog is the design. `openAppWhenRun = false`. `perform()` runs on the main actor and saves through `WordStore.add` on the shared `AppDependencies.shared`. The intent runs in the app process, so there is no app group, no extension and no entitlement. Replies: "Added “book” to your hoard." / "“book” is already in your hoard." (C4). A blank word asks again. Any other failure says "Couldn't save the word." The intent starts no work. Autofill fills the word on the next `.active` through the 2.3 queue (C5), and the list reloads on `.active`. When `autoGenerateImages` is on, a created word is marked `imageStatus = .pending`, so the foreground resume draws its picture (I3; ruling on #49). One App Shortcut carries exactly two **English-only** phrases: "Add a word to Wordhoard" and "Save a word in Wordhoard". v1's UI is English only (§6 Localization).

## Consequences

- Easier: no second target or shared container. A Debug hook (`--ui-testing-add-word`) runs the real `perform()` in a UI test.
- Harder: a word added while the app is closed is filled, and gets its picture, only when the user next opens the app. The two-step dialog is slower than one sentence. With Russian Siri the English trigger may not be recognised at all.
- Pending, decided by the tables: the recognition rate for the 10 words with English Siri and with Russian Siri, whether "Wordhoard" is mangled, whether the two-step dialog is acceptable, and whether the App Shortcut runs under the free personal team. If Russian Siri misses the trigger, the options are: keep Siri in English, run the shortcut from the Shortcuts app, or add Russian phrases together with the Russian UI (§8 Later). Choose then.
- Revisit: when #6 and #7 are posted (set the status to accepted; answer §10 Q3 and Q7). Also revisit when the share extension (C3, v1.1, #42) needs an app group, which would let both capture paths share a queue file.
