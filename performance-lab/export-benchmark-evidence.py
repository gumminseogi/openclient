#!/usr/bin/env python3
"""Retain payload-free benchmark evidence even if artifact upload is unavailable."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        return {"unavailable": str(error)}


evidence = {"schema": 1, "comparison": load(root / "extreme/paired-comparison.json"), "variants": {}}
for variant in ("baseline", "patched"):
    folder = root / "extreme" / variant
    case = folder / "seeded-revisit-trial1-g0"
    record = {"provenance": load(folder / "provenance.json"),
              "measurements": load(folder / "measurements.json"),
              "validation": load(folder / "validation.json"),
              "seed_proof": load(folder / "cache-seed/cache-seed-proof.json"),
              "seed_validation": load(folder / "cache-seed/validation.json"),
              "regression_summary": load(folder / "dedup-regressions/summary.json"),
              "ui_summary": load(case / "summary.json"),
              "native_rows": [], "app_requests": [], "completed_ui_evidence": []}
    for path in sorted((case / "probes").glob("*.jsonl")):
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
                if row.get("phase") != "heartbeat":
                    record["native_rows"].append(row)
            except ValueError as error:
                record.setdefault("parse_errors", []).append(str(error))
    path = case / "requests.jsonl"
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
                if not row.get("path", "").startswith("/_lab/") or row.get("path") == "/_lab/reference":
                    record["app_requests"].append(row)
            except ValueError as error:
                record.setdefault("parse_errors", []).append(str(error))
    for path in (case / "attachments").rglob("*.json"):
        entry = load(path)
        if isinstance(entry, dict) and entry.get("experiment") == "extreme_session_load" and entry.get("checkpoint") == "complete":
            record["completed_ui_evidence"].append(entry)
    evidence["variants"][variant] = record

encoded = json.dumps(evidence, indent=2, sort_keys=True)
(root / "core-evidence.json").write_text(encoded + "\n")
print("BENCHMARK_EVIDENCE_JSON_BEGIN")
print(encoded)
print("BENCHMARK_EVIDENCE_JSON_END")
