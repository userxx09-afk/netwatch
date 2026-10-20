#!/usr/bin/env python3
"""NetWatch collector: receives log uploads from the iPads and summarizes them.

Run a receiver (any always-on machine the iPads can reach):
    python3 collector.py serve --port 8080 --data ./data [--token SECRET]
    -> set MDM managed config collectorURL = http://<this-host>:8080/ingest
    -> open http://<this-host>:8080/ for a dashboard

Summarize log files pulled off a device (Finder / Apple Configurator):
    python3 collector.py summarize netwatch-*.jsonl

Standard library only; Python 3.8+.
"""
import argparse
import datetime as dt
import glob
import html
import json
import os
import re
import sys
from collections import Counter, defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TIMELINE_TYPES = {
    "monitor_start", "first_launch", "device_rebooted", "app_relaunched_unexpectedly", "app_updated",
    "outage_start", "outage_update", "outage_end", "monitor_gap",
    "wifi_joined", "wifi_lost", "wifi_roam", "wifi_network_changed", "wifi_info_unavailable",
    "network_change", "app_background", "app_terminate", "device_locked", "memory_warning",
    "low_power_mode", "thermal_state", "battery_state", "metrickit_crash", "metrickit_hang",
    "kiosk_load_failed", "kiosk_webcontent_crashed", "location_permission",
}


def parse_ts(s):
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def read_events(paths):
    events = []
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ev["_t"] = parse_ts(ev.get("ts", ""))
                if ev["_t"]:
                    events.append(ev)
    # Dedupe (same upload can arrive twice after a retry) and sort.
    seen, unique = set(), []
    for ev in events:
        key = (ev.get("device"), ev.get("session"), ev.get("seq"))
        if key not in seen:
            seen.add(key)
            unique.append(ev)
    unique.sort(key=lambda e: e["_t"])
    return unique


def summarize(events):
    """Returns per-device stats and a list of notable events."""
    devices = defaultdict(lambda: {
        "first": None, "last": None, "outages": 0, "downtime_s": 0, "longest_s": 0,
        "causes": Counter(), "reboots": 0, "unexpected_relaunches": 0, "gaps": 0, "roams": 0,
        "wifi_lost": 0, "aps": Counter(), "last_status": None,
    })
    notable = []
    for ev in events:
        d = devices[ev.get("device") or "unknown"]
        t, typ, data = ev["_t"], ev.get("type"), ev.get("data") or {}
        d["first"] = d["first"] or t
        d["last"] = t
        if data.get("bssid"):
            d["aps"][data["bssid"]] += 1
        if typ == "outage_start":
            d["outages"] += 1
            d["causes"][data.get("verdict", "?")] += 1
            d["last_status"] = "DOWN"
        elif typ == "outage_end":
            secs = data.get("duration_s", 0) or 0
            d["downtime_s"] += secs
            d["longest_s"] = max(d["longest_s"], secs)
            d["last_status"] = "up"
        elif typ == "probe_ok":
            d["last_status"] = "up"
        elif typ == "device_rebooted":
            d["reboots"] += 1
        elif typ == "app_relaunched_unexpectedly":
            d["unexpected_relaunches"] += 1
        elif typ == "monitor_gap":
            d["gaps"] += 1
        elif typ == "wifi_roam":
            d["roams"] += 1
        elif typ == "wifi_lost":
            d["wifi_lost"] += 1
        if typ in TIMELINE_TYPES:
            notable.append(ev)
    return devices, notable


def fmt_dur(s):
    s = int(s)
    if s < 120:
        return f"{s}s"
    if s < 7200:
        return f"{s // 60}m"
    return f"{s / 3600:.1f}h"


def print_summary(events):
    devices, notable = summarize(events)
    if not events:
        print("No events found.")
        return
    for name, d in sorted(devices.items()):
        print(f"\n=== {name}  ({d['first']:%Y-%m-%d %H:%M} -> {d['last']:%Y-%m-%d %H:%M} UTC)")
        print(f"  outages: {d['outages']}  total down: {fmt_dur(d['downtime_s'])}  longest: {fmt_dur(d['longest_s'])}")
        if d["causes"]:
            print("  outage causes: " + ", ".join(f"{k} x{v}" for k, v in d["causes"].most_common()))
        print(f"  reboots: {d['reboots']}  unexpected app restarts: {d['unexpected_relaunches']}  "
              f"monitor gaps (sleep/suspend): {d['gaps']}")
        print(f"  wifi lost: {d['wifi_lost']}  roams: {d['roams']}  access points seen: {len(d['aps'])}")
    print("\n=== Timeline")
    for ev in notable:
        print(f"{ev['_t']:%Y-%m-%d %H:%M:%S}  {ev.get('device', ''):<16} {ev.get('level', ''):<5} "
              f"{ev.get('type', ''):<28} {ev.get('msg', '')}")
        clues = (ev.get("data") or {}).get("clues")
        for c in clues or []:
            print(f"{'':>40}- {c}")


