#!/usr/bin/env python3
"""Convert a KML feed into GeoJSON, CSV, and GPX.

Usage: convert.py <input.kml> <output_dir>
Emits exodussail.geojson, exodussail.csv, exodussail.gpx in <output_dir>.
"""
from __future__ import annotations

import csv
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

KML_NS = "{http://www.opengis.net/kml/2.2}"


def parse(kml_path: Path) -> list[dict]:
    tree = ET.parse(kml_path)
    root = tree.getroot()
    points: list[dict] = []
    for pm in root.iter(f"{KML_NS}Placemark"):
        pt = pm.find(f"{KML_NS}Point")
        if pt is None:
            continue
        data: dict = {}
        for d in pm.iter(f"{KML_NS}Data"):
            value_el = d.find(f"{KML_NS}value")
            data[d.get("name") or ""] = (
                (value_el.text or "").strip() if value_el is not None else ""
            )
        when_el = pm.find(f"{KML_NS}TimeStamp/{KML_NS}when")
        data["_when"] = (
            when_el.text.strip() if when_el is not None and when_el.text else ""
        )
        coords_el = pt.find(f"{KML_NS}coordinates")
        if coords_el is not None and coords_el.text:
            lon, lat, *rest = coords_el.text.strip().split(",")
            data["_lon"] = float(lon)
            data["_lat"] = float(lat)
            data["_ele"] = float(rest[0]) if rest else None
        points.append(data)
    points.sort(key=lambda d: d.get("_when", ""))
    return points


def num(s: str) -> float | None:
    """Pull the first numeric token from strings like '8.0 km/h' or '45.00 ° True'."""
    if not s:
        return None
    for token in s.split():
        try:
            return float(token)
        except ValueError:
            continue
    return None


def to_geojson(points: list[dict]) -> dict:
    valid = [p for p in points if "_lon" in p]
    coords = [[p["_lon"], p["_lat"], p["_ele"] or 0] for p in valid]
    times = [p.get("_when", "") for p in valid]
    line = {
        "type": "Feature",
        "geometry": {"type": "LineString", "coordinates": coords},
        "properties": {
            "name": "Track",
            "point_count": len(coords),
            "first_time": times[0] if times else None,
            "last_time": times[-1] if times else None,
            "coordTimes": times,
        },
    }
    features = [line]
    if valid:
        last = valid[-1]
        features.append(
            {
                "type": "Feature",
                "geometry": {
                    "type": "Point",
                    "coordinates": [last["_lon"], last["_lat"], last["_ele"] or 0],
                },
                "properties": {
                    "name": last.get("Name", ""),
                    "time": last.get("_when", ""),
                    "velocity_kmh": num(last.get("Velocity", "")),
                    "course_deg": num(last.get("Course", "")),
                    "elevation_m": last["_ele"],
                    "event": last.get("Event", ""),
                    "in_emergency": last.get("In Emergency", "") == "True",
                    "valid_gps_fix": last.get("Valid GPS Fix", "") == "True",
                    "device_type": last.get("Device Type", ""),
                    "is_latest": True,
                },
            }
        )
    return {"type": "FeatureCollection", "features": features}


CSV_COLS = [
    "when_utc", "latitude", "longitude", "elevation_m",
    "velocity", "course", "valid_gps_fix", "in_emergency",
    "event", "text", "name", "device_type", "imei", "id",
]


def write_csv(points: list[dict], out: Path) -> None:
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(CSV_COLS)
        for p in points:
            w.writerow([
                p.get("_when", ""),
                p.get("_lat", ""),
                p.get("_lon", ""),
                p.get("_ele", ""),
                p.get("Velocity", ""),
                p.get("Course", ""),
                p.get("Valid GPS Fix", ""),
                p.get("In Emergency", ""),
                p.get("Event", ""),
                p.get("Text", ""),
                p.get("Name", ""),
                p.get("Device Type", ""),
                p.get("IMEI", ""),
                p.get("Id", ""),
            ])


def write_gpx(points: list[dict], out: Path, name: str) -> None:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<gpx version="1.1" creator="exodussail-extract" '
        'xmlns="http://www.topografix.com/GPX/1/1">',
        f"  <metadata><name>{name}</name></metadata>",
        f"  <trk><name>{name}</name><trkseg>",
    ]
    for p in points:
        if "_lon" not in p:
            continue
        lines.append(f'    <trkpt lat="{p["_lat"]}" lon="{p["_lon"]}">')
        if p.get("_ele") is not None:
            lines.append(f"      <ele>{p['_ele']}</ele>")
        if p.get("_when"):
            lines.append(f"      <time>{p['_when']}</time>")
        lines.append("    </trkpt>")
    lines.append("  </trkseg></trk>")
    lines.append("</gpx>")
    out.write_text("\n".join(lines))


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: convert.py <input.kml> <output_dir>", file=sys.stderr)
        sys.exit(2)
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    pts = parse(src)
    print(f"Parsed {len(pts)} trackpoints", file=sys.stderr)
    (dst / "exodussail.geojson").write_text(
        json.dumps(to_geojson(pts), separators=(",", ":"))
    )
    write_csv(pts, dst / "exodussail.csv")
    write_gpx(pts, dst / "exodussail.gpx", "Track")
    if pts:
        first, last = pts[0], pts[-1]
        print(
            f"First: {first.get('_when')} ({first.get('_lat')}, {first.get('_lon')})",
            file=sys.stderr,
        )
        print(
            f"Last:  {last.get('_when')} ({last.get('_lat')}, {last.get('_lon')})",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
