# Wordhoard — release checklist (TestFlight)

For the owner. The agents finished the [sim] half of plan 6.5 in PR #63. Release builds with zero warnings. There are no Debug hooks in the binary. The archived `Info.plist` has `dev.wordhoard.app`, display name Wordhoard, version **1.0.0**, build **1**, `ITSAppUsesNonExemptEncryption` false, category Education, portrait only and iOS 27.0. The app has no entitlements file. `DEVELOPMENT_TEAM` is empty. `ExportOptions.plist` and `*.xcarchive` are git-ignored. Nothing in this list is committed except a build-number bump.

## Version rules

- `MARKETING_VERSION` stays `1.0.0` for the whole v1 TestFlight period.
- `CURRENT_PROJECT_VERSION` is an integer. The first upload is `1`. Every later upload bumps it by one: edit `project.yml`, run `xcodegen generate`, and commit only that change as `Bump build number to N`.
- Before each archive, this unsigned check must pass from the repo root (the command used for PR #63):
  `xcodebuild archive -scheme Wordhoard -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/Wordhoard.xcarchive CODE_SIGNING_ALLOWED=NO`

## Owner steps

1. **Paid Apple Developer Program** (requirements §9). TestFlight needs it. Without it, use the fallback: Xcode → Run on the iPhone with the free personal team. That install expires after 7 days, so reinstall it every week.
2. **App Store Connect record.** My Apps → + → New App → iOS. Name "Wordhoard" (if the name is taken, choose another; the home screen still shows "Wordhoard"). Bundle ID `dev.wordhoard.app`, SKU `wordhoard`, primary language English (U.S.).
3. **App Privacy.** "Do you or your third-party partners collect data from this app?" → **No, we do not collect data from this app.** The label shows Data Not Collected. Why (plan 6.4): no network code, no analytics or crash SDKs, and the only required-reason API is file timestamps (`C617.1`, the picture orphan scan).
4. **Select your team without committing it.** In Xcode, target Wordhoard → Signing & Capabilities → Team. After archiving, run `git checkout -- Wordhoard.xcodeproj`. Or skip the change on disk entirely:
   `xcodebuild archive -scheme Wordhoard -configuration Release -destination 'generic/platform=iOS' -archivePath ~/Desktop/Wordhoard.xcarchive DEVELOPMENT_TEAM=<team id> -allowProvisioningUpdates`
5. **Archive and upload.** Product → Archive → Organizer. First, Generate Privacy Report: it should show Data Not Collected and File Timestamp only. Attach it to #53. Then Distribute App → TestFlight Internal Only → Upload. Export compliance is pre-answered. If App Store Connect emails an ITMS warning (for example ITMS-91053), paste it into #53.
6. **Install.** TestFlight → Internal Testing → add yourself → install from the TestFlight app. Note the build number and the date in #54. The placeholder icon ships unless you say otherwise in #52.
7. **First device run** (6.5): type a word and see it fill; add a word with "Hey Siri, add a word to Wordhoard"; Settings → Export → Files, then Import, and the list comes back; About shows the Open English WordNet credit. Then work through PR #63's "Needs device" list: #5 pictures, #6/#7 Siri and signing, #50 VoiceOver, #51 airplane mode, #52 icon. Post each result on its issue.
8. **The month.** Add every word you meet, every day, and keep the spreadsheet closed. If something is wrong or missing, open a one-line issue labelled `qa` the same day. On day 30, comment on #54 with: start and end dates, build number, words added, **"I prefer it to the spreadsheet: yes / no"**, and the three biggest frictions. qa ticks 6.5 and the v1 exit criterion from that comment (requirements §8 "Done when").

## Privacy statement (for the v1.1 landing page; reflects requirements §6)

Wordhoard keeps your words on your iPhone and in your own device backup. It has no account, no server and no analytics, and it never sends your data to us or to anyone else. Definitions, translations and pictures are made on the device by Apple's frameworks, and your words leave the phone only when you export them yourself.
