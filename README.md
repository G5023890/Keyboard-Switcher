# Keyboard Switcher

Keyboard Switcher is a native macOS menu bar utility that corrects text typed with the wrong keyboard layout. It currently targets English, Russian, and Hebrew, runs locally, and keeps the app bundle small by using Apple system frameworks plus compact bundled word lists.

Current release checkpoint: `v0.88 (0903.1706.26)`.

## What It Does

- Shows the current keyboard layout in the menu bar as `A`, `Я`, or `א`.
- Watches keyboard input locally through macOS Accessibility/Input Monitoring permissions.
- Buffers the current word and evaluates likely intended text across English, Russian, and Hebrew layouts.
- Corrects already typed words when confidence is high enough.
- Switches the macOS input source to the language chosen for the corrected word.
- Plays a bundled typewriter-style switch sound when the layout actually changes.
- Supports Double Shift manual correction for the word before the cursor.
- Learns from manual Double Shift corrections and from Undo suppressions.
- Handles selected short functional words such as Russian `и`, English `I`/`in`, and Hebrew `ו`/`של` with extra safeguards.
- Avoids correction in excluded apps and unsafe text shapes such as URLs, emails, file paths, shell-like commands, and code-like tokens.
- Uses project-provided local dictionaries, local spelling signals, compact scoring rules, optional local Core ML shadow scoring, and user learning. It does not send typed text to the internet.

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
- A strict whitelist for 1-2 character functional words. In automatic mode these short words require Space as the terminator; punctuation and Enter do not trigger them.
- Technical casing rules for terms like `macOS`, `iOS`, `CoreML`, `SwiftUI`, and `Xcode`.
- Local user learning.
- Local suppressions after undo.
- Optional local Core ML safety classification in shadow mode. The model records diagnostics and divergence against the rule-based scorer, but the rule/scoring pipeline remains the source of truth in this release.

The app only applies a correction when the winner is clear enough. Low-confidence cases are left alone.

## Local Intelligence

`v0.88` adds the first local Core ML safety layer without changing the correction engine's authority.

- `CorrectionSafetyClassifier.mlmodel` is bundled as a small local model.
- The model runs only after a word-level decision point, such as a terminator, manual correction, or suggestion flow.
- The model currently operates in shadow/reranker diagnostics mode: it reports `auto_correct`, `suggest_only`, or `do_nothing`, plus confidence, but does not override the deterministic safety rules.
- Diagnostics show the last ML decision, confidence, text context, divergence from the rule fallback, and local training sample count.
- Synthetic dataset and training helpers live in `scripts/generate_synthetic_dataset.py`, `scripts/merge_training_samples.py`, and `scripts/train_correction_safety_model.swift`.
- Training samples are stored locally and are used for development diagnostics; no typed text is sent to a network service.
- Local training samples can be exported manually from Settings -> Diagnostics -> Export Training Samples. The export is JSONL with correction features, outcomes, model predictions, and text context labels only.

Local model training workflow:

```bash
scripts/generate_synthetic_dataset.py \
  --output dist/training/correction_safety_synthetic.jsonl

# Save the Settings export as:
# dist/training/correction_safety_local.jsonl

scripts/merge_training_samples.py \
  --synthetic dist/training/correction_safety_synthetic.jsonl \
  --local dist/training/correction_safety_local.jsonl \
  --output dist/training/correction_safety_mixed.jsonl \
  --local-weight 4

scripts/train_correction_safety_model.swift \
  --input dist/training/correction_safety_mixed.jsonl \
  --model-output dist/training/CorrectionSafetyClassifier.mlmodel
```

The default merge keeps synthetic samples as the broad baseline and gives local samples higher weight so real undo/manual/suggestion behavior can shape the next model without exporting typed text.

Recent short-word examples:

- `b` + Space -> `и `
- `z` + Space -> `я `
- `ш` + Space -> `I `
- `ф` + Space -> `a `
- `шт` + Space -> `in `
- `u` + Space -> `ו `
- `ak` + Space -> `של `

Double Shift remains an explicit manual override and can correct short words without requiring a trailing Space.

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

