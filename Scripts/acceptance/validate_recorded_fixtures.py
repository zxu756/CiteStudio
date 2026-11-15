#!/usr/bin/env python3
"""Strict C23/C24 validator for recorded Crossref / OpenAlex fixtures in Tests/Fixtures/recorded/.

Trust Boundary & Known Limitation (C24):
- This script verifies internal structural and SHA-256 consistency across `manifest.json`,
  `<slug>.meta.json`, and `<slug>.raw` (catching accidental corruption, partial edits,
  missing HTTP Date headers, or mailto/email leaks).
- Because `manifest.json`, `.meta.json`, and `.raw` reside in the same repository without
  an external cryptographic signature (e.g., TLSNotary), an author who modifies `.raw` AND
  recomputes `byte_length` + `sha256` in both `.meta.json` and `manifest.json` will still
  satisfy self-contained checks unless `--expected-manifest-sha256` is pinned against an
  externally recorded digest (e.g., `29b557c0d69c2bdf0913eaa395e5286b63c066afd9af77255493395851097bb9`
  from `m0/honest` `c8298c3`) or verified via `git diff <baseline> -- Tests/Fixtures/recorded/`.
"""

from __future__ import annotations

import argparse
import datetime
import email.utils
import hashlib
import json
import os
import sys
import urllib.parse


