#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "requests",
#   "guessit",
#   "transmission-rpc",
#   "bencode3",
# ]
# ///
"""
restore-seeding.py - Re-add torrents to transmission for existing downloads.

Searches PassThePopcorn (films) and BroadcastTheNet (TV) for matching torrents,
downloads them, and adds to transmission pointing at existing data so it seeds
without re-downloading.

Usage:
    python3 scripts/restore-seeding.py [options]

Options:
    --limit N      Process at most N untracked items (default: all)
    --dry-run      Print what would happen, no API writes
    --item NAME    Process only this specific download name
    --verbose      Show search results and scores

Credentials via environment or .env file:
    TRANSMISSION_URL   https://transmission.shark-puffin.ts.net
    TRANSMISSION_USER  zem
    TRANSMISSION_PASS  ...
    PTP_API_USER       PassThePopcorn API user
    PTP_API_KEY        PassThePopcorn API key
    BTN_API_KEY        BroadcastTheNet API key
"""

import argparse
import base64
import difflib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import bencode3
import requests
from guessit import guessit
import transmission_rpc


KUBECTL_CONTEXT = "cluster01.shark-puffin.ts.net"
KUBECTL_NAMESPACE = "media-prod"
KUBECTL_POD = "transmission-0"
DOWNLOADS_PATH = "/downloads/complete"

SCORE_EXACT = 100
SCORE_NORMALISED = 90
SCORE_TOKENS = 70
SCORE_THRESHOLD = 70


def load_env():
    env_file = Path(__file__).parent.parent / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())


def require_env(key):
    val = os.environ.get(key)
    if not val:
        sys.exit(f"Missing env var: {key}")
    return val


def list_downloads():
    """Return list of (download_dir, name) for all items under DOWNLOADS_PATH.

    Scans one level deep: items directly in DOWNLOADS_PATH plus items inside
    any immediate subdirectory (e.g. movies/, tv/).
    """
    result = subprocess.run(
        [
            "kubectl", "exec", KUBECTL_POD,
            "-n", KUBECTL_NAMESPACE,
            f"--context={KUBECTL_CONTEXT}",
            "--", "find", DOWNLOADS_PATH, "-mindepth", "1", "-maxdepth", "2",
            "!", "-path", f"{DOWNLOADS_PATH}/*/*/**",
        ],
        capture_output=True, text=True, check=True,
    )
    items = []
    seen_dirs = set()
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parent = line.rsplit("/", 1)[0]
        name = line.rsplit("/", 1)[1]
        depth = line[len(DOWNLOADS_PATH):].count("/")
        if depth == 1:
            # Direct child — only include if it's not a plain subdirectory
            # that itself contains releases (we'll get those at depth 2)
            items.append((DOWNLOADS_PATH, name))
        elif depth == 2:
            items.append((parent, name))
            seen_dirs.add(parent)

    # Remove depth-1 entries that are just container dirs (movies/, tv/)
    items = [
        (d, n) for d, n in items
        if not (d == DOWNLOADS_PATH and f"{DOWNLOADS_PATH}/{n}" in seen_dirs)
    ]
    return items


def get_tracked_names(client):
    torrents = client.get_torrents(arguments=["name", "downloadDir"])
    return {t.name for t in torrents}


def normalise(name):
    name = re.sub(r"[()[\]{}-]", " ", name)
    return re.sub(r"[\._\s]+", " ", name).strip().lower()


def score_match(download_name, release_name):
    if download_name == release_name:
        return SCORE_EXACT
    dn = normalise(download_name)
    rn = normalise(release_name)
    if dn == rn:
        return SCORE_NORMALISED
    # Fuzzy: use exact ratio as score so closest match wins tiebreaks
    ratio = difflib.SequenceMatcher(None, dn, rn).ratio()
    if ratio >= 0.85:
        return ratio * 100
    # Subset: all tokens from (short) download name appear in release name
    tokens = dn.split()
    if tokens and all(t in rn for t in tokens):
        return SCORE_TOKENS
    return 0


