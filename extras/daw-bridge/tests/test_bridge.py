# offline tests for the DAW bridge (no DAW): serialization, object model access with plain objects, the remote
# script's tick against a local UDP socket. run: python3 -m unittest discover -s extras/daw-bridge/tests
# MINOS741_WRITE_FIXTURES=1 writes the packets used by the swift tests to Tests/Fixtures/DAW.

import json
import os
import socket
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
FIXTURES = os.path.join(HERE, "..", "..", "..", "Tests", "Fixtures", "DAW")

from MINOS741Bridge import protocol, snapshot  # noqa: E402


class Obj:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def marker(b, s):
    return Obj(beat_time=b, sample_time=s)


def make_song(playing=True):
    loop = Obj(_live_ptr=101, is_audio_clip=True, name="Loop 128", file_path="/tmp/minos-daw/loop.wav", warping=True,
               warp_markers=(marker(0.0, 0.5), marker(32.0, 15.5), marker(32.03125, 15.514648)),
               loop_start=0.0, loop_end=16.0, looping=True, start_marker=0.0, end_marker=32.0,
               is_playing=True, playing_position=4.5)
    midi = Obj(_live_ptr=102, is_audio_clip=False, name="Bass")
    arr = Obj(_live_ptr=103, is_audio_clip=True, name="Track", file_path="/tmp/minos-daw/track.flac", warping=True,
              warp_markers=(marker(-4.0, 0.0), marker(0.0, 1.875), marker(64.0, 31.875)), loop_start=0.0, loop_end=64.0,
              looping=False, start_marker=-4.0, end_marker=64.0, is_playing=True, playing_position=10.25,
              start_time=8.0, end_time=80.0)
    tracks = [
        Obj(name="Drums", clip_slots=[Obj(clip=None), Obj(clip=loop)], playing_slot_index=1, arrangement_clips=()),
        Obj(name="Bass", clip_slots=[Obj(clip=midi)], playing_slot_index=0, arrangement_clips=()),
        Obj(name="Edit", clip_slots=[], playing_slot_index=-1, arrangement_clips=(arr,)),
    ]
    return Obj(tracks=tracks, view=Obj(detail_clip=loop), current_song_time=12.0, is_playing=playing, tempo=128.0,
               signature_numerator=4)


class ProtocolTests(unittest.TestCase):
    def test_collect(self):
        got = snapshot.collect(make_song())
        self.assertEqual([(c[1], c[2], c[3], c[4], c[5]) for c in got],
                         [("c101", 0, "Drums", "session", True), ("c103", 2, "Edit", "arrangement", False)])
        # stopped song: no arrangement clip
        self.assertEqual([c[1] for c in snapshot.collect(make_song(playing=False))], ["c101"])

    def test_missing_properties(self):
        # older model without warp markers / arrangement clips, objects raising on access
        class Broken:
            @property
            def name(self):
                raise RuntimeError("deleted")
        clip = Obj(_live_ptr=7, is_audio_clip=True)
        info = snapshot.clip_info(clip, "c7", 0, "", "session", False)
        self.assertEqual(info["markers"], [])
        self.assertEqual(snapshot._get(Broken(), "name", "x"), "x")
        song = Obj(tracks=[Obj(name="T", clip_slots=[Obj(clip=clip)], playing_slot_index=0)], view=None)
        self.assertEqual([c[1] for c in snapshot.collect(song)], ["c7"])

    def test_packets(self):
        song = make_song()
        clips = snapshot.collect(song)
        pkt = protocol.clip_packet(snapshot.clip_info(*clips[0]))
        self.assertEqual(pkt["markers"], [[0.0, 0.5], [32.0, 15.5], [32.03125, 15.514648]])
        self.assertEqual(pkt["loop"], [0.0, 16.0])
        self.assertFalse(pkt["truncated"])
        s = protocol.song_packet(7, 128.0, True, 12.0, 4, [(c[1],) + snapshot.position(c[0]) for c in clips])
        self.assertEqual(s["clips"], ["c101", "c103"])
        self.assertEqual(s["pos"]["c101"], [1, 4.5])
        self.assertEqual(json.loads(protocol.encode(s).decode()), s)
        if os.environ.get("MINOS741_WRITE_FIXTURES") == "1":
            os.makedirs(FIXTURES, exist_ok=True)
            for name, p in (("bridge-song.json", s), ("bridge-clip.json", pkt),
                            ("bridge-clip-arrangement.json", protocol.clip_packet(snapshot.clip_info(*clips[1])))):
                with open(os.path.join(FIXTURES, name), "wb") as f:
                    f.write(protocol.encode(p))
        # committed fixtures = what this code sends
        path = os.path.join(FIXTURES, "bridge-song.json")
        if os.path.exists(path):
            with open(path, "rb") as f:
                self.assertEqual(json.loads(f.read().decode()), s)

    def test_truncation(self):
        many = [(i * 1.0, i * 0.5) for i in range(2000)]
        pkt = protocol.clip_packet({"id": "c1", "markers": many, "name": "x" * 50})
        self.assertTrue(pkt["truncated"])
        self.assertLessEqual(len(protocol.encode(pkt)), protocol.MAX_PACKET)
        self.assertGreater(len(pkt["markers"]), 100)

    def test_bad_numbers(self):
        pkt = protocol.clip_packet({"id": "c1", "markers": [(float("nan"), 1.0)], "loopStart": None})
        self.assertEqual(pkt["markers"], [[0.0, 1.0]])
        self.assertEqual(pkt["loop"][0], 0.0)


class ScriptTests(unittest.TestCase):
    """the remote script with a stand-in for the DAW's framework module"""

    def setUp(self):
        fw = types.ModuleType("_Framework")
        cs = types.ModuleType("_Framework.ControlSurface")

        class ControlSurface:
            def __init__(self, c_instance):
                self.logged = []

            def song(self):
                return self._song

            def log_message(self, s):
                self.logged.append(s)

            def update_display(self):
                pass

            def disconnect(self):
                pass

        cs.ControlSurface = ControlSurface
        sys.modules["_Framework"] = fw
        sys.modules["_Framework.ControlSurface"] = cs
        self.rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rx.bind(("127.0.0.1", 0))
        self.rx.settimeout(1)

    def tearDown(self):
        self.rx.close()
        for m in ("_Framework", "_Framework.ControlSurface", "MINOS741Bridge.bridge"):
            sys.modules.pop(m, None)

    def test_ticks(self):
        from MINOS741Bridge import bridge
        bridge.Bridge.song = lambda self: self._song
        bridge.ControlSurface._song = make_song()
        b = bridge.Bridge(None)
        b._addr = ("127.0.0.1", self.rx.getsockname()[1])
        for _ in range(3):
            b.update_display()
        got = []
        try:
            while True:
                got.append(json.loads(self.rx.recv(65536).decode()))
                self.rx.settimeout(0.2)
        except socket.timeout:
            pass
        types_ = [p["t"] for p in got]
        self.assertEqual(types_.count("song"), 3)
        clips = [p for p in got if p["t"] == "clip"]
        self.assertEqual(sorted(set(p["id"] for p in clips)), ["c101", "c103"])
        b.disconnect()
        self.assertEqual(json.loads(self.rx.recv(65536).decode())["t"], "bye")
        self.assertFalse(any("tick:" in s for s in b.logged), b.logged)


if __name__ == "__main__":
    unittest.main()
