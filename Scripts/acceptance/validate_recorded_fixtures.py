#!/usr/bin/env python3
"""Strict C23/C24 validator for recorded Crossref / OpenAlex fixtures in Tests/Fixtures/recorded/.

Trust Boundary & Known Limitation (C24):
- This script verifies internal structural and SHA-256 consistency across `manifest.json`,
  `<slug>.meta.json`, and `<slug>.raw` (catching accidental corruption, partial edits,
  missing HTTP Date headers, or mailto/email leaks).
- Because `manifest.json`, `.meta.json`, and `.raw` reside in the same repository without
  an external cryptographic signature (e.g., TLSNotary), an author who modifies `.raw` AND
  recomputes `byte_length` + `sha256` in both `.meta.json` and `manifest.json` will still
  satisfy self-contained checks unless `--expected-manifest-sha256` is pinned against the
  recorded baseline digest (`PINNED_CURRENT_MANIFEST_SHA256`) and `--verify-m0-baseline`
  confirms the original 20 M0 items (`.raw`, `.meta.json`, and `manifest.items[:20]`) remain
  byte-for-byte identical to `m0/honest` (`29b557c0d69c2bdf0913eaa395e5286b63c066afd9af77255493395851097bb9`).
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

PINNED_M0_MANIFEST_SHA256 = "29b557c0d69c2bdf0913eaa395e5286b63c066afd9af77255493395851097bb9"
PINNED_CURRENT_MANIFEST_SHA256 = "adc644701848c655114c59afc21e6548ee30e110a1c273cd6c278832b5a7b274"
PINNED_M0_FIRST_20_ITEMS_JSON_SHA256 = "2ab261bfcea070a4782ad2cbc41c321e340b06ea6f29400b28ad07a3789e0bb9"

# Exact byte lengths and SHA-256 digests of the original 20 (.raw, .meta.json) pairs from m0/honest:
PINNED_M0_20_FILES: tuple[tuple[str, int, str, int, str], ...] = (
    ("crossref_doi_10.1038_nature14539_2fbc9ecc14", 40565, "1e398c9591c4c10a368b0d7031e41a4a868c7c85fbde78d1d96e33223251c0f6", 490, "eb5e1ee6320bbe1b6513d9b70e33f462566d5789e6a9e8f941cec9da754a1e26"),
    ("openalex_doi_10.1038_nature14539_2fbc9ecc14", 21383, "a41f7bf135816cc32d87962ea9ab669ab7cfe09db42a5ad1faf850a776130166", 506, "48525861175aa6b92edb346d612a2b35351ab0d5afe0b36ebfd950d82264941b"),
    ("crossref_doi_10.1162_neco.1997.9.8.1735_b5b0572fa1", 7294, "0bb29c6cd7a01ff2b486e80ce2b0ab9fd80eac75352c8489c1f223bca776fb7d", 510, "8450b5c2ad3c403acc5779cea4c3858dfcab1645a86ee3f82b371e1534167564"),
    ("openalex_doi_10.1162_neco.1997.9.8.1735_b5b0572fa1", 17412, "9859e5511dfe944e6dc1f55661bc56e75cc60a1e507342092615134b02aff7b8", 527, "29f67d6db386b5322e17880ca1c341cf9be8ce9b5254ea9d25ddfe93b2342f04"),
    ("crossref_doi_10.1038_171737a0_c02e1b29fc", 4482, "8307b633959046b5a24e995851e12747c553e2e99319a690bce400e00eec3b09", 480, "1806908902e06b9032df73441d8dbdb16998d0e3ec4eca0cc466ccf1cecf28a8"),
    ("openalex_doi_10.1038_171737a0_c02e1b29fc", 13691, "54b62fb8aa809bc01a0cfbe448d62053d325d90553e9473eb1935ff5806fe1b9", 497, "e3c326f87ac5b78cac5f610cdc8753bd90f07f6c91641642364b3ac0781dbc88"),
    ("crossref_doi_10.1038_fake.2026.99999_f246da2766", 19, "ae8462e3af85ca7577aaa97ff22a194f9dfd7fada58cf4944b53d2fdfa7b1f92", 493, "663e2f7057a122a6bd657a63a286b88f73c8c51ff9da9d44381bc169328dc982"),
    ("openalex_doi_10.1038_fake.2026.99999_f246da2766", 207, "e9639e3c4681ce85f852fbac48e2eeee5ba51296dbfec57c200d59b76237ab80", 524, "b8c829fa94cb6f0d9b85c50363d695c120080d4542aac1504ae041a17726c43b"),
    ("crossref_doi_10.1234_fake.2026.99999_ca13380f94", 19, "ae8462e3af85ca7577aaa97ff22a194f9dfd7fada58cf4944b53d2fdfa7b1f92", 493, "dae42b3d1fa850cda5d3be5ce046c3101cedf4880aa44f3b2316e26e88e8341f"),
    ("openalex_doi_10.1234_fake.2026.99999_ca13380f94", 207, "e9639e3c4681ce85f852fbac48e2eeee5ba51296dbfec57c200d59b76237ab80", 524, "2f9c406997f97ace1fe524b9209909421f7f81af9cd53d728349cee3cb1a61de"),
    ("crossref_doi_10.1016_j.fct.2012.08.005_289ea237f0", 23124, "a3d2ff8021ac50bd8ba4d4b123ed41839a11d521d71d2c0542a9410ef9bb30e0", 508, "d2d2635ecacd7aed935e80a76bd1c76526569c2bf2175e4a94c4b8f93fbd98c0"),
    ("openalex_doi_10.1016_j.fct.2012.08.005_289ea237f0", 33425, "ca11706cf122f24caf1e806c9f2eea67c5bc369c0702e134d7c5f9810243a810", 524, "13703c48e93391fbfc98ccf88a58f0286c7c386e240d4af36720deaa1f337c42"),
    ("crossref_doi_10.1016_s0140-6736_97_11096-0_e1144ad9cb", 11288, "b154ca5978d796a0983c5a551653db9fff70f48a9d3bb0831a117ca9528e9a83", 520, "b44c1e2ab82f67ec4e8b47c10de68f25a9675501567636c0029cd0291d169f5e"),
    ("openalex_doi_10.1016_s0140-6736_97_11096-0_e1144ad9cb", 25959, "26161a6db78649470ab58fcf2c4250a7b55a08f8168867ebdd708084d48c9917", 536, "ee51dcb919c983d7c38dcc537bbb1c00b866af4732851b6195608527d978683b"),
    ("crossref_doi_10.48550_arxiv.1706.03762_f81aabcbd3", 19, "ae8462e3af85ca7577aaa97ff22a194f9dfd7fada58cf4944b53d2fdfa7b1f92", 499, "a8a0df69339521739c77184b3751b787e625b23029aa5460abfa5fc7d5ade788"),
    ("openalex_doi_10.48550_arxiv.1706.03762_f81aabcbd3", 30776, "60af926c6a42eee1303e4ef38887d81f71e6b2d534a89c715adcde330ed63740", 524, "2fa10417bf3d52d0a1f7d86167dbd43d24c01c02b4122ef93c41bbfeabfa96e4"),
    ("openalex_title_The_Art_of_Computer_Programming_Volume_1_Fundame_a30531dad9", 32037, "98eb1bd079a0cbc95b7f1910eab4e0de15e04b170e67b9c8231141392a2a29cb", 632, "048a04059d09a46ef78cf3362518f1f33982a6cfec4bd1d5245d65269fdb1084"),
    ("crossref_title_The_Art_of_Computer_Programming_Volume_1_Fundame_a30531dad9", 5177, "201553e030eb886ad03f179fde1e9171fade6f3f989663c42e7ad41f66222e74", 640, "e51942f35ccbce636904294b7dec8ed900061b5adc83cfbd939add3ca9ef057a"),
    ("openalex_title_Recursive_Causal_Lattices_for_Zero-Shot_Climate__1c12c1589a", 61307, "4b269e79c8ab99764a937646c5ae3067156e0a7d8b5c8ef1c5d37756c962aa94", 622, "832caa7be429b593ecaf73a2608703294914bc7e2e86547c7915e2b41ab091d4"),
    ("crossref_title_Recursive_Causal_Lattices_for_Zero-Shot_Climate__1c12c1589a", 28903, "bca0d13ecc95b5212dcdbd809166fc4a7f768810d1e0546a770fe642a89e7432", 631, "82b098678312eadfb4ac58bb6595d3c9d6cbb500a8960cd5ec4912034e5b7b8a"),
)


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


def verify_m0_baseline_20(rec_dir: str, items: list[dict]) -> None:
    if len(items) < len(PINNED_M0_20_FILES):
        fail(f"M0 baseline check requires at least {len(PINNED_M0_20_FILES)} items, got {len(items)}")

    prefix_items = items[: len(PINNED_M0_20_FILES)]
    actual_prefix_sha = hashlib.sha256(
        json.dumps(prefix_items, indent=2, sort_keys=True).encode("utf-8")
    ).hexdigest()
    if actual_prefix_sha != PINNED_M0_FIRST_20_ITEMS_JSON_SHA256:
        fail(
            f"manifest.items[:20] differs from M0 baseline: "
            f"expected={PINNED_M0_FIRST_20_ITEMS_JSON_SHA256!r} vs actual={actual_prefix_sha!r}"
        )

    for idx, (slug, exp_raw_len, exp_raw_sha, exp_meta_len, exp_meta_sha) in enumerate(PINNED_M0_20_FILES, start=1):
        raw_path = os.path.join(rec_dir, f"{slug}.raw")
        meta_path = os.path.join(rec_dir, f"{slug}.meta.json")
        if not os.path.isfile(raw_path):
            fail(f"M0 baseline item[{idx}] missing raw file: {raw_path}")
        if not os.path.isfile(meta_path):
            fail(f"M0 baseline item[{idx}] missing meta file: {meta_path}")

        raw_bytes = open(raw_path, "rb").read()
        if len(raw_bytes) != exp_raw_len or hashlib.sha256(raw_bytes).hexdigest() != exp_raw_sha:
            fail(f"M0 baseline item[{idx}] ({slug}.raw) is not byte-for-byte identical to original M0 recording")

        meta_bytes = open(meta_path, "rb").read()
        if len(meta_bytes) != exp_meta_len or hashlib.sha256(meta_bytes).hexdigest() != exp_meta_sha:
            fail(f"M0 baseline item[{idx}] ({slug}.meta.json) is not byte-for-byte identical to original M0 recording")


def validate_directory(
    rec_dir: str,
    min_items: int,
    expected_manifest_sha256: str | None = None,
    verify_m0_baseline: bool = False,
) -> None:
    if not os.path.isdir(rec_dir):
        fail(f"Directory does not exist: {rec_dir}")

    manifest_path = os.path.join(rec_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        fail(f"Missing manifest.json in {rec_dir}")

    manifest_raw_bytes = open(manifest_path, "rb").read()
    actual_manifest_sha = hashlib.sha256(manifest_raw_bytes).hexdigest()
    if expected_manifest_sha256 is not None:
        resolved_expected = (
            PINNED_CURRENT_MANIFEST_SHA256
            if expected_manifest_sha256.lower() == "pinned"
            else expected_manifest_sha256.lower()
        )
        if actual_manifest_sha != resolved_expected:
            fail(
                f"manifest.json sha256 mismatch against pinned baseline: "
                f"expected={resolved_expected!r} vs actual={actual_manifest_sha!r}"
            )
        if resolved_expected == PINNED_CURRENT_MANIFEST_SHA256:
            verify_m0_baseline = True

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
    if type(total_sent) is not int or total_sent < min_items or total_sent > 36:
        fail(f"manifest.total_http_requests_sent must be int in [{min_items}, 36], got {total_sent!r}")

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

    if verify_m0_baseline:
        verify_m0_baseline_20(rec_dir, items)

    baseline_note = " m0_baseline_20_byte_identical=true" if verify_m0_baseline else ""
    print(
        f"VALID_RECORDED_FIXTURES: items={len(items)} total_http_requests_sent={total_sent} "
        f"started_at={manifest['started_at']} completed_at={manifest['completed_at']}{baseline_note}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate recorded Crossref/OpenAlex fixtures.")
    parser.add_argument("recorded_dir", help="Path to Tests/Fixtures/recorded")
    parser.add_argument("--min-items", type=int, default=28, help="Minimum required fixture items (default: 28)")
    parser.add_argument(
        "--expected-manifest-sha256",
        default=None,
        help="Optional pinned SHA-256 hex digest of manifest.json (or 'pinned' for PINNED_CURRENT_MANIFEST_SHA256)",
    )
    parser.add_argument(
        "--verify-m0-baseline",
        action="store_true",
        help="Verify the original 20 M0 (.raw, .meta.json, manifest.items[:20]) entries are byte-for-byte identical",
    )
    args = parser.parse_args()
    validate_directory(
        args.recorded_dir,
        args.min_items,
        args.expected_manifest_sha256,
        args.verify_m0_baseline,
    )


if __name__ == "__main__":
    main()
