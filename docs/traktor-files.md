# TRAKTOR FILES

741-mix reads and writes traktors own file formats -> no export step, no conversion.

## ◆ COLLECTION.NML (read)

* `COLLECTION/ENTRY` -> `LOCATION` (volume + dir + file, dir uses `/:` as separator), `INFO`, `TEMPO`, `LOUDNESS`, `MUSICAL_KEY`, `CUE_V2`
* track key = `VOLUME + DIR + FILE`, the same key playlists use in `PRIMARYKEY`
* `INFO COMMENT` = comment 1, `INFO RATING` = comment 2 (yes, rating)
* `MUSICAL_KEY` 0-11 major (c…b), 12-23 minor -> shown as open key (1d…12m)
* `CUE_V2 TYPE`: 0 cue, 1 fade in, 2 fade out, 3 load, 4 grid, 5 loop. `START` / `LEN` in ms, `HOTCUE` -1 or 0-7
* `PLAYLISTS/NODE` tree: folder, playlist, smartlist (`SEARCH_EXPRESSION QUERY`)
* the collection file itself is never written

## ◆ SMARTLIST QUERIES

same syntax as traktor, so existing smartlists just work:

```
$COMMENT % "hain" & $IMPORTDATE >= MONTHS_AGO(12)
$COMMENT2 % "» BASIS" | $COMMENT2 % " BASIS"
$FILEPATH STARTS_WITH "/Users/me/Music/2023"
```

* fields: `$ARTIST $TITLE $COMMENT $COMMENT2 $LABEL $GENRE $KEY $BPM $COLOR $RATING $PLAYCOUNT $PLAYED $IMPORTDATE $FILEPATH $FILESTATE` and a few more
* operators: `%` contains, `!%` not contains, `== != >= <= > <`, `STARTS_WITH`, `&` and, `|` or, `!` not, brackets
* functions: `MONTHS_AGO(n)`, `DAYS_AGO(n)`, `TRUE` / `FALSE`
* own smartlists in 741-mix use the same syntax

## ◆ HISTORY (read + write)

file name like traktor: `history_2026y10m10d_21h05m07s.nml`

* `COLLECTION` -> the full `ENTRY` of every played track, copied 1:1 from the collection (cues, tags, audio id stay intact)
* `PLAYLISTS` -> one playlist `HISTORY`, `TYPE="PROTOCOL"`, each entry with:

```
<EXTENDEDDATA DECK="0" DURATION="148.456314" EXTENDEDTYPE="HistoryData" PLAYEDPUBLIC="1" STARTDATE="132778506" STARTTIME="32592">
```

* `STARTDATE` = year << 16 | month << 8 | day, `STARTTIME` = seconds since midnight, `DECK` 0-3
* a track counts as played after 30s audible (setting) -> in external mode always audible, internal mode needs the fader up
* own sessions: `~/Library/Application Support/741-mix/History`, optional copy into traktors `History` folder
* the history archive shows own sessions and all traktor sessions

## ◆ PREPARATION (write)

* the preparation list survives a crash but gets archived and cleared on every start
* archive = normal traktor playlist nml (`TYPE="LIST"`) in `~/Library/Application Support/741-mix/Preparation` -> import in traktor via the playlist import

## ◆ TRAKTOR SETTINGS.TSI (read, tools only)

`DeviceIO.Config.Controller` is a base64 blob with a chunk tree (4 byte tag, 4 byte big endian length):

```
DIOM -> DIOI, DEVS [count] -> DEVI (name utf-16) -> DDAT -> DDIF, DDIV, DDIC (comment), DDPT (port / serial),
        DDDC (controls: DDCI in, DDCO out, DCDT names), DDCB (bindings: CMAS -> CMAI -> CMAD, DCBM control names)
```

* `CMAI` = control id, in / out, command id, then `CMAD` with control type, interaction mode, deck, modifiers, values
* command ids from cmdr, e.g. 874 flux reverse, 2380 beatjump, 2548 modifier 1, 2549 modifier 2
* beatjump values: ±7 = ±1 beat, ±8 = ±2, ±9 = ±4 … (cmdr `MoveSize`)
* `tools/tsi_dump.py` prints the chunk tree, `tools/tsi_x1.py` prints the custom x1 bindings
