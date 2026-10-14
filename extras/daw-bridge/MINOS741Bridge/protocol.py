# MINOS-741 DAW bridge: packet format (protocol v1). Pure python, no DAW modules.
#
# one JSON object per UDP datagram, at most MAX_PACKET bytes:
#   song  every tick (~100 ms): tempo, playing, beat, sig, clips (ids), pos {id: [playing 0/1, position]}
#   clip  on change + round robin every ~2 s: id, track, trackName, name, file, warping, markers [[beat, sec], ...],
#         truncated, loop [start, end], looping, start, end, playing, selected, where (session / arrangement)
#   bye   script stops
# clip position: clip beats (warped), file seconds (not warped).

import json

VERSION = 1
DEFAULT_PORT = 7411
MAX_PACKET = 8000


def _num(v, nd=6):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return 0.0
    if f != f or f in (float("inf"), float("-inf")):
        return 0.0
    return round(f, nd)


def encode(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def song_packet(seq, tempo, playing, beat, sig, positions):
    """positions: list of (clip id, playing, position)"""
    return {
        "v": VERSION, "t": "song", "seq": int(seq),
        "tempo": _num(tempo), "playing": bool(playing), "beat": _num(beat), "sig": int(sig or 4),
        "clips": [p[0] for p in positions],
        "pos": {p[0]: [1 if p[1] else 0, _num(p[2])] for p in positions},
    }


def clip_packet(info):
    """info: dict from snapshot.clip_info. markers are cut so the packet fits MAX_PACKET (truncated = true)"""
    pkt = {
        "v": VERSION, "t": "clip",
        "id": str(info["id"]), "track": int(info.get("track", 0)), "trackName": info.get("trackName", ""),
        "name": info.get("name", ""), "file": info.get("file", ""), "warping": bool(info.get("warping", True)),
        "markers": [[_num(b), _num(s)] for b, s in info.get("markers", [])], "truncated": False,
        "loop": [_num(info.get("loopStart", 0)), _num(info.get("loopEnd", 0))], "looping": bool(info.get("looping", False)),
        "start": _num(info.get("start", 0)), "end": _num(info.get("end", 0)),
        "playing": bool(info.get("playing", False)), "selected": bool(info.get("selected", False)),
        "where": info.get("where", "session"),
    }
    data = encode(pkt)
    while len(data) > MAX_PACKET and pkt["markers"]:
        keep = max(0, len(pkt["markers"]) * MAX_PACKET // len(data) - 1)
        pkt["markers"] = pkt["markers"][:keep]
        pkt["truncated"] = True
        data = encode(pkt)
    if len(data) > MAX_PACKET:
        pkt["name"] = pkt["name"][:64]
        pkt["trackName"] = pkt["trackName"][:64]
    return pkt


def bye_packet():
    return {"v": VERSION, "t": "bye"}
