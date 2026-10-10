# CONTRIBUTING

```
> minos --contribute
  bugs      -> issues
  ideas     -> discussions
  own needs -> fork
  fixes     -> pull request
```

minos is built around my own setup. focused fixes, tests, docs and controller mappings are welcome. for bigger changes (audio core, sync, file formats) open a discussion or issue first.

## ◆ CHOOSING A CONTRIBUTION

* name the concrete problem, keep related changes together
* say what you tested and what you couldn't test (no external mixer, no controller, …)
* cosmetic-only changes -> collect them in one issue, not single prs

## ◆ SETUP

macos 15+, xcode / swift 6.

```
git clone https://github.com/Slayer7411/MINOS-741.git
cd MINOS-741
swift build
swift run minos741
```

app bundle -> `scripts/make-app.sh` (`--no-install` keeps it in `build/`).

## ◆ RULES

the realtime core has hard rules. a pr that breaks one is not merged.

* audio thread (`MixDSP`) -> atomics only, no locks, no allocations, no swift, no logging
* new recursive dsp state (filters, delay lines) -> reset it in `healDeck`, keep filter frequencies below nyquist (`Biquad::safeF`)
* deck logic, sync, controllers -> control thread (`MixController`), never the main thread
* ui only mirrors state and calls commands
* the device sample rate is never changed
* library files: read freely, write only history / preparation / exports. `collection.nml` stays untouched
* no vendor code. file formats and controller protocols only from own files and public docs
* new options get a setting (⌘,) and survive a restart
* ui text in english and german (`Localization/`)

modules: [docs/architecture.md](docs/architecture.md).

## ◆ VERIFY

before a pr:

```
swift test
MIX741_SELFTEST=1 MIX741_NOEXT=1 swift run minos741
```

`swift test` also renders the audio core offline (no device): transport, seek, loop, reverse, keylock, fx tail, limiter, clock, track handoff, decode, nan / denormal / low-rate guards, load order -> `Tests/MixEngineTests`. the same runs in ci on every push. cpu per block (local only): `MIX741_BENCH=1 swift test --filter benchRenderCPU`.
the self test plays, syncs, loops and jumps without sound and ends by itself. check the `[selftest]` lines: phase error should stay at ~0.00 beats.
audio / sync changes -> also test live with 2 decks + keylock, note the cpu load.
controller changes -> name the device and serial-free setup you tested with.

## ◆ STYLE

* code: match the file you're in
* commits: lowercase, short, what changed (`sync: keep phase after reverse`)
* docs + github texts: english, ci-741 style -> `## ◆ CAPS` headings, short lines, `->` and `·`, unicode instead of emoji
* no serial numbers, paths or personal data in commits

## ◆ RELEASES

maintainer checklist:

1. move `[UNRELEASED]` in [CHANGELOG.md](CHANGELOG.md) into `[X.Y.Z] · date · NAME`, update the compare links
2. bump the version in the README ticker
3. `git tag -a vX.Y.Z -m vX.Y.Z && git push origin main vX.Y.Z`
4. `gh release create vX.Y.Z --title "◆ vX.Y.Z · NAME"` with the changelog section -> the release action builds the universal dmg and attaches it (`MINOS-741.dmg` + `MINOS-741-X.Y.Z.dmg`), the homebrew cask always points to the latest one
5. `scripts/make-app.sh` -> app title shows the new version

semver: `0.x` minor = new features, patch = fixes.

## ◆ LICENSE

contributions are under GPL-2.0-or-later, same as the project ([LICENSE.md](LICENSE.md)).
