# Wordhoard

A personal English vocabulary app for iPhone. Add a word — by typing, by asking Siri, or by sharing it from another app — and Wordhoard fills in the rest: definition, translation, synonyms, antonyms, example sentences tied to the grammar you're learning, and a picture. All of it on the device, with no account and no server.

> *word-hord* (Old English): the store of words a poet keeps in memory.

## Status

Phase 1 of [`docs/plan.md`](docs/plan.md): the project skeleton builds, tests and lints; the app launches to an empty word list. Requirements are in [`docs/requirements.md`](docs/requirements.md); conventions in [`CLAUDE.md`](CLAUDE.md).

## Building

Xcode 27.0 with the iOS 27 SDK, plus `brew install xcodegen swiftformat swiftlint`. The Xcode project is generated from `project.yml` and committed; never edit it by hand.

```sh
xcodegen generate                                   # after any change to project.yml
xcodebuild -scheme Wordhoard -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Testing and linting:

```sh
cd WordhoardCore && swift test                      # unit tests, no simulator needed
xcodebuild -scheme Wordhoard -destination 'platform=iOS Simulator,name=iPhone 17' test   # Core tests + UI smoke test
swiftformat --lint . && swiftlint --strict          # what CI runs; `swiftformat .` fixes formatting
```

Use whatever iPhone `xcrun simctl list devices available` shows if `iPhone 17` is missing. CI (`.github/workflows/ci.yml`) runs lint, regenerates the project and fails on a diff, runs `swift test` and builds for a simulator on every PR and push to `main`.

`spike/` is the Phase 0 spike, kept as the on-device prompt regression runner; it is a separate Xcode project outside lint and CI. See [`spike/README.md`](spike/README.md).

## What it will do

- **Capture anywhere.** Type a word, say "Hey Siri, add a word to Wordhoard", or share text from Safari.
- **Fill itself in.** Apple's on-device language model (Foundation Models framework) generates the card as structured data. Everything is editable; your edits are never overwritten.
- **Learn grammar along the way.** Each example sentence is tagged with a grammar topic — *Present Perfect*, *Second Conditional*, *Passive Voice* — chosen from the topics you're currently studying.
- **Pictures, on device.** Illustrations generated with Image Playground, or your own photos.
- **Private by construction.** No network calls, no analytics, no sign-up. Your words live on your phone (and in your own iCloud backup).
- **Review later.** Spaced repetition and grammar drills are planned for v2.

## Requirements

- iPhone running iOS 27 or later.
- AI features (autofill, image generation) need an Apple Intelligence-capable device with Apple Intelligence enabled. Without it the app still works; you fill the cards in yourself.

## Tech

SwiftUI · SwiftData · Foundation Models · Image Playground · App Intents · StoreKit 2

## Roadmap

| Version | Scope |
|---|---|
| v1 | Capture, autofill, card view and editing, images, Siri, grammar topics, export/import |
| v1.1 | Share sheet, tags, pronunciation, tip jar, App Store release |
| v2 | Flashcards with FSRS, reminders, grammar drills, iCloud sync |

Details and the reasoning behind each decision are in [`docs/requirements.md`](docs/requirements.md).

## Pricing

Free, with no locked features. If it helps you, there will be a tip jar.

## License

Code: [Apache License 2.0](LICENSE). Bundled third-party data is listed in [NOTICE](NOTICE) with its own license (Open English WordNet, CC BY 4.0). The name *Wordhoard*, the app icon and other brand assets are not covered by the license.
