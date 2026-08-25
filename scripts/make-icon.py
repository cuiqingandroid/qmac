#!/usr/bin/env python3
"""生成应用图标（纯标准库，无需 Pillow）。
输出 assets/icon_<size>.png 若干尺寸，供 iconutil 打成 .icns。
"""
import os, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")

# 闪电多边形（0..1 归一化坐标）
BOLT = [(0.56, 0.05), (0.24, 0.55), (0.45, 0.55), (0.38, 0.95),
        (0.74, 0.43), (0.52, 0.43), (0.60, 0.05)]


def write_png(path, pixels, w, h):
    """pixels: list of (r,g,b,a) 行优先"""
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("BBBB", *pixels[y * w + x]) for x in range(w))
        for y in range(h)
    )
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def in_poly(px, py, poly):
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > py) != (y2 > py):
            xin = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
            if px < xin:
                inside = not inside
    return inside


def rounded_rect(px, py, r):
    """1x1 单位方格内的圆角矩形（r 为圆角半径，归一化）"""
    if px < r and py < r:
        return (px - r) ** 2 + (py - r) ** 2 <= r * r
    if px > 1 - r and py < r:
        return (px - (1 - r)) ** 2 + (py - r) ** 2 <= r * r
    if px < r and py > 1 - r:
        return (px - r) ** 2 + (py - (1 - r)) ** 2 <= r * r
    if px > 1 - r and py > 1 - r:
        return (px - (1 - r)) ** 2 + (py - (1 - r)) ** 2 <= r * r
    return True


def render(w, h, shade, ss=4):
    """shade(nx, ny) -> (r,g,b,a) or None；ss 为超采样倍数"""
    out = []
    for y in range(h):
        for x in range(w):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    nx = (x + (sx + 0.5) / ss) / w
                    ny = (y + (sy + 0.5) / ss) / h
                    c = shade(nx, ny)
                    if c:
                        acc[0] += c[0] * c[3]; acc[1] += c[1] * c[3]
                        acc[2] += c[2] * c[3]; acc[3] += c[3]
            n = ss * ss
            a = acc[3] / n
            if a <= 0.5:
                out.append((0, 0, 0, 0))
            else:
                out.append((int(acc[0] / acc[3]), int(acc[1] / acc[3]),
                            int(acc[2] / acc[3]), int(round(a))))
    return out


def tray_shade(rgb):
    def shade(nx, ny):
        # 外框：圆角方框（描边）
        pad = 0.06
        x = (nx - pad) / (1 - 2 * pad)
        y = (ny - pad) / (1 - 2 * pad)
        if 0 <= x <= 1 and 0 <= y <= 1:
            t = 0.16  # 边框厚度
            outer = rounded_rect(x, y, 0.24)
            inner = (t <= x <= 1 - t and t <= y <= 1 - t
                     and rounded_rect((x - t) / (1 - 2 * t), (y - t) / (1 - 2 * t), 0.18))
            if outer and not inner:
                return (*rgb, 255)
        if in_poly(nx, ny, BOLT):
            return (*rgb, 255)
        return None
    return shade


def app_shade(nx, ny):
    if not rounded_rect(nx, ny, 0.22):
        return None
    if in_poly(nx, ny, BOLT):
        return (255, 255, 255, 255)
    # 竖向渐变底
    t = ny
    r = int(88 + (36 - 88) * t)
    g = int(101 + (99 - 101) * t)
    b = int(242 + (235 - 242) * t)
    return (r, g, b, 255)


def main():
    os.makedirs(ASSETS, exist_ok=True)
    jobs = [(f"icon_{s}.png", s, s, app_shade) for s in (16, 32, 64, 128, 256, 512, 1024)]
    for name, w, h, shade in jobs:
        write_png(os.path.join(ASSETS, name), render(w, h, shade), w, h)
        print("generated", name, f"{w}x{h}")


if __name__ == "__main__":
    main()
