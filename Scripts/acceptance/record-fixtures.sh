#!/usr/bin/env bash
set -euo pipefail

# C15 / C23 / C5 Upstream Fixture Recorder for CiteStudio
# Default behavior: does NOT run and makes ZERO network requests unless CITESTUDIO_RECORD=1
# is explicitly set after user approval.
# When Tests/Fixtures/recorded/manifest.json already exists, runs in strict append-only mode:
# existing recorded requests are NEVER re-sent, existing .raw / .meta.json files are NEVER
# modified, and at most MAX_SUPPLEMENT_REQUESTS=12 new GET requests are sent.

if [[ "${CITESTUDIO_RECORD:-0}" != "1" ]]; then
    echo "SKIPPED: Set CITESTUDIO_RECORD=1 after explicit user approval to record live Crossref/OpenAlex fixtures."
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_BIB="${ROOT_DIR}/Tests/Fixtures/test.bib"
SUPPLEMENT_BIB="${ROOT_DIR}/Tests/Fixtures/c5_nodoi_supplement.bib"
OUT_DIR="${ROOT_DIR}/Tests/Fixtures/recorded"

if [[ ! -f "${TEST_BIB}" ]]; then
    echo "Error: Missing ${TEST_BIB}" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

python3 - "${TEST_BIB}" "${SUPPLEMENT_BIB}" "${OUT_DIR}" <<'PYEOF'
import datetime
import hashlib
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "CiteStudio/0.3.0"
CROSSREF_BASE = "https://api.crossref.org"
OPENALEX_BASE = "https://api.openalex.org"
EXTRA_DOIS = ["10.48550/arxiv.1706.03762"]
MAX_REQUESTS = 24
MAX_SUPPLEMENT_REQUESTS = 12
MIN_INTERVAL_SECONDS = 1.15
MAX_RETRIES_PER_TARGET = 1

total_http_requests_sent = 0


class TransientUpstreamError(Exception):
    pass


def utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_doi(raw: str) -> str:
    d = raw.strip()
    for prefix in ("https://doi.org/", "http://doi.org/", "doi:"):
        if d.lower().startswith(prefix):
            d = d[len(prefix):]
    return d.lower()


def clean_bib_value(raw: str) -> str:
    val = raw.replace("{", "").replace("}", "")
    return re.sub(r"\s+", " ", val).strip()


def extract_field(stanza: str, field_name: str):
    m = re.search(rf"\b{re.escape(field_name)}\s*=\s*\{{", stanza, flags=re.IGNORECASE)
    if not m:
        return None
    idx = m.end()
    depth = 1
    chars = []
    while idx < len(stanza) and depth > 0:
        ch = stanza[idx]
        if ch == "{":
            depth += 1
            chars.append(ch)
        elif ch == "}":
            depth -= 1
            if depth > 0:
                chars.append(ch)
        else:
            chars.append(ch)
        idx += 1
    return clean_bib_value("".join(chars))


def encode_doi_for_path(doi: str) -> str:
    return urllib.parse.quote(doi, safe="/:@!$&'()*+,;=-._~")


def slugify(prefix: str, key: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9._-]+", "_", key).strip("_") or "nonascii"
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:10]
    return f"{prefix}_{safe[:48]}_{digest}"


def assert_allowed_url(url: str) -> None:
    if not (url.startswith("https://api.crossref.org/") or url.startswith("https://api.openalex.org/")):
        print(f"FATAL: Disallowed endpoint URL: {url}", file=sys.stderr)
        sys.exit(1)
    parsed = urllib.parse.urlsplit(url)
    if "@" in parsed.query or "@" in parsed.netloc or "mailto" in url.lower():
        print(f"FATAL: Personal/mailto data forbidden in request URL: {url}", file=sys.stderr)
        sys.exit(1)


