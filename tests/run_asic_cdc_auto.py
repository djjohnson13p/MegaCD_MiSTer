"""Run adjacent production ASIC/CDC automatic-DMA regressions; --baseline extracts pristine RTL."""
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
    parser.add_argument("--destinations", type=int, nargs="+", default=[5,7])
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
    for relative in paths + ["tests/tb_asic_cdc_auto.vhd"]:
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
        ("analyze", [ghdl, "-a", *flags, *[str(source / Path(p).name) for p in paths], str(source / "tb_asic_cdc_auto.vhd")]),
        ("elaborate", [ghdl, "-e", *flags, "tb_asic_cdc_auto"]),
    ]:
        proc = subprocess.run(command, cwd=build, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (build / f"{name}.log").write_text(proc.stdout, encoding="utf-8")
        if proc.returncode:
            print(proc.stdout)
            return proc.returncode
    results = []
    combinations = [(dest, 32, 0x3FFC, 3) for dest in args.destinations]
    if args.matrix:
        combinations += [(dest, length, address, delay)
                         for dest in args.destinations for length in (8,256,2352)
                         for address in (0,0x3FFC) for delay in ((1,7) if dest == 5 else (3,))]
    for dest, length, address, delay in combinations:
        proc = subprocess.run(
            [ghdl, "-r", *flags, "tb_asic_cdc_auto", f"-gDESTINATION={dest}",
             f"-gTRANSFER_BYTES={length}", f"-gSOURCE_ADDR={address}", f"-gPRG_DELAY={delay}",
             f"-gTIMEOUT_US={100 if dest == 4 else 3000}", "--assert-level=error"],
            cwd=build, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        name = f"dest-{dest}-bytes-{length}-addr-{address:04x}-delay-{delay}"
        (build / f"{name}.log").write_text(proc.stdout, encoding="utf-8")
        results.append({"destination": dest, "bytes": length, "address": address,
                        "prg_delay": delay, "exit": proc.returncode})
        print(f"{name}: {'PASS' if proc.returncode == 0 else 'FAIL'}")
        if proc.returncode:
            lines = [line for line in proc.stdout.splitlines() if "assertion failure" in line]
            print(lines[0] if lines else proc.stdout.splitlines()[0])
    (build / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    return int(any(item["exit"] != 0 for item in results))


if __name__ == "__main__":
    sys.exit(main())
