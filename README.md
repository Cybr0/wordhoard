# Wordhoard

A personal English vocabulary app for iPhone. Add a word — by typing, by asking Siri, or by sharing it from another app — and Wordhoard fills in the rest: definition, translation, synonyms, antonyms, example sentences tied to the grammar you're learning, and a picture. All of it on the device, with no account and no server.

> *word-hord* (Old English): the store of words a poet keeps in memory.

## Status

Pre-development. The requirements are being written down before any code; see [`docs/requirements.md`](docs/requirements.md).

## What it will do

- **Capture anywhere.** Type a word, say "Hey Siri, add a word to Wordhoard", or share text from Safari.
- **Fill itself in.** Apple's on-device language model (Foundation Models framework) generates the card as structured data. Everything is editable; your edits are never overwritten.
- **Learn grammar along the way.** Each example sentence is tagged with a grammar topic — *Present Perfect*, *Second Conditional*, *Passive Voice* — chosen from the topics you're currently studying.
- **Pictures, on device.** Illustrations generated with Image Playground, or your own photos.
- **Private by construction.** No network calls, no analytics, no sign-up. Your words live on your phone (and in your own iCloud backup).
- **Review later.** Spaced repetition and grammar drills are planned for v2.

## Requirements

- iPhone running iOS 26 or later.
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

To be decided at first release. The code will be under a permissive open-source license; the name *Wordhoard*, the app icon and other brand assets are not part of that license.
