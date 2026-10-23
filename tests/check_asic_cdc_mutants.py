"""Require host regressions to reject targeted broken ASIC implementations."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghdl", default="ghdl")
    parser.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.build_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    original = (repo / "rtl/MCD/ASIC.vhd").read_text(encoding="utf-8")
    main_skip = 'when "00100" =>\t\t\t--$A12008 CDC host data: writes skip a word\n\t\t\t\t\t\t\tMAIN_CPU_CDC_READ <= \'1\';'
    sub_skip = 'when "0000100" =>\t\t\t--$FF8008 CDC host data: writes skip a word\n\t\t\t\t\t\t\t\tSUB_CPU_CDC_READ <= \'1\';'
    host_end = 'if CDC_DTEN_N = \'1\' and (DD = "010" or DD = "011") then'
    mutants = [
        ("ignore-main-write", main_skip, main_skip.replace("<= '1';", "<= '0';"), 2, "host writes did not skip"),
        ("ignore-sub-write", sub_skip, sub_skip.replace("<= '1';", "<= '0';"), 3, "host writes did not skip"),
        ("late-edt", host_end, "if false then", 4, "EDT missing while final host word"),
        ("early-edt", host_end, "if true then", 4, "EDT asserted before final buffered word"),
        ("wrong-cpu-consumes", "if MAIN_CPU_CDC_READ = '1' then", "if MAIN_CPU_CDC_READ = '1' or SUB_CPU_CDC_READ = '1' then", 6, "wrong CPU advanced"),
        ("mode-does-not-clear", "if CDC_MODE_SET = '1' then", "if false then", 12, "mode write did not leave EDT cleared"),
        ("held-write-retriggers", "if M68K_GA_SEL = '1' and M68K_REG_DTACK_N = '1' then", "if M68K_GA_SEL = '1' then", 8, "held write did not skip exactly one word"),
    ]
    results = []
    for name, before, after, case, message in mutants:
        if original.count(before) != 1:
            raise RuntimeError(f"{name}: mutation site is not unique")
        source = output / f"{name}.vhd"
        source.write_text(original.replace(before, after, 1), encoding="utf-8")
        build = output / name
        proc = subprocess.run(
            [sys.executable, str(repo / "tests/run_asic_cdc_host.py"),
             "--ghdl", args.ghdl, "--build-dir", str(build),
             "--asic", str(source), "--cases", str(case)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        (output / f"{name}.log").write_text(proc.stdout, encoding="utf-8")
        log_path = build / f"case-{case}.log"
        log = log_path.read_text(encoding="utf-8") if log_path.exists() else ""
        killed = proc.returncode == 1 and "assertion failure" in log and message in log
        results.append({"mutant": name, "case": case, "killed": killed, "required_assertion": message})
        print(f"{name}: {'KILLED' if killed else 'UNEXPECTED'}")
        if not killed:
            print(proc.stdout)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    return int(not all(item["killed"] for item in results))


if __name__ == "__main__":
    sys.exit(main())
