# Local CDC host-transfer compatibility track

The production ASIC ignores writes to the main/sub CPU host-data ports and raises
EDT too late for a transfer's final buffered word. It also treats idle CDC DTEN as
completion, causing EDT to reappear after software clears it through the mode
register. This patch repairs those independently reproducible protocol failures.
It is a simulation candidate. Full-core fit, timing, and MiSTer acceptance remain.
No particular reported game freeze is claimed fixed.

## Baseline and hardware oracle

Baseline: `MiSTer-devel/MegaCD_MiSTer` at
`a3a3da81d04b22533def34f26eb9d748be9d2d0c`.

Independent expected behavior comes from Krikzz's hardware-derived verificator,
`krikzz/mega-ed-pub` at `8b72838f8b449e34e519b53d9e9b8fd2021a6044`:

- [testCDC_dma3](https://github.com/krikzz/mega-ed-pub/blob/8b72838f8b449e34e519b53d9e9b8fd2021a6044/mcd-verificator/src/test_cdc_new.c#L560):
  return codes 0x01-0x21 check DSR/EDT before, during, and after main/sub host
  transfers, and prevent the wrong CPU from consuming the selected port.
- [Word writes skip data](https://github.com/krikzz/mega-ed-pub/blob/8b72838f8b449e34e519b53d9e9b8fd2021a6044/mcd-verificator/src/test_cdc_new.c#L993):
  return codes 0x60-0x63 write the first half of a transfer away, then read and
  compare its remaining half on both CPU ports.
- [testCDC_flags](https://github.com/krikzz/mega-ed-pub/blob/8b72838f8b449e34e519b53d9e9b8fd2021a6044/mcd-verificator/src/test_cdc_new.c#L1035):
  codes 0x01-0x05 preserve completed EDT across DTACK, DMA address writes, and CDC
  reset; a mode write clears it. Codes 0x11-0x12 terminate the CDC transfer and
  deselect the destination to clear DSR.
- The bundled Mega-CD Hardware Manual, PDF page 65 / printed page 58, specifies
  the main host-data register as **Word Access**. Byte accesses are outside this
  validation; no byte-level hardware behavior is inferred from these word tests.

The full verificator erases backup memory. It has not been run on this user's
device. These simulations use synthetic data and perform no device writes.

## Implementation

Only `rtl/MCD/ASIC.vhd` changes. Host writes issue the same one-shot consumption
request as reads, under the existing register DTACK qualification. A held write
therefore skips exactly one word. DMA destination selection still chooses which
CPU can consume a word.

EDT sets when the CDC has completed a host transfer while its final word remains
in the gate-array buffer. DSR stays asserted until the selected CPU consumes that
word. Automatic memory DMA retains completion after its destination handshake.
Idle DTEN alone no longer fabricates a completion event.

A separate `CDC_MODE_SET` pulse distinguishes mode writes from DMA destination
address writes. It clears EDT/DSR after the DMA state-machine assignments, so an
old completion cannot override the mode write in that cycle. DTACK and CDC reset
do not clear the gate-array EDT latch. CDC DTEI timing is unchanged.

## Reproduction and evidence

From the core repository, with GHDL on PATH:

```powershell
python tests/run_asic_cdc_host.py --baseline a3a3da81d04b22533def34f26eb9d748be9d2d0c --build-dir ../../builds/megacd-host-original-buffer14
python tests/run_asic_cdc_host.py --matrix --build-dir ../../builds/megacd-host-candidate-check
python tests/check_asic_cdc_mutants.py --build-dir ../../builds/megacd-host-mutants-check
python tests/run_asic_cdc_auto.py --matrix --build-dir ../../builds/megacd-auto-candidate-check
git -c core.whitespace=cr-at-eol diff --check
```

The baseline intentionally exits 1: twelve cases fail by their expected protocol
assertions; eight controls pass. The runner extracts unmodified RTL from the
baseline Git commit and applies the same current bench. It records source
snapshots, SHA-256 inputs, tool version, logs, and raw per-case exit codes.

| Cases | Behavior | Baseline | Candidate |
|---|---|---|---|
| 0, 1 | Ordinary main/sub reads, data, final status | Pass | Pass |
| 2, 3 | Writes skip the prefix, remaining data is intact | Fail | Pass |
| 4, 5 | EDT and DSR coexist for the last buffered word | Fail | Pass |
| 6, 7 | Wrong CPU reads/writes cannot consume words | Pass | Pass |
| 8, 9 | A held write consumes exactly one word | Fail | Pass |
| 10, 11 | Mode setup leaves EDT clear before transfer | Fail | Pass |
| 12, 13 | Mode write clears a completed EDT latch | Fail | Pass |
| 14, 15 | Termination and mode deselect clear status | Fail | Pass |
| 16, 17 | DMA destination address preserves completed EDT | Pass | Pass |
| 18, 19 | DTACK and CDC reset preserve completed EDT | Pass | Pass |

The 36 additional matrix runs repeat cases 0-5 at 32, 256, and 2352 bytes, each
from address zero and 0x3FFC. RAM data includes high address bits and applies
physical 14-bit wrapping, distinguishing a 16 KB wrap from a smaller boundary.
The test connects the complete production ASIC and CDC as in MCD.vhd, including
clock enables, decoded register strobes, DTACK, and CDC byte handshakes. Only CPU
bus masters and the registered synthetic buffer RAM are models.

The host matrix first passed with the original CDC and then with the separate
decoder patch from `fb0d2cb`. Final combined evidence is retained under
`core-lab/builds/megacd-host-buffer14-final`; original failure evidence is under
`megacd-host-original-buffer14`. Earlier matrices remain separately named.

Seven targeted mutants are rejected by specific assertions: ignored main write,
ignored sub write, late EDT, premature EDT, wrong CPU consumption, missing mode
clear, and held-write retrigger. Mutation receipts are under
`megacd-host-mutants-buffer14`; mutation sources are build artifacts, not production RTL.

The independently authored adjacent automatic-DMA bench passes 20 cases on the
baseline and 20 on the candidate, including full-sector PRG/word-RAM data,
destination addresses, exact write counts, source-buffer wrap, and varied PRG
ready delays. The combined decoder/ASIC candidate passes the same 20 cases in
`megacd-auto-combined-matrix`. Production VHDL-93 analysis also passes.

An optional PCM case stops on both baseline and candidate because the existing
`PCM_HALT_WAIT` counter lacks an initialization/reset assignment in VHDL
simulation. Those identical diagnostics remain under `megacd-auto-*-pcm`; this
is not a passing PCM gate and does not demonstrate a hardware PCM defect. The
counter was not changed or forced to make the tests pass.

## Remaining acceptance

Compile baseline/candidate with the same Quartus 25.1 settings and retain
fit/timing/RBF hashes. Then compare the same
non-destructive synthetic host/decoder test on MiSTer using separate RBF names
and disposable save storage. Preserve existing firmware, games, and configuration.
Game compatibility is established only by a reproduced failing scenario that
passes with the candidate. No remote pushes, PRs, or author contact are authorized.
