#!/usr/bin/env python3
"""Compare complete replay frames and search results from two MCTS binaries."""
import argparse
import hashlib
import itertools
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("before")
parser.add_argument("after")
parser.add_argument("--output", default="benchmarks/mcts/masks_equivalence.json")
args = parser.parse_args()
runs = []

def normalized_metadata(path):
    data = json.loads(path.read_text())
    data["options"].pop("output")
    data["summary"].pop("compute_seconds")
    for decision in data["decisions"]:
        decision.pop("seconds")
    return data

with tempfile.TemporaryDirectory(prefix="mcts-equivalence-") as folder:
    folder = pathlib.Path(folder)
    cases = itertools.product(("warlock", "frost_mage"), repeat=2)
    for a, b in cases:
        for boundary, random_policy in itertools.product(("event", "tick"), (False, True)):
            index = len(runs)
            common = ["--spec-a", a, "--spec-b", b, "--boundary", boundary,
                      "--seconds", "6", "--rollouts", "128", "--depth", "2",
                      "--seed", str(100 + index), "--workers", str(1 + index % 2)]
            if random_policy:
                common += ["--random-rollout", "--algorithm", "exp3", "--evaluator", "rollout"]
            outputs = []
            for version, binary in (("before", args.before), ("after", args.after)):
                path = folder / f"{index}-{version}.lua"
                subprocess.run([binary, *common, "--output", str(path)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                outputs.append(path)
            # Metadata equality checks actions, complete root strategies/choices,
            # exact tick/node statistics, initial state, and final summary.
            metadata = [normalized_metadata(pathlib.Path(str(p) + ".search.json")) for p in outputs]
            if metadata[0] != metadata[1]:
                raise RuntimeError(f"search mismatch: {a}, {b}, {boundary}, random={random_policy}")
            trajectories = [json.loads(pathlib.Path(str(p) + ".json").read_text()) for p in outputs]
            if trajectories[0] != trajectories[1]:
                raise RuntimeError(f"replay mismatch: {a}, {b}, {boundary}, random={random_policy}")
            runs.append(dict(spec_a=a, spec_b=b, boundary=boundary,
                             random_rollout=random_policy, arguments=common,
                             decisions=len(metadata[0]["decisions"]), matched=True,
                             search_sha256=hashlib.sha256(json.dumps(metadata[0], sort_keys=True).encode()).hexdigest(),
                             replay_sha256=hashlib.sha256(json.dumps(trajectories[0], sort_keys=True).encode()).hexdigest()))
            print("matched", a, b, boundary, "random=" + str(random_policy), flush=True)

output = pathlib.Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(runs, indent=2) + "\n")
