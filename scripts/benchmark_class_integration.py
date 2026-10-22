#!/usr/bin/env python3
"""Interleave saved before/after class_perf binaries and retain raw results."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("rounds must be positive")
    paths = {"before": args.before.resolve(), "after": args.after.resolve()}
    results = {"before": [], "after": []}
    for turn in range(args.rounds):
        order = ("before", "after") if turn % 2 == 0 else ("after", "before")
        for name in order:
            output = subprocess.check_output([str(paths[name])], text=True)
            results[name].extend(json.loads(line) for line in output.splitlines() if line.strip())
    keys = sorted({(row["a"], row["b"]) for row in results["before"]})
    summary = []
    for a, b in keys:
        samples = {name: [r for r in rows if r["a"] == a and r["b"] == b] for name, rows in results.items()}
        invariants = {tuple(row[key] for key in ("snapshot_bytes", "choices", "checksum")) for rows in samples.values() for row in rows}
        if len(invariants) != 1 or any(not rows for rows in samples.values()):
            raise SystemExit(f"Workload/layout mismatch for {a}/{b}")
        entry = {"a": a, "b": b, "samples_per_binary": len(samples["before"]), "snapshot_bytes": samples["before"][0]["snapshot_bytes"], "choices": samples["before"][0]["choices"]}
        for metric in ("tick_ns", "copy_ns"):
            medians = {name: statistics.median(row[metric] for row in rows) for name, rows in samples.items()}
            entry[metric] = {**medians, "change_percent": 100 * (medians["after"] / medians["before"] - 1)}
        summary.append(entry)
    report = {"platform": platform.platform(), "binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}, "rounds": args.rounds, "summary": summary, "raw": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