def send_single_get(url: str, hard_request_cap: int):
    global total_http_requests_sent
    assert_allowed_url(url)

    if total_http_requests_sent >= hard_request_cap:
        print(
            f"FATAL: Aborting before sending HTTP request #{total_http_requests_sent + 1} "
            f"(hard limit={hard_request_cap}).",
            file=sys.stderr,
        )
        sys.exit(1)

    if total_http_requests_sent > 0:
        time.sleep(MIN_INTERVAL_SECONDS)

    total_http_requests_sent += 1
    requested_at = utc_now_iso()
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": USER_AGENT})

    try:
        with urllib.request.urlopen(req, timeout=15.0) as resp:
            body = resp.read()
            status = int(resp.status)
            ctype = resp.headers.get("Content-Type", "application/json")
            date_hdr = resp.headers.get("Date") or ""
            return status, ctype, date_hdr, requested_at, body
    except urllib.error.HTTPError as err:
        body = err.read() if err.fp is not None else b""
        ctype = err.headers.get("Content-Type", "application/json") if err.headers else "application/json"
        date_hdr = (err.headers.get("Date") if err.headers else None) or ""
        if err.code == 404:
            return 404, ctype, date_hdr, requested_at, body
        if err.code in (429, 403):
            print(
                f"FATAL: Upstream returned HTTP {err.code} for {url}; "
                f"stopping immediately per recording policy (0 retries on 429/403).",
                file=sys.stderr,
            )
            sys.exit(1)
        if 500 <= err.code < 600:
            raise TransientUpstreamError(f"Upstream HTTP {err.code} for {url}") from err
        print(f"FATAL: Unexpected HTTP {err.code} for {url}; stopping immediately.", file=sys.stderr)
        sys.exit(1)
    except (urllib.error.URLError, TimeoutError, socket.timeout) as net_err:
        raise TransientUpstreamError(f"Network/timeout error for {url}: {net_err}") from net_err


def fetch_raw(url: str, hard_request_cap: int):
    max_attempts = 1 + MAX_RETRIES_PER_TARGET
    for attempt in range(1, max_attempts + 1):
        try:
            status, ctype, date_hdr, requested_at, body = send_single_get(url, hard_request_cap)
            return status, ctype, date_hdr, requested_at, body, attempt
        except TransientUpstreamError as exc:
            if attempt >= max_attempts:
                print(f"FATAL: Failed after {attempt} attempt(s) for {url}: {exc}", file=sys.stderr)
                sys.exit(1)
            print(
                f"WARN: Transient error on attempt {attempt} for {url} ({exc}); "
                f"retrying once after >={MIN_INTERVAL_SECONDS}s...",
                file=sys.stderr,
            )
    sys.exit(1)


def parse_bib_files(bib_paths, seen_dois, dois, seen_titles, no_doi_titles):
    for path in bib_paths:
        if not path or not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or not line.startswith("@"):
                    continue
                raw_doi = extract_field(line, "doi")
                title = extract_field(line, "title") or ""
                if raw_doi:
                    nd = normalize_doi(raw_doi)
                    if nd not in seen_dois:
                        seen_dois.add(nd)
                        dois.append(nd)
                elif title:
                    if title not in seen_titles:
                        seen_titles.add(title)
                        no_doi_titles.append(title)


