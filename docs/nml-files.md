# NML FILES

## ◆ COLLECTION.NML (read)

* `COLLECTION/ENTRY` -> `LOCATION` (volume + dir + file, dir uses `/:` as separator), `INFO`, `TEMPO`, `LOUDNESS`, `MUSICAL_KEY`, `CUE_V2`
* track key = `VOLUME + DIR + FILE`, the same key playlists use in `PRIMARYKEY`
* `INFO COMMENT` = comment 1, `INFO RATING` = comment 2
* `MUSICAL_KEY` 0-11 major (c…b), 12-23 minor -> shown as open key (1d…12m)
* `CUE_V2 TYPE`: 0 cue, 1 fade in, 2 fade out, 3 load, 4 grid, 5 loop. `START` / `LEN` in ms, `HOTCUE` -1 or 0-7
* `PLAYLISTS/NODE` tree: folder, playlist, smartlist (`SEARCH_EXPRESSION QUERY`)
* the collection file itself is never written

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
