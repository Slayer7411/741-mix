"""Eigene Zuordnungen (CMAI/CMAD) der X1-MK2-Geräte aus einer Traktor-TSI lesen."""
import struct, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from tsi_dump import load, chunks, utf16

def find(buf, off, end, path):
    """Alle Chunks entlang eines Tag-Pfads (mit optionalem 4-Byte-Zähler)"""
    if not path: return [(off, end)]
    res = []
    for tag, o, ln in chunks(buf, off, end):
        if tag == path[0]:
            res += find(buf, o, o + ln, path[1:])
            res += find(buf, o + 4, o + ln, path[1:]) if len(path) > 1 else []
    return res

def i32(b, o): return struct.unpack('>i', b[o:o+4])[0]
def f32(b, o): return struct.unpack('>f', b[o:o+4])[0]

b = load(sys.argv[1])
for tag, o, ln in chunks(b, 0, len(b)):
    for t2, o2, l2 in chunks(b, o, o + ln):  # DIOI, DEVS
        if t2 != b'DEVS': continue
        for t3, o3, l3 in chunks(b, o2 + 4, o2 + l2):
            name, p = utf16(b, o3)
            if 'X1 MK2' not in name: continue
            print('=' * 70); print(name)
            for t4, o4, l4 in chunks(b, p, o3 + l3):      # DDAT
                ctrl = {}
                for t5, o5, l5 in chunks(b, o4, o4 + l4):
                    if t5 == b'DDIC': print('Kommentar:', utf16(b, o5)[0])
                    if t5 == b'DDCB':
                        for t6, o6, l6 in chunks(b, o5, o5 + l5):
                            if t6 == b'DCBM':
                                for t7, o7, l7 in chunks(b, o6 + 4, o6 + l6):
                                    cid = i32(b, o7); nm, _ = utf16(b, o7 + 4); ctrl[cid] = nm
                        for t6, o6, l6 in chunks(b, o5, o5 + l5):
                            if t6 != b'CMAS': continue
                            for t7, o7, l7 in chunks(b, o6 + 4, o6 + l6):
                                cid, typ, cmd = i32(b, o7), i32(b, o7 + 4), i32(b, o7 + 8)
                                d = o7 + 12 + 8   # CMAD-Payload
                                f = [i32(b, d + 4 * k) for k in range(30)]
                                print(f"{ctrl.get(cid, cid):28s} {'IN ' if typ == 0 else 'OUT'} cmd={cmd:5d}  raw={f}")