def search_ptp(name, info, session, verbose):
    api_user = require_env("PTP_API_USER")
    api_key = require_env("PTP_API_KEY")
    headers = {"ApiUser": api_user, "ApiKey": api_key}

    title = info.get("title", "")
    year = info.get("year", "")
    params = {"action": "advanced", "json": "noredirect", "searchstr": title}
    if year:
        params["year"] = str(year)

    try:
        r = session.get(
            "https://passthepopcorn.me/torrents.php",
            headers=headers, params=params, timeout=15,
        )
        r.raise_for_status()
        data = r.json()
    except Exception as e:
        return None, None, f"PTP search failed: {e}"

    best_score = 0
    best_torrent_id = None
    best_release = None

    for movie in data.get("Movies", []):
        for torrent in movie.get("Torrents", []):
            release = torrent.get("ReleaseName", "")
            sc = score_match(name, release)
            if verbose:
                print(f"  PTP {torrent['Id']} {release!r} score={sc}")
            if sc > best_score:
                best_score = sc
                best_torrent_id = torrent["Id"]
                best_release = release

    if best_score >= SCORE_THRESHOLD:
        return best_torrent_id, best_release, None
    return None, None, f"no PTP result ≥{SCORE_THRESHOLD} (best={best_score})"


def download_ptp_torrent(torrent_id, session):
    api_user = require_env("PTP_API_USER")
    api_key = require_env("PTP_API_KEY")
    headers = {"ApiUser": api_user, "ApiKey": api_key}
    r = session.get(
        "https://passthepopcorn.me/torrents.php",
        headers=headers,
        params={"action": "download", "id": torrent_id},
        timeout=15,
    )
    r.raise_for_status()
    return r.content


def search_btn(name, info, session, verbose):
    api_key = require_env("BTN_API_KEY")

    title = str(info.get("title", ""))
    season = info.get("season")
    episode = info.get("episode")

    filters = {}
    if title:
        filters["series"] = title
    if season is not None:
        filters["season"] = int(season)
    if episode is not None:
        filters["episode"] = int(episode)

    payload = {
        "method": "getTorrents",
        "params": [api_key, filters, 100, 0],
        "id": 1,
    }

    try:
        r = session.post(
            "https://api.broadcasthe.net/",
            data=json.dumps(payload),
            headers={"Content-Type": "application/json"},
            timeout=15,
        )
        r.raise_for_status()
        if not r.text:
            return None, None, None, f"BTN empty response (status {r.status_code})"
        data = r.json()
    except json.JSONDecodeError:
        return None, None, None, f"BTN non-JSON response (status {r.status_code}): {r.text[:200]}"
    except Exception as e:
        return None, None, None, f"BTN search failed: {e}"

    if "error" in data:
        return None, None, None, f"BTN error: {data['error']}"

    torrents = data.get("result", {}).get("torrents", {})
    if isinstance(torrents, dict):
        torrents = list(torrents.values())

    best_score = 0
    best_torrent = None

    for t in torrents:
        release = t.get("ReleaseName", "")
        sc = score_match(name, release)
        if verbose:
            print(f"  BTN {t.get('TorrentID')} {release!r} score={sc}")
        if sc > best_score:
            best_score = sc
            best_torrent = t

    if best_score >= SCORE_THRESHOLD and best_torrent:
        return (
            best_torrent.get("TorrentID"),
            best_torrent.get("ReleaseName"),
            best_torrent.get("DownloadURL"),
            None,
        )
    return None, None, None, f"no BTN result ≥{SCORE_THRESHOLD} (best={best_score})"


def download_btn_torrent(download_url, session):
    r = session.get(download_url, timeout=15)
    r.raise_for_status()
    return r.content