- `KeyboardSwitcher/Resources/ru_auto_core_100k.tsv`
- `KeyboardSwitcher/Resources/ru_manual_extended_300k.tsv`
- `KeyboardSwitcher/Resources/en_auto_core_50k.tsv`
- `KeyboardSwitcher/Resources/en_manual_extended_200k.tsv`
- `KeyboardSwitcher/Resources/short_words_auto_whitelist.tsv`
- `KeyboardSwitcher/Resources/technical_never_correct.tsv`
- `KeyboardSwitcher/Resources/CorrectionSafetyClassifier.mlmodel`
- `KeyboardSwitcher/Resources/AppIcon.icns`
- `KeyboardSwitcher/Resources/KeyboardSwitcherIcon_1024_whitebg.png`
- `KeyboardSwitcher/Resources/switch_typewriter_shift.wav`
- `KeyboardSwitcher/Resources/THIRD-PARTY-NOTICES.txt`

The current dictionary TSV set adds roughly 20 MB of local data before app packaging, comfortably below the 500 MB hard limit.

Dictionary policy:

- Automatic correction uses only the clean auto dictionaries: `ru_auto_core_100k.tsv`, `en_auto_core_50k.tsv`, and `short_words_auto_whitelist.tsv`.
- Manual correction and Double Shift may use the broader manual delta dictionaries: `ru_manual_extended_300k.tsv` and `en_manual_extended_200k.tsv`.
- Manual extended dictionaries do not increase automatic confidence.
- Manual delta dictionaries intentionally exclude words already covered by the automatic core dictionaries and short-word whitelist.
- `technical_never_correct.tsv` is checked before normal layout scoring to protect technical terms, paths, identifiers, versions, URLs, emails, and code-like tokens.
- Some technical terms can also exist in word dictionaries; the technical preflight layer takes precedence.
- Russian dictionary matching normalizes `ё` to `е`.
- Dictionary separation can be checked with `python3 scripts/audit_dictionaries.py`.

## Third-Party Notices

See `LICENSES/THIRD-PARTY-NOTICES.md` and the bundled `KeyboardSwitcher/Resources/THIRD-PARTY-NOTICES.txt`.

Summary:

- Current Russian and English scoring dictionaries are project-provided TSV resources maintained for Keyboard Switcher, split into automatic core dictionaries and manual delta dictionaries. Older bundled `txt`/`csv` dictionary resources were removed after the TSV migration.
- Short Russian and English 1-4 character word behavior is controlled by the project-provided `short_words_auto_whitelist.tsv`.
- Technical terms and technical-token rules are project-provided resources, now backed by `technical_never_correct.tsv`, used to reduce false corrections around macOS, iOS, SwiftUI, Core ML, Xcode, APIs, filenames, and identifiers.
- `CorrectionSafetyClassifier.mlmodel` is a project-generated local Core ML model trained from synthetic/project data for shadow safety diagnostics.
- The app icon and switch sound are project-provided assets.

Resources that were evaluated or used as development references but are not bundled as current dictionaries in `v0.88`:

- `wordfreq` 3.1.1 and `pymorphy3`, because the current Russian and English dictionaries have been replaced by project-provided resources.
- `first20hours/google-10000-english`, because its license notice cautions against commercial use without licensing from the Linguistic Data Consortium.
- `dwyl/english-words`, because the current app does not need a very large English word list.
- `hingston/russian` and the University of Leeds Russian Internet Corpus frequency list, because the Russian frequency resource has been replaced.
- `MichaelWehar/Public-Domain-Word-Lists`, because the English common-word resource has been replaced.

## Project License

No open-source license for the Keyboard Switcher application code has been declared yet. Until a license is added, the repository should be treated as all rights reserved by the project owner, except for the separately attributed third-party data listed in `LICENSES/THIRD-PARTY-NOTICES.md`.

## Requirements

- macOS 15.0 Sequoia or newer target, tested on current macOS beta.
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

Current checkpoint test status: 80 unit tests passing.

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
10. Test short functional words: `b` + Space -> `и `, `ш` + Space -> `I `, and `u` + Space -> `ו `.
11. Confirm short functional words do not auto-correct on non-Space terminators.
12. Test excluded apps such as Terminal and Xcode.

## Repository Hygiene

Ignored local artifacts include:

- `.DS_Store`
- `.codex/`
- `.build/`
- `dist/`
- `DerivedData/`

Generated Release builds should not be committed.
