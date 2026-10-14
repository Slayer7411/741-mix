# MINOS-741 DAW bridge: remote script (control surface without hardware). Sends the state of the playing / selected
# audio clips (warp markers, loop, position) and the song (tempo, beat) to MINOS-741 via UDP on 127.0.0.1.
# Never blocks: non-blocking socket, small packets, every error is caught and written to the DAW log.

import json
import os
import socket

from _Framework.ControlSurface import ControlSurface

from . import protocol, snapshot

REFRESH_TICKS = 10      # clip list rebuilt every ~1 s (ticks of ~100 ms)


def _port():
    try:
        with open(os.path.join(os.path.dirname(__file__), "config.json")) as f:
            return int(json.load(f).get("port", protocol.DEFAULT_PORT))
    except Exception:
        return protocol.DEFAULT_PORT


class Bridge(ControlSurface):
    def __init__(self, c_instance):
        ControlSurface.__init__(self, c_instance)
        self._addr = ("127.0.0.1", _port())
        self._sock = None
        self._seq = 0
        self._tick = 0
        self._clips = []          # [(clip, id, track index, track name, where, selected)]
        self._dirty = set()       # clip ids to send on the next tick
        self._listeners = []      # [(object, remove function name, callback)]
        self._song_listeners = []
        try:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._sock.setblocking(False)
        except Exception as e:
            self._log("socket: %s" % e)
        self._watch_song()
        self._refresh()
        self._log("started, port %d" % self._addr[1])

    # --- sending

    def _send(self, pkt):
        if self._sock is None:
            return
        try:
            self._sock.sendto(protocol.encode(pkt), self._addr)
        except (BlockingIOError, ConnectionRefusedError, OSError):
            pass    # receiver not running or buffer full: drop, the next tick sends again
        except Exception as e:
            self._log("send: %s" % e)

    def _log(self, s):
        try:
            self.log_message("MINOS741Bridge: " + s)
        except Exception:
            pass

    # --- listeners

    def _listen(self, obj, prop, cb):
        add, remove = "add_%s_listener" % prop, "remove_%s_listener" % prop
        try:
            if hasattr(obj, add) and not getattr(obj, "%s_has_listener" % prop)(cb):
                getattr(obj, add)(cb)
                return (obj, remove, cb)
        except Exception as e:
            self._log("listen %s: %s" % (prop, e))
        return None

    def _unlisten(self, items):
        for obj, remove, cb in items:
            try:
                getattr(obj, remove)(cb)
            except Exception:
                pass

    def _watch_song(self):
        song = self.song()
        for obj, prop in ((song, "tempo"), (song, "tracks"), (song, "is_playing"), (song.view, "detail_clip")):
            r = self._listen(obj, prop, self._structure_changed)
            if r:
                self._song_listeners.append(r)

    def _structure_changed(self):
        self._tick = REFRESH_TICKS - 1   # rebuild on the next tick (never inside a notification)

    def _refresh(self):
        try:
            self._unlisten(self._listeners)
            self._listeners = []
            song = self.song()
            for track in song.tracks:
                r = self._listen(track, "playing_slot_index", self._structure_changed)
                if r:
                    self._listeners.append(r)
            old = set(c[1] for c in self._clips)
            self._clips = snapshot.collect(song)
            for entry in self._clips:
                clip, cid = entry[0], entry[1]
                if cid not in old:
                    self._dirty.add(cid)
                for prop in ("warp_markers", "loop_start", "loop_end", "start_marker", "end_marker", "looping", "name",
                             "warping", "playing_status"):
                    r = self._listen(clip, prop, self._make_dirty(cid))
                    if r:
                        self._listeners.append(r)
        except Exception as e:
            self._log("refresh: %s" % e)

    def _make_dirty(self, cid):
        def cb():
            self._dirty.add(cid)
        return cb

    # --- timer (~100 ms, called by the DAW)

    def update_display(self):
        ControlSurface.update_display(self)
        try:
            self._tick += 1
            if self._tick >= REFRESH_TICKS:
                self._tick = 0
                self._refresh()
            song = self.song()
            pos = []
            for clip, cid, ti, tname, where, sel in self._clips:
                p, x = snapshot.position(clip)
                pos.append((cid, p, x))
            self._seq += 1
            sig = getattr(song, "signature_numerator", 4)
            self._send(protocol.song_packet(self._seq, song.tempo, song.is_playing, song.current_song_time, sig, pos))
            if self._clips and self._seq % 2 == 0:
                # round robin: one clip again every 200 ms (receiver started later, lost packets)
                self._dirty.add(self._clips[(self._seq // 2) % len(self._clips)][1])
            for clip, cid, ti, tname, where, sel in self._clips:
                if cid in self._dirty:
                    self._send(protocol.clip_packet(snapshot.clip_info(clip, cid, ti, tname, where, sel)))
            self._dirty.clear()
        except Exception as e:
            self._log("tick: %s" % e)

    def disconnect(self):
        try:
            self._send(protocol.bye_packet())
            self._unlisten(self._listeners)
            self._unlisten(self._song_listeners)
            if self._sock is not None:
                self._sock.close()
        except Exception as e:
            self._log("disconnect: %s" % e)
        ControlSurface.disconnect(self)
