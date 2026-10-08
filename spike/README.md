# Wordhoard spike (Phase 0)

Throwaway app that answers `docs/requirements.md` §10 Q1: can the on-device Foundation Models
language model produce a usable vocabulary card? One screen: a text field, a Generate button,
the model availability line, and the raw output.

Not held to the root `CLAUDE.md` conventions (no `WordhoardCore`, no tests, `print` is fine).
Nothing here is meant to survive into the real app except the lessons.

## Layout

- `project.yml` — XcodeGen spec. Regenerate with `cd spike && xcodegen generate`.
- `WordhoardSpike/CardGeneration.swift` — instructions, prompt, `@Generable` types and
  `generateCard(for:)`. Everything the model sees is in this one file; iterate here.
- `WordhoardSpike/ContentView.swift` — the screen.

## Run on a device

The simulator usually reports the model as unavailable (`deviceNotEligible` or
`appleIntelligenceNotEnabled`), so use a real iPhone with Apple Intelligence.

1. On the phone: Settings → Apple Intelligence & Siri → turn on Apple Intelligence, wait for the
   model download to finish. Device language should be English.
2. `open spike/WordhoardSpike.xcodeproj`.
3. Select the `WordhoardSpike` target → Signing & Capabilities → Team: pick your personal
   (free) team. The team is intentionally not committed in `project.yml`.
4. Select the phone as the run destination and run.
5. Type a word, tap Generate. The decoded card and the raw JSON appear on screen; the same raw
   JSON and a `dump` of the struct go to the Xcode console.

## Build check without a device

```
xcodebuild -project spike/WordhoardSpike.xcodeproj -scheme WordhoardSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```
