# Local CDC decoder compatibility track

This branch repairs a reproducible missing CDC protocol behavior: an enabled
decoder stops producing decoder status/interrupts when the HPS is not delivering
new sectors. It also fixes missing sync gating, automatic DECI release, and
decoder-disable acknowledgment. It does **not** establish that any reported game
freeze is fixed. This is a simulation and isolated-synthesis candidate, pending
full-core compilation, fitting, timing analysis, and hardware validation.

## Locked primary source and independent oracle

- Core repository: [MiSTer-devel/MegaCD_MiSTer](https://github.com/MiSTer-devel/MegaCD_MiSTer).
  Baseline `a3a3da81d04b22533def34f26eb9d748be9d2d0c`, checked 2026-10-23.
  Its latest change is the unrelated T80 warm-reset fix from 2026-07-30.
- [Production CDC at that baseline](https://github.com/MiSTer-devel/MegaCD_MiSTer/blob/a3a3da81d04b22533def34f26eb9d748be9d2d0c/rtl/MCD/CDC.vhd):
  Git blob `08b56d2cb428164798d03551657485a2f59b9575`.
  Upstream only sets DECI on the final input word and releases it on STAT3/reset.
  It has no autonomous decoder clock, no automatic DECI release, and no SYIEN/SYDEN
  gating for a completed input sector. The source has not changed since 2020-05-02.
- [MiSTer issue 50](https://github.com/MiSTer-devel/MegaCD_MiSTer/issues/50), opened
  2020-07-13, remains open. Its 2025 comment reports testing release 2024-04-08;
  its 2026-08-05 comment points to jGenesis's analysis. These are leads, not proof
  that every reported test failure remains in current RTL.
- Independent hardware-derived tests: Krikzz's original `mcd-verificator`, before
  its 2026 repository reorganization. The old `krikzz/MEGA-PRO` now redirects to
  `krikzz/mega-ed-pub`. Pin: `8b72838f8b449e34e519b53d9e9b8fd2021a6044`.
  [Readme](https://github.com/krikzz/mega-ed-pub/blob/8b72838f8b449e34e519b53d9e9b8fd2021a6044/mcd-verificator/readme.txt)
  states the tests derive from real hardware and results are valid on NTSC.
  The complete verificator erases BRAM/RAM-cart data, so it must never be run
  against the user's normal saves. These RTL benches use synthetic ports only.
- [Original decoder test](https://github.com/krikzz/mega-ed-pub/blob/8b72838f8b449e34e519b53d9e9b8fd2021a6044/mcd-verificator/src/test_cdc.c#L181):
  lines 181-207 test idle SYIEN gating and recurring events without STAT3 ack;
  lines 273-277 require DECEN disable to release DECI.
  Blob `68cedab522e5ecf1fb3aec17d978a863217f03ae`.
- [Later tests](https://github.com/krikzz/mega-ed-pub/blob/8b72838f8b449e34e519b53d9e9b8fd2021a6044/mcd-verificator/src/test_cdc_new.c#L1167):
  lines 1177-1183 require recurring 75 Hz decoder interrupts, lines 1234-1264
  measure an approximately 40% active DECI phase in that test configuration,
  and lines 1280-1294 check IFSTAT still changes with DECIEN masked.
  Blob `e4b8383786e8d0bb42136a6044c46a55e0b6db14`.
- [Sanyo manual retained by the core](https://github.com/MiSTer-devel/MegaCD_MiSTer/blob/a3a3da81d04b22533def34f26eb9d748be9d2d0c/docs/Sanyo_LC8950_%26_LC8951.pdf):
  PDF pages 55-57 (printed 44-46) distinguish inserted SYIEN sync from detected
  SYDEN sync. This prevents an incorrect blanket SYIEN gate on received sectors.
  Figure 11, PDF page 82 (printed 71), shows the independent status latch and
  interrupt mask; it does not specify simultaneous set/reset priority.
- [jGenesis discussion](https://github.com/jsgroth/jgenesis/issues/105) was read
  for context, including the 2026 reopening for CPU timing errors. It is not the
  expected-value source for the new RTL tests.

## Scope and implementation

Only `rtl/MCD/CDC.vhd` and its `PALSW` connection in `rtl/MCD/MCD.vhd` change.
The decoder phase uses the actual core clocks, 53,693,175 Hz NTSC and
53,203,423 Hz PAL, matching existing PLL/PCM/CDDA definitions. The bounded
counter wraps at 715,909 or 709,379 system clocks per nominal 75 Hz interval.
The PAL check verifies that selected period at the PAL system clock; it is not a
new real-PAL hardware measurement.

SYIEN permits autonomous sync insertion. Completed synthetic sectors can also
trigger an event with SYDEN alone, preserving sync-hunt operation. Reading STAT3
acknowledges DECI, changing DECIEN masks only the pin, and disabling DECEN releases
the pending status. A sector completion takes priority over a coincident STAT3
read, preserving the baseline's event ordering rather than claiming an undocumented
silicon collision rule.

The HPS supplies sector bursts rather than a physical continuous CD sample clock.
The first word starts a fresh timer interval; completion synchronizes it again.
This prevents nominal idle expiry from announcing stale HEAD/PT during an ordinary
burst that straddles the prior expiry. The timer never waits indefinitely for
WORD_CNT to return to zero: a partial packet followed by silence still receives
periodic events. Exact startup phase and arbitrary slow/late burst arrival remain
integration approximations; hardware validation must check that phase behavior.

The approximately 40% low phase is taken from Krikzz's tested Mega-CD configuration.
The bundled LC8950/51 manual documents mode-dependent active durations, so this
patch must not be described as a complete chip-accurate decoder timing model.
Existing STAT3.VALST timing is also approximate and is deliberately excluded:
the upstream sets VALST on STAT3 read, while the manual describes different validity
timing. This patch repairs IFSTAT.DECI and the interrupt protocol only.

The initial hypothesis about transfer-complete DTEI timing was **refuted** by the
production byte-transfer test. HRD is the ASIC's byte-prefetch handshake, so
consuming the last CDC byte can precede the CPU's final host-word read. No DTEI,
transfer state machine, buffer addressing, or ASIC host-write logic was changed.

## Reproducible gates and results

From the repository root in PowerShell:

```powershell
. ../../tools/activate.ps1
$cdcPy = 'C:/Users/djjoh/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
& $cdcPy tests/run_cdc_protocol.py --baseline --out ../../builds/megacd-cdc-baseline-final
& $cdcPy tests/run_cdc_protocol.py --out ../../builds/megacd-cdc-candidate-final
ghdl --synth --std=08 --workdir=../../builds/megacd-cdc-candidate-final --out=verilog CDC
git -c core.whitespace=cr-at-eol diff --check
```

Both runner invocations exit 0 only if their expected pass/failure matrix matches.
`--baseline` obtains the original production CDC directly with `git show` at the
locked SHA; it never reimplements the CDC or patches baseline behavior. Every
expected failure has an assertion log in the output directory. The candidate runs
the same NTSC tests plus the separate PAL port/clock integration test.

| Case | Behavior | Baseline | Candidate |
|---|---|---|---|
| 0 | Reset IFSTAT and pins | Pass | Pass |
| 1 | Four idle interrupts, 75 Hz, automatic release | Fail | Pass |
| 2 | Both sync mechanisms disabled for multiple periods | Fail | Pass |
| 3 | DECEN disable releases pending DECI | Fail | Pass |
| 4 | Masked pin still updates and acknowledges IFSTAT | Fail | Pass |
| 5 | Stalled byte DMA, data/address/count, DTEI/DTACK | Pass | Pass |
| 6 | STAT3 ack preserves next period | Fail | Pass |
| 7 | Disabled decoder stays quiet | Pass | Pass |
| 8 | Sector buffer count, header, PT unchanged | Pass | Pass |
| 9 | SYDEN-only sector, auto-release, no inserted sync | Fail | Pass |
| 10 | Mask/unmask does not acknowledge active status | Fail | Pass |
| 11 | Sector completion concurrent with STAT3 read | Pass | Pass |
| 12 | Incoming burst straddles prior idle expiry | Pass | Pass |
| 13 | Partial sector followed by silence recurs | Fail | Pass |
| PAL | Four idle events at PAL system clock | No PAL port | Pass |

GHDL 6.0.0 analysis and isolated synthesis pass for both baseline and candidate;
candidate production CDC also passes VHDL-93 analysis. A separate reviewer checked
clock enables, sync interpretation, collision ordering, and partial-stream behavior.
Logs and machine-readable `results.json` files live under the named `core-lab/builds`
directories, outside commits. Simulation proves this bounded protocol behavior,
not fit, timing closure, or game compatibility.

## Hardware acceptance and remaining work

1. Compile both unchanged baseline and candidate with the same requested Quartus
   version, inspect resource/fit/timing reports, and retain source/RBF hashes.
2. Use a separately named test RBF and disposable save storage. Exercise a minimal
   owned/synthetic test that enables DECEN+SYIEN, then stops sector input: observe
   repeated INT5/DECI, automatic release, and STAT3 acknowledgment without lockup.
3. Check continuous CD streaming and seek/pause/resume across representative owned
   games and both region clocks. Compare same-device baseline/candidate behavior.
4. Run a non-destructive isolated version of the decoder oracle, or the full
   verificator only with disposable BRAM/RAM-cart copies. New failures in other
   verificator tests are not silently classified as fixed by this patch.
5. A reported game freeze becomes a claimed compatibility fix only after the
   failing wait/protocol can be tied to this decoder behavior and the same scenario
   passes on the candidate. No such causal game result is claimed here.

No ROM/BIOS/save data was read, no device was modified, no remote writes or outreach
were performed. The local upstream push URL and pre-push hook block accidental pushes.