def fail(msg: str) -> None:
    print(f"INVALID_RECORDED_FIXTURES: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_iso_utc(ts: str, field_name: str) -> datetime.datetime:
    if not isinstance(ts, str) or not ts.endswith("Z"):
        fail(f"{field_name} must be non-empty ISO-8601 UTC timestamp ending with 'Z', got {ts!r}")
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError as exc:
        fail(f"{field_name} failed ISO-8601 UTC parse ({ts!r}): {exc}")
        raise AssertionError("unreachable")


def validate_directory(rec_dir: str, min_items: int, expected_manifest_sha256: str | None = None) -> None:
    if not os.path.isdir(rec_dir):
        fail(f"Directory does not exist: {rec_dir}")

    manifest_path = os.path.join(rec_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        fail(f"Missing manifest.json in {rec_dir}")

    manifest_raw_bytes = open(manifest_path, "rb").read()
    actual_manifest_sha = hashlib.sha256(manifest_raw_bytes).hexdigest()
    if expected_manifest_sha256 is not None and actual_manifest_sha != expected_manifest_sha256.lower():
        fail(
            f"manifest.json sha256 mismatch against pinned baseline: "
            f"expected={expected_manifest_sha256.lower()!r} vs actual={actual_manifest_sha!r}"
        )

    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except Exception as exc:
        fail(f"Failed to parse manifest.json: {exc}")
        return

    if not isinstance(manifest, dict):
        fail("manifest.json root must be a JSON object")

    ua = manifest.get("user_agent")
    if not isinstance(ua, str) or not ua.strip():
        fail("manifest.user_agent must be a non-empty string")
    if "@" in ua or "mailto" in ua.lower():
        fail(f"manifest.user_agent must not contain email or mailto: {ua!r}")

    parse_iso_utc(manifest.get("started_at"), "manifest.started_at")
    parse_iso_utc(manifest.get("completed_at"), "manifest.completed_at")

    total_sent = manifest.get("total_http_requests_sent")
    if type(total_sent) is not int or total_sent < min_items or total_sent > 24:
        fail(f"manifest.total_http_requests_sent must be int in [{min_items}, 24], got {total_sent!r}")

    items = manifest.get("items")
    if not isinstance(items, list) or len(items) < min_items:
        fail(f"manifest.items must be a list with at least {min_items} items")

    if manifest.get("count") != len(items):
        fail(f"manifest.count ({manifest.get('count')!r}) != len(items) ({len(items)})")

    seen_slugs = set()
    for idx, item in enumerate(items, start=1):
        ctx = f"item[{idx}]"
        if not isinstance(item, dict):
            fail(f"{ctx} must be an object")

        slug = item.get("slug")
        if not isinstance(slug, str) or not slug or "/" in slug or "\\" in slug or ".." in slug:
            fail(f"{ctx}.slug invalid: {slug!r}")
        if slug in seen_slugs:
            fail(f"{ctx}.slug duplicate: {slug!r}")
        seen_slugs.add(slug)

        service = item.get("service")
        url = item.get("url")
        if service == "crossref":
            expected_prefix = "https://api.crossref.org/"
        elif service == "openalex":
            expected_prefix = "https://api.openalex.org/"
        else:
            fail(f"{ctx}.service must be 'crossref' or 'openalex', got {service!r}")
            return

        if not isinstance(url, str) or not url.startswith(expected_prefix):
            fail(f"{ctx}.url must start with {expected_prefix!r}, got {url!r}")
        parsed_url = urllib.parse.urlsplit(url)
        if "@" in parsed_url.query or "@" in parsed_url.netloc or "mailto" in url.lower():
            fail(f"{ctx}.url contains forbidden personal/mailto data: {url!r}")

        status = item.get("status")
        if type(status) is not int or status not in (200, 404):
            fail(f"{ctx}.status must be integer 200 or 404, got {status!r}")

        parse_iso_utc(item.get("requested_at"), f"{ctx}.requested_at")

        date_hdr = item.get("response_date_header")
        if not isinstance(date_hdr, str) or not date_hdr.strip():
            fail(f"{ctx}.response_date_header must be a non-empty HTTP Date header string")
        try:
            parsed_http_date = email.utils.parsedate_to_datetime(date_hdr)
            if parsed_http_date is None:
                fail(f"{ctx}.response_date_header returned None on RFC-2822/7231 parse: {date_hdr!r}")
        except Exception as exc:
            fail(f"{ctx}.response_date_header is not a valid HTTP Date header ({date_hdr!r}): {exc}")

        attempts = item.get("attempts")
        if type(attempts) is not int or attempts not in (1, 2):
            fail(f"{ctx}.attempts must be 1 or 2, got {attempts!r}")

        raw_file = item.get("raw_file")
        if not isinstance(raw_file, str) or raw_file != f"{slug}.raw":
            fail(f"{ctx}.raw_file ({raw_file!r}) must equal '{slug}.raw'")

        raw_path = os.path.join(rec_dir, raw_file)
        if not os.path.isfile(raw_path):
            fail(f"{ctx} missing raw file on disk: {raw_path}")

        meta_path = os.path.join(rec_dir, f"{slug}.meta.json")
        if not os.path.isfile(meta_path):
            fail(f"{ctx} missing meta file on disk: {meta_path}")
        try:
            with open(meta_path, encoding="utf-8") as mfh:
                disk_meta = json.load(mfh)
        except Exception as exc:
            fail(f"{ctx} failed to parse {meta_path}: {exc}")
            return
        if disk_meta != item:
            fail(f"{ctx} mismatch between manifest.json item and {slug}.meta.json")

        with open(raw_path, "rb") as rfh:
            raw_bytes = rfh.read()

        byte_length = item.get("byte_length")
        if type(byte_length) is not int or byte_length != len(raw_bytes):
            fail(f"{ctx}.byte_length ({byte_length!r}) != actual disk size ({len(raw_bytes)})")

        expected_sha = item.get("sha256")
        actual_sha = hashlib.sha256(raw_bytes).hexdigest()
        if not isinstance(expected_sha, str) or actual_sha != expected_sha:
            fail(f"{ctx}.sha256 mismatch: manifest={expected_sha!r} vs disk={actual_sha!r}")

        if status == 200:
            try:
                json.loads(raw_bytes.decode("utf-8"))
            except Exception as exc:
                fail(f"{ctx} HTTP 200 raw body is not valid UTF-8 JSON: {exc}")

    print(
        f"VALID_RECORDED_FIXTURES: items={len(items)} total_http_requests_sent={total_sent} "
        f"started_at={manifest['started_at']} completed_at={manifest['completed_at']}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate recorded Crossref/OpenAlex fixtures.")
    parser.add_argument("recorded_dir", help="Path to Tests/Fixtures/recorded")
    parser.add_argument("--min-items", type=int, default=20, help="Minimum required fixture items (default: 20)")
    parser.add_argument(
        "--expected-manifest-sha256",
        default=None,
        help="Optional pinned SHA-256 hex digest of manifest.json to detect synchronized raw+manifest edits",
    )
    args = parser.parse_args()
    validate_directory(args.recorded_dir, args.min_items, args.expected_manifest_sha256)


if __name__ == "__main__":
    main()