# ---------------------------------------------------------------- server

def safe_name(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", s or "unknown")[:64] or "unknown"


class Handler(BaseHTTPRequestHandler):
    data_dir = "data"
    token = None

    def log_message(self, fmt, *args):  # quieter console
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def do_POST(self):
        if self.path.rstrip("/") != "/ingest":
            return self.send_error(404)
        if self.token and self.headers.get("X-NetWatch-Token") != self.token:
            return self.send_error(403)
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 5_000_000:
            return self.send_error(400)
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        header_device = self.headers.get("X-NetWatch-Device")
        by_file = defaultdict(list)
        for line in body.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            device = safe_name(ev.get("device") or header_device)
            day = (ev.get("ts") or "unknown")[:10]
            by_file[(device, day)].append(line)
        for (device, day), lines in by_file.items():
            folder = os.path.join(self.data_dir, device)
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, f"{day}.jsonl"), "a", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path not in ("/", "/index.html"):
            return self.send_error(404)
        days = {(dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=i)).strftime("%Y-%m-%d") for i in range(3)}
        paths = [p for p in glob.glob(os.path.join(self.data_dir, "*", "*.jsonl"))
                 if os.path.basename(p)[:10] in days]
        events = read_events(paths)
        devices, notable = summarize(events)
        rows = []
        for name, d in sorted(devices.items()):
            status = d["last_status"] or "?"
            color = "#c62828" if status == "DOWN" else "#2e7d32"
            causes = ", ".join(f"{k}&nbsp;x{v}" for k, v in d["causes"].most_common(3))
            rows.append(
                f"<tr><td>{html.escape(name)}</td><td style='color:{color};font-weight:600'>{status}</td>"
                f"<td>{d['last']:%m-%d %H:%M}</td><td>{d['outages']}</td><td>{fmt_dur(d['downtime_s'])}</td>"
                f"<td>{causes}</td><td>{d['reboots']}</td><td>{d['unexpected_relaunches']}</td>"
                f"<td>{d['gaps']}</td><td>{d['roams']}</td><td>{len(d['aps'])}</td></tr>")
        tl = []
        for ev in reversed(notable[-200:]):
            lvl = ev.get("level", "")
            color = {"error": "#c62828", "warn": "#ef6c00"}.get(lvl, "inherit")
            tl.append(f"<tr><td>{ev['_t']:%m-%d %H:%M:%S}</td><td>{html.escape(ev.get('device', ''))}</td>"
                      f"<td style='color:{color}'>{html.escape(ev.get('type', ''))}</td>"
                      f"<td>{html.escape(ev.get('msg', ''))}</td></tr>")
        page = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>NetWatch</title>
<meta http-equiv="refresh" content="60">
<style>body{{font:14px system-ui,sans-serif;margin:16px;background:#fff;color:#111}}
table{{border-collapse:collapse;width:100%;margin-bottom:24px}}td,th{{border-bottom:1px solid #ddd;padding:4px 8px;text-align:left;vertical-align:top}}
th{{background:#f4f4f4}}@media (prefers-color-scheme:dark){{body{{background:#111;color:#eee}}th{{background:#222}}td,th{{border-color:#333}}}}</style>
</head><body><h2>NetWatch: last 3 days (UTC)</h2>
<table><tr><th>Device</th><th>Status</th><th>Last seen</th><th>Outages</th><th>Down</th><th>Top causes</th>
<th>Reboots</th><th>App crashes</th><th>Sleep gaps</th><th>Roams</th><th>APs</th></tr>{''.join(rows)}</table>
<h3>Timeline (newest first)</h3><table><tr><th>Time</th><th>Device</th><th>Event</th><th>Detail</th></tr>{''.join(tl)}</table>
</body></html>"""
        data = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=8080)
    s.add_argument("--data", default="data")
    s.add_argument("--token")
    m = sub.add_parser("summarize")
    m.add_argument("files", nargs="+")
    args = ap.parse_args()

    if args.cmd == "serve":
        Handler.data_dir = args.data
        Handler.token = args.token
        os.makedirs(args.data, exist_ok=True)
        print(f"NetWatch collector on :{args.port}  (POST /ingest, dashboard at /)")
        ThreadingHTTPServer(("", args.port), Handler).serve_forever()
    else:
        files = [p for pattern in args.files for p in (glob.glob(pattern) or [pattern])]
        print_summary(read_events(files))


if __name__ == "__main__":
    main()
