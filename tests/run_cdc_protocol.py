#!/usr/bin/env python3
"""Run port-driven tests against candidate CDC or its exact upstream baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

BASELINE = "a3a3da81d04b22533def34f26eb9d748be9d2d0c"
BASELINE_FAILURES = {
    1: "decoder interrupt missing without CD sectors",
    2: "decoder event generated with SYIEN disabled",
    3: "disabling DECEN left decoder interrupt pending",
    4: "masked decoder did not update IFSTAT",
    6: "decoder interrupt missing without CD sectors",
    9: "SYDEN-only event did not clear",
    10: "decoder interrupt missing without CD sectors",
    13: "decoder interrupt missing without CD sectors",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ghdl = shutil.which("ghdl")
    if not ghdl:
        parser.error("ghdl not found; dot-source core-lab/tools/activate.ps1 first")
    source = repo / "rtl/MCD/CDC.vhd"
    if args.baseline:
        source = out / "CDC.upstream.vhd"
        source.write_bytes(subprocess.check_output(
            ["git", "show", f"{BASELINE}:rtl/MCD/CDC.vhd"], cwd=repo))
    else:
        snapshot = out / "CDC.candidate.vhd"
        snapshot.write_bytes(source.read_bytes())
        source = snapshot
    sources = [source, repo / "tests/tb_cdc_protocol.vhd"]
    if not args.baseline:
        sources.append(repo / "tests/tb_cdc_pal_clock.vhd")
    common = [ghdl, "-a", "--std=08", f"--workdir={out}"]
    subprocess.run(common + [str(p) for p in sources], check=True, cwd=repo, timeout=60)
    results = []
    for case in range(14):
        cmd = [ghdl, "-r", "--std=08", f"--workdir={out}",
               "tb_cdc_protocol", f"-gTEST_CASE={case}", "--assert-level=error"]
        result = subprocess.run(cmd, cwd=repo, capture_output=True, text=True, timeout=60)
        log = result.stdout + result.stderr
        (out / f"case-{case}.log").write_text(log, encoding="utf-8")
        failed = result.returncode != 0
        expected_failure = args.baseline and case in BASELINE_FAILURES
        expected_text = BASELINE_FAILURES[case] if expected_failure else f"PASS CDC case {case}"
        match = failed == expected_failure and expected_text in log
        results.append(dict(case=case, exit_code=result.returncode,
                            expected_failure=bool(expected_failure), matched=match))
        print(f"case {case}: {'FAIL' if failed else 'PASS'}"
              f" ({'expected' if match else 'UNEXPECTED'})")
    if not args.baseline:
        result = subprocess.run([ghdl, "-r", "--std=08", f"--workdir={out}",
                                 "tb_cdc_pal_clock", "--assert-level=error"],
                                cwd=repo, capture_output=True, text=True, timeout=60)
        log = result.stdout + result.stderr
        (out / "pal.log").write_text(log, encoding="utf-8")
        match = result.returncode == 0 and "PASS CDC PAL timing" in log
        results.append(dict(case="pal", exit_code=result.returncode,
                            expected_failure=False, matched=match))
        print(f"PAL timing: {'PASS' if match else 'FAIL'}")
    report = dict(baseline=BASELINE, tested="baseline" if args.baseline else "candidate",
                  source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  bench_sha256=hashlib.sha256(sources[1].read_bytes()).hexdigest(),
                  results=results, success=all(r["matched"] for r in results))
    (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
