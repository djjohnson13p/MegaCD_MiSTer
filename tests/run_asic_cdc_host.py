"""Run production ASIC/CDC host regressions; --baseline extracts pristine RTL."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghdl", default="ghdl")
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--baseline", help="known Git commit to test with current bench")
    parser.add_argument("--asic", type=Path, help="alternate ASIC source for mutation checks")
    parser.add_argument("--cdc", type=Path, help="alternate CDC source for combined-track integration")
    parser.add_argument("--matrix", action="store_true", help="also test long transfers and buffer wrap")
    parser.add_argument("--cases", type=int, nargs="+", default=list(range(20)))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    source = build / "source"
    source.mkdir(exist_ok=True)
    paths = ["rtl/MCD/ASIC_PKG.vhd", "rtl/MCD/ASIC.vhd", "rtl/MCD/CDC.vhd"]
    manifest = {"baseline": args.baseline, "files": {},
                "overrides": {"asic": str(args.asic) if args.asic else None,
                              "cdc": str(args.cdc) if args.cdc else None}}
    for relative in paths + ["tests/tb_asic_cdc_host.vhd"]:
        if args.asic and relative == "rtl/MCD/ASIC.vhd":
            data = args.asic.read_bytes()
        elif args.cdc and relative == "rtl/MCD/CDC.vhd":
            data = args.cdc.read_bytes()
        elif args.baseline and relative in paths:
            data = subprocess.run(
                ["git", "show", f"{args.baseline}:{relative}"], cwd=repo,
                check=True, stdout=subprocess.PIPE,
            ).stdout
        else:
            data = (repo / relative).read_bytes()
        target = source / Path(relative).name
        target.write_bytes(data)
        manifest["files"][relative] = hashlib.sha256(data).hexdigest()
    ghdl = shutil.which(args.ghdl)
    if not ghdl:
        parser.error(f"GHDL executable not found: {args.ghdl}")
    ghdl = str(Path(ghdl).resolve())
    manifest["ghdl"] = subprocess.run(
        [ghdl, "--version"], capture_output=True, text=True, check=True,
    ).stdout
    (build / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    flags = ["--std=08", "--ieee=synopsys"]
    for name, command in [
        ("analyze", [ghdl, "-a", *flags, *[str(source / Path(p).name) for p in paths], str(source / "tb_asic_cdc_host.vhd")]),
        ("elaborate", [ghdl, "-e", *flags, "tb_asic_cdc_host"]),
    ]:
        proc = subprocess.run(command, cwd=build, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (build / f"{name}.log").write_text(proc.stdout, encoding="utf-8")
        if proc.returncode:
            print(proc.stdout)
            return proc.returncode
    results = []
    combinations = [(case, 8, 0) for case in args.cases]
    if args.matrix:
        combinations += [(case, length, address)
                         for length in (32, 256, 2352)
                         for address in (0, 0x3FFC)
                         for case in args.cases if case <= 5]
    for case, length, address in combinations:
        proc = subprocess.run(
            [ghdl, "-r", *flags, "tb_asic_cdc_host", f"-gTEST_CASE={case}",
             f"-gTRANSFER_BYTES={length}", f"-gSOURCE_ADDR={address}", "--assert-level=error"],
            cwd=build, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        name = f"case-{case}" if length == 8 and address == 0 else f"case-{case}-bytes-{length}-addr-{address:04x}"
        (build / f"{name}.log").write_text(proc.stdout, encoding="utf-8")
        results.append({"case": case, "bytes": length, "address": address, "exit": proc.returncode})
        print(f"{name}: {'PASS' if proc.returncode == 0 else 'FAIL'}")
        if proc.returncode:
            print(proc.stdout.splitlines()[0])
    (build / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    return int(any(item["exit"] != 0 for item in results))


if __name__ == "__main__":
    sys.exit(main())