def main():
    bib_path, supplement_bib_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    manifest_path = os.path.join(out_dir, "manifest.json")

    existing_manifest = None
    existing_items = []
    existing_slugs = set()
    existing_urls = set()

    if os.path.isfile(manifest_path):
        with open(manifest_path, encoding="utf-8") as mfh:
            existing_manifest = json.load(mfh)
        existing_items = list(existing_manifest.get("items", []))
        for item in existing_items:
            slug = item["slug"]
            existing_slugs.add(slug)
            existing_urls.add((item["service"], item["url"]))
            raw_p = os.path.join(out_dir, item["raw_file"])
            meta_p = os.path.join(out_dir, f"{slug}.meta.json")
            if not (os.path.isfile(raw_p) and os.path.isfile(meta_p)):
                print(f"FATAL: Existing fixture files missing for {slug}", file=sys.stderr)
                sys.exit(1)

    dois = []
    seen_dois = set()
    no_doi_titles = []
    seen_titles = set()

    parse_bib_files([bib_path, supplement_bib_path], seen_dois, dois, seen_titles, no_doi_titles)

    for extra in EXTRA_DOIS:
        nd = normalize_doi(extra)
        if nd not in seen_dois:
            seen_dois.add(nd)
            dois.append(nd)

    all_targets = []
    for doi in dois:
        enc = encode_doi_for_path(doi)
        all_targets.append(("crossref", f"{CROSSREF_BASE}/works/{enc}", slugify("crossref_doi", doi)))
        all_targets.append(("openalex", f"{OPENALEX_BASE}/works/https://doi.org/{enc}", slugify("openalex_doi", doi)))

    for title in no_doi_titles:
        oa_q = f"search={urllib.parse.quote(title, safe=':,')}&per-page=3"
        cr_q = f"query.bibliographic={urllib.parse.quote(title, safe=':,')}&rows=3"
        all_targets.append(("openalex", f"{OPENALEX_BASE}/works?{oa_q}", slugify("openalex_title", title)))
        all_targets.append(("crossref", f"{CROSSREF_BASE}/works?{cr_q}", slugify("crossref_title", title)))

    if existing_manifest is not None:
        targets = [
            (svc, url, slug)
            for (svc, url, slug) in all_targets
            if slug not in existing_slugs and (svc, url) not in existing_urls
        ]
        hard_cap = MAX_SUPPLEMENT_REQUESTS
        if len(targets) > hard_cap:
            print(
                f"FATAL: Planned new supplement target count {len(targets)} exceeds MAX_SUPPLEMENT_REQUESTS={hard_cap}",
                file=sys.stderr,
            )
            sys.exit(1)
        if not targets:
            print("No new unrecorded targets to fetch; existing fixtures untouched.")
            return
    else:
        targets = all_targets
        hard_cap = MAX_REQUESTS
        if len(targets) > hard_cap:
            print(f"FATAL: Planned target count {len(targets)} exceeds MAX_REQUESTS={hard_cap}", file=sys.stderr)
            sys.exit(1)

    run_started_at = utc_now_iso()
    new_manifest_items = []

    for idx, (service, url, slug) in enumerate(targets, start=1):
        raw_filename = f"{slug}.raw"
        meta_filename = f"{slug}.meta.json"
        raw_path = os.path.join(out_dir, raw_filename)
        meta_path = os.path.join(out_dir, meta_filename)

        if os.path.exists(raw_path) or os.path.exists(meta_path):
            print(f"FATAL: Refusing to overwrite existing recorded file for slug={slug}", file=sys.stderr)
            sys.exit(1)

        status, ctype, date_hdr, requested_at, body, attempts = fetch_raw(url, hard_cap)

        with open(raw_path, "wb") as bf:
            bf.write(body)

        meta = {
            "slug": slug,
            "service": service,
            "url": url,
            "status": status,
            "content_type": ctype,
            "requested_at": requested_at,
            "response_date_header": date_hdr,
            "raw_file": raw_filename,
            "byte_length": len(body),
            "sha256": hashlib.sha256(body).hexdigest(),
            "attempts": attempts,
        }
        with open(meta_path, "w", encoding="utf-8") as mf:
            json.dump(meta, mf, indent=2, sort_keys=True)
            mf.write("\n")

        new_manifest_items.append(meta)
        print(
            f"[{idx}/{len(targets)}] Recorded {service} HTTP {status} "
            f"({len(body)} bytes, Date='{date_hdr}', attempts={attempts}) -> {raw_filename}"
        )

    completed_at = utc_now_iso()
    if existing_manifest is not None:
        combined_items = existing_items + new_manifest_items
        started_at = existing_manifest["started_at"]
        combined_requests = int(existing_manifest["total_http_requests_sent"]) + total_http_requests_sent
    else:
        combined_items = new_manifest_items
        started_at = run_started_at
        combined_requests = total_http_requests_sent

    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "completed_at": completed_at,
                "count": len(combined_items),
                "items": combined_items,
                "started_at": started_at,
                "total_http_requests_sent": combined_requests,
                "user_agent": USER_AGENT,
            },
            fh,
            indent=2,
            sort_keys=True,
        )
        fh.write("\n")
    print(
        f"Appended {len(new_manifest_items)} new recorded upstream fixtures to {out_dir} "
        f"(new_http_requests_sent={total_http_requests_sent}, total_manifest_items={len(combined_items)})"
    )


if __name__ == "__main__":
    main()
PYEOF
