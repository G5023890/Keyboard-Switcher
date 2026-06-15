# Keyboard Switcher

Keyboard Switcher is a native macOS menu bar utility that corrects text typed with the wrong keyboard layout. It currently targets English, Russian, and Hebrew, runs locally, and keeps the app bundle small by using Apple system frameworks plus compact bundled word lists.

Current release checkpoint: `v0.85`.

## What It Does

- Shows the current keyboard layout in the menu bar as `A`, `Я`, or `א`.
- Watches keyboard input locally through macOS Accessibility/Input Monitoring permissions.
- Buffers the current word and evaluates likely intended text across English, Russian, and Hebrew layouts.
- Corrects already typed words when confidence is high enough.
- Switches the macOS input source to the language chosen for the corrected word.
- Plays a bundled typewriter-style switch sound when the layout actually changes.
- Supports Double Shift manual correction for the word before the cursor.
- Learns from manual Double Shift corrections and from Undo suppressions.
- Avoids correction in excluded apps and unsafe text shapes such as URLs, emails, file paths, shell-like commands, and code-like tokens.
- Uses local dictionaries, local spelling signals, compact scoring rules, and user learning. It does not send typed text to the internet.

## Design

The app is macOS-first and uses SwiftUI/AppKit with an Apple Liquid Glass-style settings experience. It is intended as a small menu bar utility rather than a full windowed productivity app.

The settings window includes:

- Auto-correction enable/disable.
- Enabled languages.
- Correction confidence.
- App exclusions.
- Accessibility permission status.
- Diagnostics for debugging current correction behavior.

## How Correction Works

The app captures physical key strokes and keeps a buffer for the current word. When the user presses a terminator such as Space or Enter, or when Double Shift is pressed manually, the app builds candidate words by replaying the same physical key sequence under supported keyboard layouts.

Candidates are scored using:

- Layout conversion confidence.
- Bundled Russian frequency data.
- Bundled English common-word data.
- Apple `NaturalLanguage` / `NLLanguageRecognizer`.
- Apple `NSSpellChecker` where a local dictionary is available.
- Short-word safety rules.
- Technical casing rules for terms like `macOS`, `iOS`, `CoreML`, `SwiftUI`, and `Xcode`.
- Local user learning.
- Local suppressions after undo.

The app only applies a correction when the winner is clear enough. Low-confidence cases are left alone.

## Manual Learning With Double Shift

Double Shift is the manual correction and learning path:

1. Type a word in the wrong layout.
2. Press Shift twice quickly.
3. The app selects/copies the word before the cursor, finds the best replacement, replaces it, switches to the target layout, and records the choice locally.

Future occurrences of the same source word can use the learned replacement before the normal scorer runs.

Undoing the last correction records a local suppression for that exact source/replacement pair, so the same unwanted automatic correction is avoided later.

## Privacy

Keyboard Switcher is designed as a local-only utility.

- Typed text is not sent to a server.
- No LLM runtime is embedded.
- No network API is used for recognition.
- Learning data is stored locally in user defaults.
- The app uses macOS Accessibility APIs to observe keyboard events and apply replacement.

## Safety Rules

The app is intentionally conservative:

- It does not correct low-confidence words.
- It skips configured excluded applications.
- It avoids obvious URLs, email addresses, file paths, shell commands, and code-like text.
- It disables correction where password fields are detectable through macOS APIs.
- It provides manual correction through Double Shift when automatic correction is too risky.

Recommended exclusions include Terminal, Xcode, code editors, password managers, remote desktop tools, and other apps where automatic text replacement can be disruptive.

## Included Data And Assets

Bundled resources are kept small:

- `KeyboardSwitcher/Resources/russian-frequency-50000.txt`
- `KeyboardSwitcher/Resources/english-common-5000.txt`
- `KeyboardSwitcher/Resources/AppIcon.icns`
- `KeyboardSwitcher/Resources/KeyboardSwitcherIcon_1024_whitebg.png`
- `KeyboardSwitcher/Resources/switch_typewriter_shift.wav`
- `KeyboardSwitcher/Resources/THIRD-PARTY-NOTICES.txt`

The current installed app bundle is roughly 4 MB, comfortably below the 500 MB hard limit.

## Third-Party Notices

See `LICENSES/THIRD-PARTY-NOTICES.md` and the bundled `KeyboardSwitcher/Resources/THIRD-PARTY-NOTICES.txt`.

Summary:

- Russian frequency data is derived from the University of Leeds Russian Internet Corpus and William Hingston's cleaned `hingston/russian` repository. The source data is distributed under Creative Commons Attribution 2.5.
- English common-word data is derived from Michael Wehar's `Public-Domain-Word-Lists`, whose README describes `5000-more-common.txt` as public domain.
- The app icon and switch sound are project-provided assets.

Resources that were evaluated but are not bundled in `v0.85`:

- `first20hours/google-10000-english`, because its license notice cautions against commercial use without licensing from the Linguistic Data Consortium.
- `dwyl/english-words`, because the current app does not need a very large English word list.
- `rspeer/wordfreq`, because the project currently avoids heavy Python/package data and keeps the macOS app compact.

## Project License

No open-source license for the Keyboard Switcher application code has been declared yet. Until a license is added, the repository should be treated as all rights reserved by the project owner, except for the separately attributed third-party data listed in `LICENSES/THIRD-PARTY-NOTICES.md`.

## Requirements

- macOS 15 or newer target, tested on current macOS beta.
- Xcode-beta.
- Accessibility permission for runtime use.

## Build

Use Xcode-beta:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project "Keyboard Switcher.xcodeproj" \
  -scheme "Keyboard Switcher" \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

## Test

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project "Keyboard Switcher.xcodeproj" \
  -scheme "Keyboard Switcher" \
  -configuration Debug \
  -destination "platform=macOS" \
  test
```

Current checkpoint test status: 21 unit tests passing.

## Install Locally

The project includes a stable build/install script:

```sh
./scripts/build_and_install_app.sh
```

The script builds the Release app with Xcode-beta, signs it with the configured Apple Development identity when available, and installs it to:

```text
/Applications/Keyboard Switcher.app
```

Keeping the bundle identifier stable helps preserve macOS Accessibility permission across rebuilds.

## Basic Manual QA

After installing:

1. Open Keyboard Switcher from `/Applications`.
2. Grant Accessibility permission if macOS asks for it.
3. Open TextEdit.
4. Type `ghbdtn` in the English layout and press Space. It should become `привет`.
5. Type `ghbdtn` without pressing Space, then press Shift twice quickly. It should become `привет`.
6. Test phrase words such as `rfr ltkf` to get `как дела`.
7. Confirm the menu bar indicator changes between `A`, `Я`, and `א`.
8. Confirm layout switching happens after a correction whose target language differs from the current input source.
9. Confirm the switch sound plays only when the input source actually changes.
10. Test excluded apps such as Terminal and Xcode.

## Repository Hygiene

Ignored local artifacts include:

- `.DS_Store`
- `.codex/`
- `.build/`
- `dist/`
- `DerivedData/`

Generated Release builds should not be committed.
