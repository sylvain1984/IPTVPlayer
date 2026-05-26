#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
MAC_REPO = SCRIPT_DIR.parent
ANDROID_REPO = MAC_REPO.parent / "IPTVPlayerAndroid"
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "IPTVPlayer"

CANDIDATE_SOURCES = [
    "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv4.m3u",
    "https://iptv-org.github.io/iptv/countries/cn.m3u",
    "https://raw.githubusercontent.com/YueChan/Live/main/IPTV.m3u",
    "https://raw.githubusercontent.com/YanG-1989/m3u/main/Gather.m3u",
    "https://raw.githubusercontent.com/joevess/IPTV/main/m3u/iptv.m3u",
    "https://iptv-org.github.io/iptv/categories/sports.m3u",
    "https://raw.githubusercontent.com/YueChan/Live/main/Migu.m3u",
    "https://raw.githubusercontent.com/YanG-1989/m3u/main/Migu.m3u",
    "https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_sports.m3u",
    "https://raw.githubusercontent.com/iptv-org/iptv/master/streams/uk_sports.m3u",
    "https://raw.githubusercontent.com/imDazui/Tvlist-awesome-m3u-m3u8/master/m3u/Sports.m3u",
    "https://iptv-org.github.io/iptv/languages/zho.m3u",
    "https://live.fanmingming.com/tv/m3u/global.m3u",
    "https://raw.githubusercontent.com/joevess/IPTV/main/iptv-search.m3u",
    "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8",
]


def fetch(url: str) -> bytes | None:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 IPTVPlayer"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if not (200 <= getattr(resp, "status", 200) < 400):
                return None
            data = resp.read()
            return data if data else None
    except (urllib.error.URLError, TimeoutError, ValueError):
        return None


def write_json(path: Path, urls: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(urls, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    live: list[str] = []
    dead: list[str] = []

    for url in CANDIDATE_SOURCES:
        data = fetch(url)
        if data is None:
            dead.append(url)
            continue
        # keep sources that return non-empty text, even if they are redirected playlists
        live.append(url)

    unique_live = list(dict.fromkeys(live))
    write_json(APP_SUPPORT / "source_catalog.json", unique_live)
    write_json(MAC_REPO / "scripts" / "source_catalog.json", unique_live)
    write_json(ANDROID_REPO / "app" / "src" / "main" / "assets" / "source_catalog.json", unique_live)

    report = {
        "live_count": len(unique_live),
        "dead_count": len(dead),
        "live": unique_live,
        "dead": dead,
    }
    (SCRIPT_DIR / "source_audit_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
