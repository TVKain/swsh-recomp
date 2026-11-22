"""The app icon: a white ball outline on a blue rounded tile (the launcher draws the same mark with vectors:
runtime/ui/launcher_lg.mm logo_mark). Writes docs/icon/icon_1024.png and docs/icon/icon.ico (PNG-compressed sizes
16..256). Pure Python (zlib only): python tools/make_icon.py"""
import math
import struct
import zlib

BLUE = (37, 99, 235)
WHITE = (255, 255, 255)


def coverage(size, x, y):
    """(tile alpha, white alpha) at pixel centre x, y of a size x size icon"""
    s = size
    c = s / 2
    # the tile: a rounded square with a small margin
    m, r = s * 0.04, s * 0.22
    dx = max(abs(x - c) - (c - m - r), 0)
    dy = max(abs(y - c) - (c - m - r), 0)
    tile = r - math.hypot(dx, dy)
    # the ball: an outer ring, the band across it (a gap around the button), the button ring
    d = math.hypot(x - c, y - c)
    R, t = s * 0.30, s * 0.055
    ring = t / 2 - abs(d - R)
    band = t / 2 - abs(y - c)
    band = min(band, R - d, d - s * 0.14)  # (inside the ring, outside the button's gap)
    button = t / 2 - abs(d - s * 0.075)
    white = max(ring, band, button)
    return tile, white


def render(size, ss=4):
    px = bytearray()
    for j in range(size):
        px.append(0)  # PNG filter: none
        for i in range(size):
            ta = wa = 0.0
            for sj in range(ss):
                for si in range(ss):
                    x, y = i + (si + 0.5) / ss, j + (sj + 0.5) / ss
                    tile, white = coverage(size, x, y)
                    if tile > 0:
                        ta += 1
                        if white > 0:
                            wa += 1
            ta /= ss * ss
            wa /= ss * ss
            f = wa / ta if ta else 0
            col = [round(BLUE[k] * (1 - f) + WHITE[k] * f) for k in range(3)]
            px += bytes(col + [round(ta * 255)])
    return bytes(px)


def png(size, raw):
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


if __name__ == '__main__':
    big = png(1024, render(1024, 2))
    open('docs/icon/icon_1024.png', 'wb').write(big)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    imgs = [png(s, render(s, 8 if s <= 64 else 4)) for s in sizes]
    head = struct.pack('<HHH', 0, 1, len(sizes))
    off = 6 + 16 * len(sizes)
    dirs = b''
    for s, data in zip(sizes, imgs):
        dirs += struct.pack('<BBBBHHII', s % 256, s % 256, 0, 0, 1, 32, len(data), off)
        off += len(data)
    open('docs/icon/icon.ico', 'wb').write(head + dirs + b''.join(imgs))
    print('docs/icon/icon_1024.png, docs/icon/icon.ico')
