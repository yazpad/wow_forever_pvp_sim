#!/usr/bin/env python3
"""Interleave two MCTS binaries on identical fixed-budget workloads."""
import argparse
import json
import pathlib
import platform
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("before", help="ReleaseFast baseline executable")
parser.add_argument("after", help="ReleaseFast candidate executable")
parser.add_argument("--repeats", type=int, default=3)
parser.add_argument("--rounds", type=int, default=60)
parser.add_argument("--output", default="benchmarks/mcts/staging_optimization.json")
args = parser.parse_args()
if args.repeats < 1 or args.rounds < 1:
    parser.error("repeats and rounds must be positive")

cases = [("default", []), ("terminal", ["--evaluator", "rollout"]),
         ("suffix", ["--start-ticks", "300", "--boundary", "tick"])]
binaries = [("before", args.before), ("after", args.after)]
runs = []
for case, extra in cases:
    for repeat in range(args.repeats):
        for version, binary in (binaries if repeat % 2 == 0 else binaries[::-1]):
            command = [binary, "--benchmark", "--rounds", str(args.rounds),
                       "--rollouts", "512"] + extra
            result = json.loads(subprocess.check_output(command, text=True))
            runs.append(dict(case=case, repeat=repeat, version=version,
                             command=command, result=result))
            print(case, repeat, version, result["rollouts_per_second"], flush=True)

summaries = {}
for case, _ in cases:
    rates = {version: statistics.median(
        run["result"]["rollouts_per_second"] for run in runs
        if run["case"] == case and run["version"] == version)
        for version, _ in binaries}
    # These counters do not depend on elapsed time. Any mismatch invalidates
    # a before/after performance claim on matched search trajectories.
    for repeat in range(args.repeats):
        pair = [run["result"] for run in runs
                if run["case"] == case and run["repeat"] == repeat]
        for key in ("rollouts", "nodes", "max_depth", "lane_utilization"):
            if pair[0][key] != pair[1][key]:
                raise RuntimeError(f"unmatched workload: {case}, {repeat}, {key}")
    summaries[case] = dict(rates, speedup=rates["after"] / rates["before"])
    print(case, summaries[case], flush=True)

output = pathlib.Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(dict(host=platform.platform(), runs=runs,
                                  summaries=summaries), indent=2) + "\n")