def parse_torrent_files(torrent_bytes):
    """Return (torrent_top_name, [(rel_path, size_bytes), ...])"""
    data = bencode3.bdecode(torrent_bytes)
    info = data["info"]
    name = info["name"]
    if "files" in info:
        files = []
        for f in info["files"]:
            rel = "/".join(f["path"])
            files.append((f"{name}/{rel}", f["length"]))
    else:
        files = [(name, info["length"])]
    return name, files


def get_local_sizes(local_path, base_dir):
    """Return dict of {path_relative_to_base_dir: size} via kubectl exec."""
    try:
        r = subprocess.run(
            [
                "kubectl", "exec", KUBECTL_POD,
                "-n", KUBECTL_NAMESPACE,
                f"--context={KUBECTL_CONTEXT}",
                "--", "find", local_path, "-type", "f",
                "-exec", "stat", "-c", "%s %n", "{}", "+",
            ],
            capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError:
        # May be a single file — try stat directly
        try:
            r = subprocess.run(
                [
                    "kubectl", "exec", KUBECTL_POD,
                    "-n", KUBECTL_NAMESPACE,
                    f"--context={KUBECTL_CONTEXT}",
                    "--", "stat", "-c", "%s %n", local_path,
                ],
                capture_output=True, text=True, check=True,
            )
        except subprocess.CalledProcessError:
            return None
    sizes = {}
    for line in r.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            try:
                size, full_path = int(parts[0]), parts[1]
                rel = full_path[len(base_dir) + 1:]
                sizes[rel] = size
            except ValueError:
                pass
    return sizes


def verify_torrent(torrent_bytes, download_name, download_dir, verbose):
    """
    Check torrent file list and sizes match local files.
    Returns (ok: bool, message: str).
    """
    try:
        torrent_name, torrent_files = parse_torrent_files(torrent_bytes)
    except Exception as e:
        return False, f"torrent parse failed: {e}"

    if torrent_name != download_name:
        return False, f"name mismatch: torrent={torrent_name!r} != local={download_name!r}"

    local_sizes = get_local_sizes(f"{download_dir}/{download_name}", download_dir)
    if local_sizes is None:
        return False, f"cannot stat local path"

    mismatches = []
    for rel_path, expected in torrent_files:
        actual = local_sizes.get(rel_path)
        if actual is None:
            mismatches.append(f"missing: {rel_path}")
        elif actual != expected:
            mismatches.append(f"size mismatch {rel_path}: want {expected:,} got {actual:,}")
        elif verbose:
            print(f"  OK {rel_path} ({expected:,} bytes)")

    if mismatches:
        return False, "; ".join(mismatches[:3])
    return True, f"{len(torrent_files)} file(s) verified by size"


def process_item(name, download_dir, client, session, dry_run, verbose, save_dir=None):
    info = guessit(name)
    media_type = str(info.get("type", ""))

    if verbose:
        print(f"  guessit: {dict(info)}")

    if media_type == "movie":
        tracker = "PTP"
        torrent_id, release_name, err = search_ptp(name, info, session, verbose)
        download_url = None
    elif media_type == "episode":
        tracker = "BTN"
        torrent_id, release_name, download_url, err = search_btn(name, info, session, verbose)
    else:
        return "NO_MATCH", f"guessit type={media_type!r}, not movie/episode"

    if err:
        return "NO_MATCH", err

    print(f"  [{tracker} #{torrent_id}] {release_name!r}")

    try:
        if tracker == "PTP":
            torrent_bytes = download_ptp_torrent(torrent_id, session)
        else:
            torrent_bytes = download_btn_torrent(download_url, session)
    except Exception as e:
        return "ERROR", f"download failed: {e}"

    verified, verify_msg = verify_torrent(torrent_bytes, name, download_dir, verbose)
    if verified:
        print(f"  [VERIFIED] {verify_msg}")
    else:
        print(f"  [UNVERIFIED] {verify_msg}")

    if verified and save_dir:
        safe_name = re.sub(r'[^\w\-.]', '_', name)
        torrent_path = Path(save_dir) / f"{safe_name}.torrent"
        torrent_path.write_bytes(torrent_bytes)
        print(f"  [SAVED] {torrent_path}")

    if dry_run:
        status = "DRY_RUN" if verified else "DRY_RUN_UNVERIFIED"
        return status, f"would add {tracker} #{torrent_id} — {verify_msg}"

    if not verified:
        return "UNVERIFIED", f"{tracker} #{torrent_id}: {verify_msg}"

    try:
        result = client.add_torrent(
            torrent=torrent_bytes,
            download_dir=download_dir,
            paused=False,
        )
        return "ADD", f"torrent-add OK id={result.id}"
    except Exception as e:
        return "ERROR", f"torrent-add failed: {e}"


def main():
    load_env()
    parser = argparse.ArgumentParser(description="Restore transmission seeding from existing downloads")
    parser.add_argument("--limit", type=int, default=None, help="Max items to process")
    parser.add_argument("--dry-run", action="store_true", help="No API writes")
    parser.add_argument("--item", default=None, help="Process only this download name")
    parser.add_argument("--verbose", action="store_true", help="Show scores and search hits")
    parser.add_argument("--save-torrents", metavar="DIR", help="Save verified .torrent files to this directory")
    args = parser.parse_args()

    transmission_url = require_env("TRANSMISSION_URL")
    transmission_user = require_env("TRANSMISSION_USER")
    transmission_pass = require_env("TRANSMISSION_PASS")

    # Parse URL for transmission-rpc client
    from urllib.parse import urlparse
    parsed = urlparse(transmission_url)
    client = transmission_rpc.Client(
        host=parsed.hostname,
        port=parsed.port or (443 if parsed.scheme == "https" else 80),
        path="/transmission/rpc",
        protocol=parsed.scheme,
        username=transmission_user,
        password=transmission_pass,
    )

    print("Fetching existing torrents from transmission...")
    tracked = get_tracked_names(client)
    print(f"  {len(tracked)} torrents already tracked")

    print("Listing downloads...")
    try:
        downloads = list_downloads()
    except subprocess.CalledProcessError as e:
        sys.exit(f"kubectl exec failed: {e.stderr}")
    print(f"  {len(downloads)} items in {DOWNLOADS_PATH}")

    if args.item:
        downloads = [(d, n) for d, n in downloads if n == args.item]
        if not downloads:
            sys.exit(f"Item {args.item!r} not found in downloads")

    session = requests.Session()
    session.headers["User-Agent"] = "restore-seeding/1.0"

    save_dir = args.save_torrents
    if save_dir:
        Path(save_dir).mkdir(parents=True, exist_ok=True)

    stats = {"SKIP": 0, "ADD": 0, "DRY_RUN": 0, "NO_MATCH": 0, "ERROR": 0}
    processed = 0

    for download_dir, name in downloads:
        if name in tracked:
            print(f"[SKIP]     {name}")
            stats["SKIP"] += 1
            continue

        if args.limit is not None and processed >= args.limit:
            break

        print(f"[PROCESS]  {name}")
        status, msg = process_item(name, download_dir, client, session, args.dry_run, args.verbose, save_dir)
        label = {"ADD": "ADD", "DRY_RUN": "DRY_RUN", "NO_MATCH": "NO_MATCH", "ERROR": "ERROR"}.get(status, status)
        print(f"[{label:<8}] {name}  {msg}")
        stats[status] = stats.get(status, 0) + 1
        processed += 1

        # Polite rate limiting between tracker searches
        time.sleep(2)

    print()
    print(f"Done: {stats.get('ADD',0)} added, {stats.get('DRY_RUN',0)} dry-run, "
          f"{stats['SKIP']} skipped, {stats['NO_MATCH']} unmatched, "
          f"{stats.get('UNVERIFIED',0)} unverified, {stats.get('ERROR',0)} errors")


if __name__ == "__main__":
    main()
