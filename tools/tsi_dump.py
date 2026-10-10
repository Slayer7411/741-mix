"""Traktor-TSI: DeviceIO.Config.Controller dekodieren und Chunk-Baum ausgeben (nur lesen)."""
import base64, re, struct, sys

CONTAINERS = {b'DIOM', b'DEVS', b'DEVI', b'DDAT', b'DDCB', b'CMAS', b'CMAI', b'DDCI', b'DDCO', b'DCDT', b'DDIC',
              b'DVST', b'DOCS', b'DICS', b'DCBM', b'DDDC'}

def load(path):
    s = open(path, encoding='utf-8', errors='replace').read()
    m = re.search(r'Name="DeviceIO.Config.Controller" Type="3" Value="([^"]*)"', s)
    return base64.b64decode(m.group(1))

def chunks(buf, off, end):
    while off + 8 <= end:
        tag = buf[off:off+4]
        ln = struct.unpack('>I', buf[off+4:off+8])[0]
        if not re.fullmatch(rb'[A-Z0-9]{4}', tag) or off + 8 + ln > end:
            return
        yield tag, off + 8, ln
        off += 8 + ln

def looks_container(buf, off, ln):
    # Container: Payload beginnt wieder mit einem Tag, ggf. nach 4-Byte-Zähler
    for skip in (0, 4):
        if ln >= skip + 8 and re.fullmatch(rb'[A-Z0-9]{4}', buf[off+skip:off+skip+4]):
            sub = struct.unpack('>I', buf[off+skip+4:off+skip+8])[0]
            if off + skip + 8 + sub <= off + ln:
                return skip
    return None

def utf16(buf, off):
    n = struct.unpack('>I', buf[off:off+4])[0]
    return buf[off+4:off+4+2*n].decode('utf-16-be', errors='replace'), off + 4 + 2*n

def dump(buf, off, end, depth=0, out=None, maxdepth=9):
    for tag, o, ln in chunks(buf, off, end):
        skip = looks_container(buf, o, ln) if depth < maxdepth else None
        info = ''
        if skip is None:
            raw = buf[o:o+min(ln, 48)]
            try:
                s, _ = utf16(buf, o)
                if 0 < len(s) < 200 and s.isprintable(): info = repr(s)
            except Exception: pass
            if not info: info = raw.hex()
        else:
            info = f'[{struct.unpack(">I", buf[o:o+4])[0]}]' if skip == 4 else ''
        print('  ' * depth + tag.decode(), ln, info, file=out)
        if tag == b'DEVI' and depth < maxdepth:
            _, o2 = utf16(buf, o)
            dump(buf, o2, o + ln, depth + 1, out, maxdepth)
            continue
        if skip is not None:
            dump(buf, o + skip, o + ln, depth + 1, out, maxdepth)

if __name__ == '__main__':
    b = load(sys.argv[1])
    print('bytes', len(b))
    dump(b, 0, len(b))
