#!/usr/bin/env python3

from collections import Counter
from pathlib import Path
import sys

import requests

QBT_URL = "http://192.168.0.114:10095"
TAG = "# issue"
CLUSTERENV_PATH = Path(__file__).resolve().parents[1] / "clusters/main/clusterenv.yaml"
SUMMARY_EXCLUDED_TAGS = {"cross-seed", "cross-seed-link", "nemorosa-link"}


def truncate(text, length=30):
    return text if len(text) <= length else text[: length - 3] + "..."


def load_qbit_credentials(path):
    if not path.exists():
        print(f"Missing credentials file: {path}", file=sys.stderr)
        sys.exit(1)

    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip()

    username = values.get("QBIT_USERNAME")
    password = values.get("QBIT_PASSWORD")
    encrypted_values = (username, password)

    if not username or not password or any(value.startswith("ENC[") for value in encrypted_values):
        print(
            f"{path} is still encrypted. Run `forgetool decrypt` first, then rerun this script.",
            file=sys.stderr,
        )
        sys.exit(1)

    return username, password


def include_in_summary(tag):
    return not tag.startswith("#") and tag not in SUMMARY_EXCLUDED_TAGS


USERNAME, PASSWORD = load_qbit_credentials(CLUSTERENV_PATH)


s = requests.Session()
r = s.post(f"{QBT_URL}/api/v2/auth/login",
           data={
               "username": USERNAME,
               "password": PASSWORD}
           )
r.raise_for_status()
torrents = s.get(f"{QBT_URL}/api/v2/torrents/info", params={"tag": TAG}).json()
tag_counts = Counter()
for t in torrents:
    trackers = s.get(f"{QBT_URL}/api/v2/torrents/trackers",
                     params={"hash": t["hash"]}).json()
    issues = []
    tags = [tag.strip() for tag in t.get("tags", "").split(",") if tag.strip() and tag.strip() != TAG]
    tag_counts.update(tag for tag in tags if include_in_summary(tag))
    for tr in trackers:
        if tr.get("url", "").startswith(("http", "https", "udp", "ws", "wss")) and tr.get("status") == 4:
            msg = tr.get("msg", "").strip() or "<no message>"
            if msg not in issues:
                issues.append(msg)
    display_name = truncate(t["name"])
    tags_text = f' [{", ".join(tags)}]' if tags else ""
    if issues:
        print(f'{display_name}{tags_text} -> {" | ".join(issues)}')
    else:
        print(f'{display_name}{tags_text} -> <no current non-working tracker message>')

if tag_counts:
    print("\nTag summary:")
    for tag, count in tag_counts.most_common():
        print(f"{tag}: {count}")
