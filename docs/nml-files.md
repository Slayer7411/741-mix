# NML FILES

## ◆ COLLECTION.NML (read)

* `COLLECTION/ENTRY` -> `LOCATION` (volume + dir + file, dir uses `/:` as separator), `INFO`, `TEMPO`, `LOUDNESS`, `MUSICAL_KEY`, `CUE_V2`
* track key = `VOLUME + DIR + FILE`, the same key playlists use in `PRIMARYKEY`
* `INFO COMMENT` = comment 1, `INFO RATING` = comment 2
* `MUSICAL_KEY` 0-11 major (c…b), 12-23 minor -> shown as open key (1d…12m)
* `CUE_V2 TYPE`: 0 cue, 1 fade in, 2 fade out, 3 load, 4 grid, 5 loop. `START` / `LEN` in ms, `HOTCUE` -1 or 0-7
* `PLAYLISTS/NODE` tree: folder, playlist, smartlist (`SEARCH_EXPRESSION QUERY`)
* `ENTRY LOCK="1"` = locked track -> bpm not editable

## ◆ COLLECTION.NML (write-back, optional)

off by default (setting). browser edits go to `metadata.json` first; with write-back on they are written into the collection file:

| field | written to |
|---|---|
| title, artist | `ENTRY TITLE`, `ENTRY ARTIST` |
| release, track # | `ALBUM TITLE`, `ALBUM TRACK` |
| genre, label, comment, comment 2, key text | `INFO GENRE`, `LABEL`, `COMMENT`, `RATING`, `KEY` |
| remixer, producer, mix, catalog no | `INFO REMIXER`, `PRODUCER`, `MIX`, `CATALOG_NO` |
| release date | `INFO RELEASE_DATE` (`2011/9/26`) |
| rating 0-5 | `INFO RANKING` (stars × 51, 0 = attribute removed) |
| bpm | `TEMPO BPM` (`%.6f`) |

* the raw `ENTRY` text from loading is searched in the current file and replaced, nothing else changes (encoding, line endings, attribute order, cues, `AUDIO_ID`, `MODIFIED_DATE`)
* changed attributes keep their place, new ones go to the end of the tag, empty values remove the attribute, missing `ALBUM` / `INFO` / `TEMPO` elements are inserted where the collection puts them
* escaping like the collection: `&amp; &lt; &gt; &quot;`, apostrophes stay raw
* entry not found (file saved elsewhere meanwhile) -> skipped and reported
* result is parsed before it replaces the file: must read, same track count. temp file + rename
* backup first: `Backup MINOS-741/collection_YYYY-MM-DD_HHMMSS.nml`, at most one per hour
* never while the library software is running
* hotcues: `CUE_V2` with `HOTCUE` 0-7 (not `TYPE="4"`) replaced, written as `<CUE_V2 NAME="…" DISPL_ORDER="0" TYPE="5" START="%.6f" LEN="%.6f" REPEATS="-1" HOTCUE="n"></CUE_V2>` one per line after the last `CUE_V2`. unchanged cues (6 decimals) keep their text
* hand grid: `TEMPO BPM` + `START` of the first `TYPE="4"` marker, not for `LOCK="1"`
* renamed file: `LOCATION DIR FILE VOLUME VOLUMEID`, key changes with it
* new entry: `ENTRY MODIFIED_DATE MODIFIED_TIME TITLE ARTIST`, `LOCATION`, `ALBUM`, `MODIFICATION_INFO AUTHOR_TYPE="user"`, `INFO`, `TEMPO`, `LOUDNESS`, `MUSICAL_KEY`, `CUE_V2` (grid, hotcues, memory cues), no `AUDIO_ID`. `VOLUMEID` taken from an entry on the same volume
* own playlists: `$ROOT/MINOS-741` folder node, replaced whole, `COUNT` of `$ROOT` + 1 when new, `UUID` = md5 of the node path
* file size + mtime checked against the last read; changed -> reload, conflict rule, then write
* conflict stamp: `ENTRY MODIFIED_DATE` + `MODIFIED_TIME`

## ◆ SMARTLIST QUERIES

```
$COMMENT % "hain" & $IMPORTDATE >= MONTHS_AGO(12)
$COMMENT2 % "» BASIS" | $COMMENT2 % " BASIS"
$FILEPATH STARTS_WITH "/Users/me/Music/2023"
```

* fields: `$ARTIST $TITLE $COMMENT $COMMENT2 $LABEL $GENRE $KEY $BPM $COLOR $RATING $PLAYCOUNT $PLAYED $IMPORTDATE $FILEPATH $FILESTATE` and a few more
* operators: `%` contains, `!%` not contains, `== != >= <= > <`, `STARTS_WITH`, `&` and, `|` or, `!` not, brackets
* functions: `MONTHS_AGO(n)`, `DAYS_AGO(n)`, `TRUE` / `FALSE`

## ◆ HISTORY (read + write)

own file name: `history_2026-10-10-01.nml` (day + session number); copies into the collection's history folder: `history_2026y10m10d_21h05m07s.nml`

* `COLLECTION` -> the full `ENTRY` of every played track, copied 1:1 from the collection (cues, tags, audio id stay intact)
* `PLAYLISTS` -> one playlist `HISTORY`, `TYPE="PROTOCOL"`, each entry with:

```
<EXTENDEDDATA DECK="0" DURATION="148.456314" EXTENDEDTYPE="HistoryData" PLAYEDPUBLIC="1" STARTDATE="132778506" STARTTIME="32592">
```

* `STARTDATE` = year << 16 | month << 8 | day, `STARTTIME` = seconds since midnight, `DECK` 0-3
* own sessions: `~/Library/Application Support/MINOS-741/History`, optional copy into the collection's `History` folder

## ◆ PREPARATION (write)

* archive and playlist export = playlist nml (`TYPE="LIST"`)
