"""Reel Roku UI pieces: 9-patch pills, focus ring, card shadow, rating badge outline, scrims, and the
search, star and watched glyphs.

Standard library only. Output is deterministic, so rerunning leaves the files byte-identical.
Roku reads a .9.png with a 1px border: black pixels on the top row and left column mark the
region that stretches; everything outside that region keeps its pixel size.
"""
from pathlib import Path
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
IMAGES = ROOT / 'channel' / 'images'
SAMPLES = 4
SCRIM_RGB = (12, 12, 14)


def encode_png(width, height, rows):
    raw = b''.join(b'\x00' + bytes(row) for row in rows)

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xFFFFFFFF)

    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


def rounded_box_distance(x, y, left, top, right, bottom, radius):
    """Signed distance to a rounded rectangle; negative inside."""
    cx = (left + right) / 2
    cy = (top + bottom) / 2
    qx = abs(x - cx) - ((right - left) / 2 - radius)
    qy = abs(y - cy) - ((bottom - top) / 2 - radius)
    outside = math.hypot(max(qx, 0), max(qy, 0))
    return outside + min(max(qx, qy), 0) - radius


def coverage(width, height, test):
    """Antialiased alpha plane (0..1) by supersampling a point test."""
    plane = []
    for py in range(height):
        row = []
        for px in range(width):
            hits = 0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    if test(px + (sx + 0.5) / SAMPLES, py + (sy + 0.5) / SAMPLES):
                        hits += 1
            row.append(hits / (SAMPLES * SAMPLES))
        plane.append(row)
    return plane


def box_blur(plane, radius):
    height = len(plane)
    width = len(plane[0])
    for _ in range(3):
        horizontal = []
        for row in plane:
            out = []
            for x in range(width):
                lo = max(0, x - radius)
                hi = min(width - 1, x + radius)
                out.append(sum(row[lo:hi + 1]) / (2 * radius + 1))
            horizontal.append(out)
        plane = []
        for y in range(height):
            out = []
            for x in range(width):
                lo = max(0, y - radius)
                hi = min(height - 1, y + radius)
                out.append(sum(horizontal[j][x] for j in range(lo, hi + 1)) / (2 * radius + 1))
            plane.append(out)
    return plane


def to_rows(plane, rgb):
    return [[v for alpha in row for v in (rgb[0], rgb[1], rgb[2], round(alpha * 255))] for row in plane]


def nine_patch(plane, rgb, stretch_start, stretch_end):
    """Wrap an alpha plane in the 1px marker border; stretch_* are inner pixel indices."""
    height = len(plane)
    width = len(plane[0])
    rows = [[0] * (4 * (width + 2))]
    for x in range(stretch_start, stretch_end):
        rows[0][4 * (x + 1) + 3] = 255
    body = to_rows(plane, rgb)
    for y in range(height):
        marker = [0, 0, 0, 255] if stretch_start <= y < stretch_end else [0, 0, 0, 0]
        rows.append(marker + body[y] + [0, 0, 0, 0])
    rows.append([0] * (4 * (width + 2)))
    return width + 2, height + 2, rows


def write(name, width, height, rows):
    (IMAGES / name).write_bytes(encode_png(width, height, rows))


def filled(size, radius):
    return coverage(size, size, lambda x, y: rounded_box_distance(x, y, 0, 0, size, size, radius) <= 0)


def ring(size, radius, stroke):
    def inside(x, y):
        d = rounded_box_distance(x, y, 0, 0, size, size, radius)
        return -stroke <= d <= 0
    return coverage(size, size, inside)


def shadow(size, inset, radius, blur, strength):
    base = coverage(size, size, lambda x, y: rounded_box_distance(x, y, inset, inset, size - inset, size - inset, radius) <= 0)
    soft = box_blur(base, blur)
    return [[v * strength for v in row] for row in soft]


def gradient(width, height, vertical, alpha_at):
    length = height if vertical else width
    plane = []
    for y in range(height):
        row = []
        for x in range(width):
            t = (y if vertical else x) / (length - 1)
            row.append(alpha_at(t))
        plane.append(row)
    return plane


