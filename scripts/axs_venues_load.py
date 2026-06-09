#!/usr/bin/env python3
"""
Parse scripts/axs_venues_raw.txt (the AXS.com venue scrape, section-tagged),
strip site noise / internal-test artifacts, normalize names to match the
canonical venue normalization used in Postgres, dedupe, and emit batched
INSERT statements for public.axs_venues.

Normalization MUST mirror the SQL used to match against the canonical set:
    lower(name) -> strip leading 'the ' -> remove every char not [a-z0-9]
(no unaccent — Postgres lower() leaves accents, which [^a-z0-9] then drops).
CJK / accent-only names normalize to '' under that rule, so they get a
distinct 'cjk:'-prefixed key (kept for the reference list, never matched).
"""
import re, sys, pathlib

RAW = pathlib.Path(__file__).with_name("axs_venues_raw.txt")
OUT = pathlib.Path(__file__).with_name("axs_venues_insert.sql")

# Noise: AXS internal test/QA/office/sandbox entries + fee-flag artifacts +
# placeholders + "do not use" + pure long digit strings. Conservative on
# purpose so we don't drop real venues.
NOISE_RE = [
    re.compile(r"^axs\b", re.I),                # AXS Demo Venue, AXS QA Lounge, AXS LA Office...
    re.compile(r"\bse_fees", re.I),             # SE_Fees_OFF / _ON / _AND_Taxes_ON
    re.compile(r"do not use", re.I),            # "... - DO NOT USE"
    re.compile(r"placeholder", re.I),           # Venue 1 Placeholder, Venue_NZ_P1? (kept; see below)
    re.compile(r"\bsandbox\b", re.I),           # AXS Anywhere Sandbox Venue
    re.compile(r"testing venue", re.I),         # Toby - Testing Venue
    re.compile(r"^test venue\b", re.I),         # TEST Venue 01 (en-US)
    re.compile(r"demonstration", re.I),         # AXS ANZ Demonstration (also caught by ^axs)
    re.compile(r"^\d{7,}$"),                    # 965328741
    re.compile(r"^a l p h a b e t$", re.I),     # spaced dup of "Alphabet"
    re.compile(r"^neww+$", re.I),               # NEWWWWW
    re.compile(r"^tbd$", re.I),
]

def is_noise(name: str) -> bool:
    return any(p.search(name) for p in NOISE_RE)

def norm(name: str) -> str:
    s = name.strip().lower()
    s = re.sub(r"^the ", "", s)
    s = re.sub(r"[^a-z0-9]+", "", s)
    return s

def main():
    section = None
    raw_count = 0
    noise = []
    seen = {}            # norm_key -> (axs_name, section)
    for line in RAW.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^=== (.+) ===$", line)
        if m:
            section = m.group(1)
            continue
        raw_count += 1
        if is_noise(line):
            noise.append(line)
            continue
        n = norm(line)
        key = n if n else "cjk:" + re.sub(r"\s+", " ", line.strip().lower())
        if key not in seen:               # first occurrence wins
            seen[key] = (line, section)

    rows = [(name, key, sec) for key, (name, sec) in seen.items()]

    def esc(s):
        return s.replace("'", "''")

    # axs_name_norm is a GENERATED column, so we only transmit name + section.
    # Emit a handful of numbered batch files so each fits comfortably in one
    # execute_sql call.
    B = 3000
    nbatch = (len(rows) + B - 1) // B
    for bi in range(nbatch):
        chunk = rows[bi*B:(bi+1)*B]
        p = OUT.with_name(f"axs_venues_insert_{bi+1}.sql")
        with p.open("w", encoding="utf-8") as f:
            f.write("INSERT INTO public.axs_venues (axs_name, section) VALUES\n")
            f.write(",\n".join(
                f"('{esc(nm)}',{('NULL' if sec is None else chr(39)+esc(sec)+chr(39))})"
                for nm, key, sec in chunk))
            f.write("\nON CONFLICT (axs_name_norm) DO NOTHING;\n")
        print(f"  batch {bi+1}: {len(chunk)} rows -> {p.name} ({p.stat().st_size} bytes)")

    import json
    JSON_OUT = OUT.with_name("axs_venues.json")
    JSON_OUT.write_text(json.dumps(
        [{"axs_name": nm, "section": sec} for nm, key, sec in rows],
        ensure_ascii=False), encoding="utf-8")
    print(f"JSON written         : {JSON_OUT.name} ({JSON_OUT.stat().st_size} bytes, {len(rows)} rows)")

    print(f"raw venue lines      : {raw_count}")
    print(f"noise filtered       : {len(noise)}")
    print(f"distinct kept rows   : {len(rows)}")
    print(f"  of which CJK/other : {sum(1 for _,k,_ in rows if k.startswith('cjk:'))}")
    print("\n--- noise filtered (first 60) ---")
    for x in noise[:60]:
        print("  ", x)

if __name__ == "__main__":
    main()
