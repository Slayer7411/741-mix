# MINOS-741 DAW bridge: reads the object model (song, tracks, clip slots, clips). Every access goes through _get, so a
# missing property (older DAW version) or a deleted object never raises. No DAW modules: tests pass plain objects.


def _get(obj, name, default=None):
    try:
        v = getattr(obj, name)
    except Exception:
        return default
    return default if v is None else v


def ptr(obj):
    """stable id of an object of the object model (falls back to the python id)"""
    p = _get(obj, "_live_ptr")
    return p if p is not None else id(obj)


def is_audio_clip(clip):
    return clip is not None and bool(_get(clip, "is_audio_clip", False))


def markers(clip):
    out = []
    for m in _get(clip, "warp_markers", ()) or ():
        b, s = _get(m, "beat_time"), _get(m, "sample_time")
        if b is not None and s is not None:
            out.append((float(b), float(s)))
    return out


def clip_info(clip, cid, track_index, track_name, where, selected):
    return {
        "id": cid, "track": track_index, "trackName": track_name, "name": _get(clip, "name", ""),
        "file": _get(clip, "file_path", ""), "warping": bool(_get(clip, "warping", True)), "markers": markers(clip),
        "loopStart": _get(clip, "loop_start", 0.0), "loopEnd": _get(clip, "loop_end", 0.0),
        "looping": bool(_get(clip, "looping", False)), "start": _get(clip, "start_marker", 0.0),
        "end": _get(clip, "end_marker", 0.0), "playing": bool(_get(clip, "is_playing", False)),
        "selected": selected, "where": where,
    }


def position(clip):
    return bool(_get(clip, "is_playing", False)), float(_get(clip, "playing_position", 0.0) or 0.0)


def collect(song):
    """audio clips to report: per track the playing session clip, the arrangement clip under the play head (while the
    song plays) and the selected clip. returns [(clip, id, track index, track name, where, selected)]"""
    out, seen = [], set()
    view = _get(song, "view")
    detail = _get(view, "detail_clip") if view is not None else None
    detail_ptr = ptr(detail) if is_audio_clip(detail) else None
    now = float(_get(song, "current_song_time", 0.0) or 0.0)
    playing = bool(_get(song, "is_playing", False))

    def add(clip, ti, tname, where):
        p = ptr(clip)
        if p in seen:
            return
        seen.add(p)
        out.append((clip, "c%s" % p, ti, tname, where, p == detail_ptr))

    for ti, track in enumerate(_get(song, "tracks", ()) or ()):
        tname = _get(track, "name", "")
        slots = _get(track, "clip_slots", ()) or ()
        si = _get(track, "playing_slot_index", -1)
        if isinstance(si, int) and 0 <= si < len(slots):
            clip = _get(slots[si], "clip")
            if is_audio_clip(clip):
                add(clip, ti, tname, "session")
        if playing:
            for clip in _get(track, "arrangement_clips", ()) or ():
                if is_audio_clip(clip) and _get(clip, "start_time", 0.0) <= now < _get(clip, "end_time", 0.0):
                    add(clip, ti, tname, "arrangement")
        if detail_ptr is not None:
            for slot in slots:
                c = _get(slot, "clip")
                if c is not None and ptr(c) == detail_ptr:
                    add(c, ti, tname, "session")
            for c in _get(track, "arrangement_clips", ()) or ():
                if ptr(c) == detail_ptr:
                    add(c, ti, tname, "arrangement")
    return out