def ease(t):
    return 0.5 - 0.5 * math.cos(math.pi * min(max(t, 0.0), 1.0))


def segment_distance(x, y, start, end):
    ax, ay = start
    bx, by = end
    dx, dy = bx - ax, by - ay
    t = min(max(((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy), 0.0), 1.0)
    return math.hypot(x - (ax + t * dx), y - (ay + t * dy))


def search_glyph(size):
    """A bare magnifying glass: a ring and a round-capped handle, drawn white for blendColor tinting."""
    centre, radius, stroke = size * 0.42, size * 0.29, size * 0.08

    def inside(x, y):
        ring = abs(math.hypot(x - centre, y - centre) - radius) <= stroke / 2
        start = centre + radius * 0.75
        handle = segment_distance(x, y, (start, start), (size * 0.86, size * 0.86)) <= stroke / 2
        return ring or handle
    return coverage(size, size, inside)


def watched_badge(size):
    """A filled mint disc with a dark check cut into it, the watched mark the Apple clients use."""
    disc = coverage(size, size, lambda x, y: math.hypot(x - size / 2, y - size / 2) <= size / 2)
    points = [(size * 0.29, size * 0.52), (size * 0.44, size * 0.66), (size * 0.72, size * 0.37)]
    check = coverage(size, size, lambda x, y: min(segment_distance(x, y, points[0], points[1]),
                                                  segment_distance(x, y, points[1], points[2])) <= size * 0.055)
    mint, dark = (150, 232, 207), SCRIM_RGB
    rows = []
    for disc_row, check_row in zip(disc, check):
        row = []
        for d, c in zip(disc_row, check_row):
            rgb = [round(m * (1 - c) + k * c) for m, k in zip(mint, dark)]
            row.extend(rgb + [round(d * 255)])
        rows.append(row)
    return rows


def star_glyph(size):
    """A five-point star for the community score, drawn white for blendColor tinting."""
    cx, cy = size / 2, size * 0.53
    outer, inner = size * 0.5, size * 0.21
    corners = []
    for i in range(10):
        radius = outer if i % 2 == 0 else inner
        angle = -math.pi / 2 + i * math.pi / 5
        corners.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))

    def inside(x, y):
        hit = False
        for (ax, ay), (bx, by) in zip(corners, corners[1:] + corners[:1]):
            if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay):
                hit = not hit
        return hit
    return coverage(size, size, inside)


def main():
    IMAGES.mkdir(parents=True, exist_ok=True)
    white = (255, 255, 255)
    width, height, rows = nine_patch(filled(64, 30), white, 30, 34)
    write('fill-pill.9.png', width, height, rows)
    width, height, rows = nine_patch(filled(40, 12), white, 12, 28)
    write('fill-12.9.png', width, height, rows)
    width, height, rows = nine_patch(ring(48, 16, 3), white, 16, 32)
    write('ring-card.9.png', width, height, rows)
    width, height, rows = nine_patch(shadow(128, 40, 14, 7, 0.62), (0, 0, 0), 48, 80)
    write('shadow-card.9.png', width, height, rows)
    left = gradient(256, 4, False, lambda t: 0.94 * (1 - ease(t)))
    write('scrim-left.png', 256, 4, to_rows(left, SCRIM_RGB))
    bottom = gradient(4, 256, True, lambda t: 0.96 * ease(t))
    write('scrim-bottom.png', 4, 256, to_rows(bottom, SCRIM_RGB))
    top = gradient(4, 128, True, lambda t: 0.78 * (1 - ease(t)))
    write('scrim-top.png', 4, 128, to_rows(top, SCRIM_RGB))
    write('search.png', 64, 64, to_rows(search_glyph(64), white))
    write('watched.png', 36, 36, watched_badge(36))
    width, height, rows = nine_patch(ring(26, 6, 2), white, 6, 20)
    write('badge.9.png', width, height, rows)
    write('star.png', 22, 22, to_rows(star_glyph(22), white))
    print('10 UI images written')


if __name__ == '__main__':
    main()
