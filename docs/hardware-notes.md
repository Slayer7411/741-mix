# Hardware notes: Pioneer DJM-V10 and DJM-A9

Research for the mixer profiles (`Sources/MixCore/MixerProfiles.swift`) and the MIDI clock output
(`Sources/MixEngine/MIDIClockOut.swift`). Status per fact: **verified** (primary source read), **reported**
(secondary source or search snippet only), **open** (not found, not on hardware).

Status of the profiles: ungetestet – Kanalbelegung bitte prüfen (untested, please check the channel mapping).

## Facts

| Fact | DJM-V10 | DJM-A9 | Status | Source |
|---|---|---|---|---|
| USB audio channels | 12 in / 12 out (6 stereo pairs) | 4 stereo pairs reported, unconfirmed | V10 reported, A9 open | Linux ALSA quirk for the V10 (commit 171bb5123fbc, mirror: https://mirrors.lzu.edu.cn/git/linux-nf/-/commit/171bb5123fbc1c64a89a77b365e27e263c50491c). A9 claim from a retailer listing (no URL kept) |
| Sample formats / rates | S24_3LE, 44.1 / 48 / 96 kHz | open | V10 reported | same kernel commit |
| Kernel support for A9 | – | commit 5289d00696 "ALSA: usb-audio: Add Pioneer DJ/AlphaTheta DJM-A9 Mixer", merged 2024-10-29 (hash from search snippet) | reported | https://code.amethyst.name/public-mirrors/linux/commits/branch/master/sound/usb/quirks-table.h |
| Playback pair → mixer channel (CH1–CH4/6, input selector USB) | open | open | open | Pioneer manuals are encrypted PDFs (see below); no text extraction possible |
| macOS CoreAudio device name | open ("DJM-V10"/"DJM-A9" is an assumption; the profile matches by normalised substring) | open | open | not found; check Audio MIDI Setup on a Mac |
| Deck channel map in djay (A9) | – | djay Pro reports channel order 3-1-2-4 on the A9 | reported (user thread) | https://community.algoriddim.com/t/external-mixer-sync-behaviour/39895 |
| MIDI clock out (from mixer) | DIN out, synced to the active channel's BPM; USB MIDI out also described | DIN out (5-pin) claimed by a forum post | reported | https://cdm.link/2024/01/pioneer-v10-midi/ ; https://forum.liberationlaser.com/t/keeping-tempo-for-live-shows/222 |
| MIDI enable on the mixer | "USB/MIDI" section, toggle on; START/STOP there | open | reported | https://cdm.link/2024/01/pioneer-v10-midi/ |
| Mixer accepts MIDI clock over USB or DIN | No: "there's no MIDI input" (V10 is clock source) | open | reported (V10, secondary) | https://cdm.link/2024/01/pioneer-v10-midi/ ; DJ Tech Tools forum user claims Pioneer mixers have MIDI out only: https://forum.djtechtools.com/t/syncing-traktor-scratch-pro-3-effects-to-pioneer-djm-900-nexus2-mixer/78027 |
| MIDI port name (macOS) | open | open | open | not found |

## Official manuals

* DJM-V10 manual: https://www.adorama.com/col/productManuals/PIDJMV10LF.pdf (7.3 MB, encrypted, no text
  extraction without decryption).
* DJM-A9 manual: https://rent.djcenter.ee/images/kasutusjuhendid/Pioneer-DJM-A9.pdf (6.5 MB, encrypted).

Both were fetched and checked. The text is not readable, so the channel maps, device names and MIDI
settings above are **open**, not verified. The next step is to read the "USB audio" and "USB/MIDI"
sections by hand, or to get a plain-text copy from Pioneer DJ support.

## What this means for the code

* Profiles set external mode with deck A–D on CH1–CH4 (pairs 1/2, 3/4, 5/6, 7/8). V10 suggests CH5/6 for
  preview. The offer lists the exact pairs before anything changes. Nothing is applied silently.
* The MIDI clock output is generic: it sends 24 ppqn with start/stop, optional song position and an offset
  to any MIDI output. It is off by default. Nothing in the UI or docs claims that the mixer syncs its
  Beat FX or BPM display to it. The V10 is documented as a clock source, not a sink.
* Port preselection looks for the names "DJMV10" / "DJMA9" in the MIDI port name (normalised). Unverified.

## Test plan on hardware (not done)

1. Plug in the V10 and the A9 and note the CoreAudio name and channel count (Audio MIDI Setup).
2. Set the mixer channel inputs to USB, play a tone on each deck pair, and check which mixer channel
   carries it.
3. Check the sample rates the mixer accepts (44.1 / 48 / 96 kHz).
4. Enable MIDI clock on the mixer's MIDI menu, then check whether the mixer shows a BPM change when
   MINOS-741 sends clock (expected: no, if the mixer is only a clock source).
