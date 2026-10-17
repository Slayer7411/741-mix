# START

from zero to your first recorded set. no tech skills needed.

this guide is for djs who are not tech people. read one step at a time. you can skip the optional parts.

## ◆ 1 · WHAT YOU NEED

1. a mac with macos 15 or newer. apple silicon or intel both work.
2. music, in one of two ways:
   * an nml collection: your library file from your dj library software (`collection.nml`)
   * plain music files in folders (mp3, m4a, aac, aiff, wav, flac, ogg, opus)
3. optional, not needed to start:
   * Kontrol X1 mk2 controller (up to two units)
   * Xone:96 mixer
   * any audio interface (the box that sends sound out of the mac)

without a controller you use the mouse and the keyboard. everything in this guide works that way.

## ◆ 2 · INSTALL

the easy way, in the terminal (a window where you type commands):

```
brew install --cask slayer7411/tap/minos-741
```

brew is an install helper for macs. if the terminal says `brew` is not found, use the dmg way below.
update later: `brew upgrade --cask --greedy minos-741`

the dmg way:

1. open the releases page: https://github.com/Slayer7411/MINOS-741/releases/latest
2. download `MINOS-741.dmg`
3. open it and drag MINOS-741 onto the applications folder

**first start: the warning "not signed by apple"**

MINOS-741 is not signed by apple. the mac blocks it the first time. this is normal. do this once:

1. try to open MINOS-741. the mac says it cannot be opened. close the message.
2. click the apple menu (top left) -> system settings.
3. click privacy & security in the left list.
4. scroll down to the security part. there is a line about MINOS-741. click `OPEN ANYWAY`.
5. if the mac asks, enter your mac password.
6. open MINOS-741 again. from now on it starts normally.

## ◆ 3 · FIRST START

1. close any other dj app. the controller can talk to one app only.
2. open MINOS-741.
3. the app loads the newest library file (`collection.nml`) on its own. for another file press `⌘O` (`⌘` = command key, next to the space bar).
4. a small panel may ask you to donate a coffee. it is optional. close it with later or never.

**what you see**

* top bar: the clock and the buttons for the whole screen
* decks in the middle: a deck is one player. A and B are your two main decks. C and D are there too, switch them with the `1` `2` `4` buttons in the top bar
* browser at the bottom: the list of your tracks. on its left side is a tree (sources like the collection, music folders and playlists)
* status bar at the bottom: short messages, for example "track loaded"

**where your music comes from**

* library file: the tracks from your nml collection. they already have bpm (speed), key and beat map (grid), so they can sync.
* music folders: in the browser tree, click MUSIC FOLDERS, then a folder. these files play too. files that are not in your library file are grey and have no beat map, so they cannot sync.
* the folder the app uses for the library: `⌘,` -> BROWSER -> collection

**audio: where the sound goes**

press `⌘,` (settings) -> AUDIO. pick your output device and a mode:

* INTERNAL: the app mixes the decks itself. one pair of outputs (left and right) goes out.
* EXTERNAL: your desk mixes. every deck has its own pair of outputs into the desk.

**controller (optional)**

`⌘,` -> CONTROLLER -> BLINK lights the pads of one unit, so you see which one is which.

## ◆ 4 · LOAD, PLAY, SYNC, LOOP

the keys and controls you need first. `⌘` = command, `⌥` = option, `⌃` = control, `⇧` = shift.

1. choose a deck: `⌘1` to `⌘4` picks deck A to D. the chosen deck is the focused deck.
2. load a track: double click it in the browser. it goes into the focused deck. (right click it -> load into deck A-D to choose the deck.)
3. play and pause: `⌘space`
4. sync: `⌘Y`. the deck matches the speed and the beat of the master deck. the master is the deck with its MASTER button on (speed reference). sync needs a beat map. no sync? see step 7.
5. loop: `⌘L` turns the auto loop on or off. a loop repeats a short piece of the track.
6. hotcue: `⌃⌘1` to `⌃⌘8`. a hotcue is a saved spot in the track. press once to save it, press again to jump back to it.
7. beatjump: `⌥⌘←` and `⌥⌘→` jump back and forward in beats.
8. tempo (speed): drag the slider on the right side of a deck. double click it to go back to normal.

on the Kontrol X1 mk2: play, sync, hotcue 1-4, the loop knob (turn = loop size, press = loop on / off) and LOAD do the same jobs.

## ◆ 5 · MIX TWO TRACKS

1. press `⌘1`, then double click a track. deck A plays it. press `⌘space` to play deck A.
2. on deck A, click MASTER. deck A is now the speed reference.
3. press `⌘2`, then double click a second track. it lands on deck B.
4. press `⌘Y` on deck B. deck B now follows deck A.
5. press `⌘space` on deck B. both decks play in time.
6. move the crossfader (the slider that moves the sound from one deck to the other) slowly from A to B.

tip: a deck that is playing does not take a new track. this protects the sound. stop it first.

in INTERNAL mode the mixer is inside the app. press `⌥⌘M` to show or hide it.
in EXTERNAL mode the desk does the fading. the app only plays the decks.

## ◆ 6 · RECORD YOUR SET

1. click ● REC in the top bar (the red dot next to the clock). the recording starts. the dot blinks and the time runs.
2. play your set.
3. click ● REC again to stop. there is no dialog. the status bar shows the saved file name.

**where the files end up**

* folder: `~/Music/MINOS-741/Recordings`
* the sound: `YYYY-MM-DD HH.MM Set.m4a` (date and time of the start)
* next to it, the same name with `.txt`: the tracklist, one line per track (`00:00 Artist – Title`)
* next to it, the same name with `.cue`: track marks for other programs

in INTERNAL mode the app records the main output by itself.
in EXTERNAL mode the desk's master must go into an input of your audio interface. see [MANUAL](MANUAL.md) section 16 for the setup.
the mac may ask for access to audio inputs the first time. say yes, or the input cannot be read.

## ◆ 7 · IF SOMETHING GOES WRONG

* **no sound**: `⌘,` -> AUDIO. check the device, the mode and the output pair. the status bar shows what is connected.
* **controller does nothing**: close any other dj app, unplug the controller and plug it in again. check `⌘,` -> CONTROLLER -> BLINK.
* **sync does not work**: the track has no beat map. right click the track -> analyze. the app finds the speed, the beats and the key. do it once per track.
* **track will not load**: read the status bar. `Datei fehlt` means the file is missing. artist name in red = the file was moved. put it back or fix its path in your library, then press ↻ (reload) in the top bar.
* **crackles, or the DROPOUTS number goes up**: `⌘,` -> AUDIO -> a bigger buffer (the buffer is the audio cushion; bigger is safer but adds a little delay). close other audio apps.

## ◆ 8 · WHERE TO GO NEXT

* [FEATURES.md](FEATURES.md): what the app can do, in short lines
* [MANUAL.md](MANUAL.md): the full reference, every screen and every key. start with 01 INSTALL and 14 TROUBLESHOOTING
* your controller or mixer is missing? request it: https://github.com/Slayer7411/MINOS-741/discussions/3
* questions: https://github.com/Slayer7411/MINOS-741/discussions
* bugs: https://github.com/Slayer7411/MINOS-741/issues
* recorded a set? submit it in https://github.com/Slayer7411/MINOS-741/discussions/categories/show-and-tell
* news and sets: [@minos_741](https://www.instagram.com/minos_741/)
