#!/usr/bin/env python3
"""Turns a Ukraine oblast GeoJSON into a compact {name: [[lon, lat], ...]} map used by the app.
Usage: simplify_geo.py <in.geojson> <out.json> [tolerance_deg]"""
import json, sys


def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    (x1, y1), (x2, y2) = pts[0], pts[-1]
    dx, dy = x2 - x1, y2 - y1
    norm = (dx * dx + dy * dy) ** 0.5 or 1e-12
    dmax, idx = 0, 0
    for i in range(1, len(pts) - 1):
        x0, y0 = pts[i]
        d = abs(dy * x0 - dx * y0 + x2 * y1 - y2 * x1) / norm
        if d > dmax:
            dmax, idx = d, i
    if dmax > eps:
        return rdp(pts[: idx + 1], eps)[:-1] + rdp(pts[idx:], eps)
    return [pts[0], pts[-1]]


src, dst = sys.argv[1], sys.argv[2]
eps = float(sys.argv[3]) if len(sys.argv) > 3 else 0.015
out = {}
for f in json.load(open(src))["features"]:
    g = f["geometry"]
    polys = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]
    ring = max((r for p in polys for r in p), key=len)  # mainland outline (some files list islands as extra rings)
    if ring[0] == ring[-1]:
        ring = ring[:-1]
    # A closed ring has identical endpoints, so simplify it as two open halves.
    h = len(ring) // 2
    pts = rdp(ring[: h + 1], eps)[:-1] + rdp(ring[h:] + [ring[0]], eps)[:-1]
    out[f["properties"]["name"]] = [[round(x, 3), round(y, 3)] for x, y in pts]
json.dump(out, open(dst, "w"), ensure_ascii=False, separators=(",", ":"))
print(len(out), "regions,", sum(len(v) for v in out.values()), "points")
