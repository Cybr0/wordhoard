# 0003 — Pictures from Image Playground, on by default for now

Date: 2026-10-23 · Status: proposed (the verdict waits for the owner's #5 device table)

## Context

I1–I5 ask for an on-device illustration per word, drawn from a prompt that the language model writes. Phase 0 never ran the Image Playground check (#5, §10 Q4, ADR 0001). Phase 4 (plan 4.1–4.4, PR #63) built the whole path against stubs. The simulator always reports Image Playground unavailable, so availability in the owner's region, refusal rate, speed, styles and whether the pictures are recognisable are all still unknown. Separately, the iOS 27 SDK deprecates `ImageCreator` ("Use ImagePlaygroundViewController or imagePlaygroundSheet"), and both replacements are interactive only. Two questions: should pictures be on by default, opt-in or dropped, and should the app keep a deprecated API?

## Decision

Provisional: **pictures are on by default** (`UserSettings.autoGenerateImages = true`, with the Settings → Images toggle, S5). Every newly created word is queued, whether typed or added by Siri (ruling on #49); imported words are not. A job waits for the word's first card, asks the on-device model for a visual prompt (or "no suitable image", I5), and then asks `ImageCreator` for one picture in `.illustration` style, or the first style offered. Jobs are serial and run in the foreground only. Every outcome is stored as `Word.imageStatus` and never shown as an alert. The card always offers Choose photo… and Take photo… (I2, I4). `ImageCreator` is kept despite the deprecation, because it is the only API that can draw without the user. It is **confined to `ImagePlaygroundGenerator`** in Core: its members carry the same deprecation, and the app target and the queue reach it only through the `ImageGenerator` protocol, built by `ProductionImageServices`. The owner's #5 table decides between three outcomes. **On by default** accepts this ADR as is. **Opt-in** flips the default to `false` and keeps the toggle. **Dropped** removes the generator and the Generate action; the library, the camera and file storage (I2, I6) stay.

## Consequences

- Easier: any verdict is a one-line default change or the deletion of one type. Library and camera pictures do not depend on it.
- Harder: if a future SDK removes `ImageCreator` but keeps the framework, this one file stops compiling. The fix is to delete the type. `ProductionImageServices` then serves the always-unavailable generator, and pictures degrade to library and camera only (I4). If only the interactive API remains, background pictures (I3) are not possible.
- On an iPhone without Image Playground, the placeholder shows until the first card settles, and then the "isn't available" footnote appears.
- `.unavailable` is terminal for a word. Words added just after Apple Intelligence is turned on (model still not ready) keep the footnote until the user taps Generate.
- Pictures are not in the JSON export (1.7 expected 4.x to add an optional `image` key; it did not). A picture does not survive export → import. This is an open question for the owner, not decided here.
- Revisit: when #5 is posted (set the status to accepted, then update §8, §10 Q4, I1–I5 and plan 4.2). Also revisit when a beta SDK removes `ImageCreator` or adds a non-interactive replacement. The provisional mapping of a guardrail refusal that arrives as `creationFailed` (shown as "Couldn't create a picture") is re-checked against the #5 refusals.
