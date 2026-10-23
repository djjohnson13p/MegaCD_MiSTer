# Optional HPS UART transport smoke preparation

This isolated variant starts at CDC candidate `e50fc97f`. Production behavior
remains the default: `LAB_UART_SMOKE` is undefined, and the original combined
constant-zero UART assignment is selected. No CPU, CDC, ASIC, HPS-bus, clock,
PLL, board pin, SDC, normal Main, or UART/MIDI menu setting is changed.

An explicitly enabled build instantiates `lab_uart_smoke_tx` and drives only
the already-existing core `UART_TXD` port. RTS/DTR remain zero. There is no
RX/CTS/DSR input, flow-control backpressure, CPU state input or core output
other than TX. The module uses the existing `CLK_50M` input, wired by sys_top
to FPGA_CLK2_50; it is independent of the region-reconfigured system PLL.
The existing 50 MHz constraint remains unchanged.

At default parameters the serializer sends 9600 baud, 8 data bits LSB first,
no parity, one stop bit, idle high. Integer rounding gives 5208 input clocks
per bit, approximately 9600.6144 baud (+0.0064%). It waits two seconds after
the synchronized release of core RESET, sends four 16-byte packets with
250 ms idle gaps, and then remains idle. RESET assertion aborts an active
character; release restarts the bounded four-packet burst from sequence zero.
Thus the bound is per reset epoch, not over an arbitrarily resetting system.

The packets are:

```
55 55 55 55 4D 43 44 55 41 52 54 31 01 NN CC 0A
            M  C  D  U  A  R  T  1
NN = 00, 01, 02, 03
CC = NN XOR A4
```

Exactly 64 payload bytes are sent per uninterrupted reset epoch. The check
byte distinguishes framing/sequence mistakes; it is not a strong integrity
code. The offline parser accepts exactly one ordered four-packet burst,
rejects malformed/truncated/duplicated/reordered packets and bytes between
packets, and reports optional leading/trailing capture noise separately.
Its pure fixtures do not establish RTL behavior or hardware reception.

`tb_lab_uart_smoke.sv` is prepared with an independent bit-centre UART receiver
and golden packet vector. Cases vary divisors (including odd/one-clock),
sample phase (40/50/60%), packet counts, startup/gaps, and a mid-character
reset. It checks the full stop cell, startup/gap timing, sequence restart and
absence of any later transmission. These simulations have not been run.
The preparation plan under the lab build directory binds exact sources and
tools; no compiler or model is started by preparation.

The actual route is core UART_TXD -> sys_top uart_rxd -> the Cyclone V HPS
peripheral UART RX input. The primitive has no UART-index parameter. Official
MiSTer DE10-Nano u-boot source at `8dcc3484` sets UART0USEFPGA=0 and
UART1USEFPGA=1 in its pinmux table, which system_manager.c writes during
initialization. Installed device-tree aliases map serial1 to ffc03000 and
serial0 to ffc02000; both nodes are enabled. This identifies the intended
UART1/ttyS1 path but does not prove the live mux-register value or reception.
No bootloader image provenance or live register read is claimed.

The installed `/usr/sbin/uartmode` helper was read as data. It manages ttyS1
services; it does not configure the HPS pinmux. It can kill existing ttyS1
users, so it must not be invoked merely to prepare a debug receiver. Main
calls it during core initialization. No UART/MIDI configuration entry is
added by this variant. A future receive experiment must account for existing
services, raw 9600 8N1 settings, CLOCAL/carrier and hardware-flow-control
settings, and the receiver's lifetime around core loading; this preparation
does not open or configure the TTY, start/stop services or change control.

A real bounded, provenance-bound receiver capture is required before
investing in the full diagnostic ring. Simulation cannot prove the HPS route,
kernel configuration, service exclusivity or hardware UART reception.
