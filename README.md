# Cheshire + Ara on the ZCU102

This repository runs the [CVA6](https://github.com/openhwgroup/cva6) RISC-V core
with the [Ara](https://github.com/pulp-platform/ara) vector unit (RVV 1.0) on a
Xilinx **ZCU102**. It builds on [Cheshire](https://github.com/pulp-platform/cheshire).
CVA6 + Ara run bare-metal programs out of the PS DDR. The ARM processing
system (PS) loads the programs, starts them and reads their output.

Everything you need is in this one repository: the SoC, the patched Ara/CVA6/AXI/iDMA
RTL, the build knobs, the bare-metal apps and the scripts that drive the board.

**Contents**

1. [What is in this repository](#1-what-is-in-this-repository)
2. [Requirements](#2-requirements)
3. [Getting the sources](#3-getting-the-sources)
4. [Building a bitstream](#4-building-a-bitstream)
5. [Building many bitstreams: sweep scripts](#5-building-many-bitstreams-sweep-scripts)
6. [The apps](#6-the-apps)
7. [Building the apps](#7-building-the-apps)
8. [Working with the ZCU102](#8-working-with-the-zcu102)
9. [Running a program, step by step](#9-running-a-program-step-by-step)
10. [Reading the output](#10-reading-the-output)
11. [Unattended runs over many bitstreams](#11-unattended-runs-over-many-bitstreams)
12. [Troubleshooting](#12-troubleshooting)
13. [Known hardware issues](#13-known-hardware-issues)
14. [Upstream Cheshire](#14-upstream-cheshire)

---

## 1. What is in this repository

| Path | Contents |
|---|---|
| `hw/` | Cheshire SoC (`cheshire_soc.sv`, package, registers, bootrom) |
| `target/xilinx/` | ZCU102 top level, DRAM/PS wrapper, constraints, Vivado scripts |
| `deps/ara/hardware/` | the Ara RTL that is built (patched, see below) |
| `deps/ara/cheshire/` | **the build entry point**: knob Makefile and bitstream sweep scripts |
| `deps/ara/apps/` | bare-metal apps (upstream Ara benchmarks + the custom apps in [section 6](#6-the-apps)) |
| `deps/ara/config/` | lane/VLEN configurations for the apps |
| `cva6_patched/`, `axi_patched/`, `idma_patched/` | patched CVA6, AXI and iDMA |
| `tools/zcu102/` | JTAG programming script, SD-card helper scripts, DDR loader, `uEnv.txt`, sweep runner |

### SoC configuration

- CVA6 has scalar FP32 + FP16 but **no FP64** (RVD=0, FLEN=32), and no atomics or
  debug module by default.
- Ara has 2 or 4 lanes, VLEN 256–8192, and an FP16-only vector FPU by default
  (FP32 or both can be selected).
- The LLC is 1 MiB by default. Its ways can be split at run time between cache
  and scratchpad (SPM).
- An iDMA is attached with a 2-D frontend.
- SoC clock is 50 MHz. The SoC AXI width is `max(32 × lanes, 64)` bits: 64 bit for
  2 lanes, 128 bit for 4 lanes.
- Main memory is the PS DDR, reached through the HP0 port.

### Where the hardware comes from

`Bender.yml` still lists the upstream git dependencies, but `Bender.lock`
redirects four of them to the patched copies in this repository:

| Dependency | Built from | What is patched |
|---|---|---|
| `ara`  | `deps/ara/` | FLEN-aware scalar NaN-boxing in the dispatcher, optional ILA probes in the sequencer, ZCU102 build knobs |
| `cva6` | `cva6_patched/` | RVD=0 / FP16 configuration, FPR write-port fix, optional ILA probes |
| `axi`  | `axi_patched/` | `axi_dw_upsizer`: several outstanding reads per AXI ID (see `axi_patched/PATCH_NOTES.md`) |
| `idma` | `idma_patched/` | 128-bit slave port with width converter |

> **Do not run `bender update`.** It re-resolves the dependencies from
> `Bender.yml` and drops these redirects, and the upstream Ara branch does not
> work on this SoC. To check what a build used, look at the generated
> `target/xilinx/scripts/add_sources.zcu102.tcl`: every Ara path must start with
> `$ROOT/deps/ara/`.

---

## 2. Requirements

| What | Version used | Needed for |
|---|---|---|
| Vivado (full, with a licence for `xczu9eg`) | 2021.1 | synthesis / implementation |
| Vivado Lab (or full Vivado) | 2021.1 | programming over JTAG |
| [bender](https://github.com/pulp-platform/bender) | 0.31.0 | resolving the hardware sources |
| Python 3 + `pip install -r requirements.txt` | 3.6+ | register / IP generators run by the build |
| RISC-V LLVM toolchain ([section 7](#7-building-the-apps)) | built from `deps/ara/toolchain` | building the apps |
| `aarch64-linux-gnu-gcc` | any | building the DDR loader once |
| `screen`, `pyserial` | any | the board console and unattended runs |
| ZCU102 board, an FTDI JTAG cable, an SD card | | running |

All archived bitstreams were built with Vivado 2021.1. A build takes 1.5–3 h on a
40-core machine with 192 GB RAM. Most of the variation comes from the lane count.

---

## 3. Getting the sources

```bash
git clone https://github.com/StavrosMitro/cheshire_ara.git
cd cheshire_ara
bender checkout                 # all other hardware dependencies, into .bender/
```

That is enough for a bitstream. The repository also has submodules, which are
only needed for some tasks. Do **not** use `--recurse-submodules`, because it
fetches several GB that a bitstream build never touches:

| Submodule | Needed for |
|---|---|
| `deps/ara/toolchain/riscv-llvm`, `deps/ara/toolchain/newlib` | building the LLVM toolchain for the apps |
| `deps/ara/toolchain/riscv-isa-sim` | Spike, to simulate apps |
| `deps/ara/toolchain/riscv-gnu-toolchain`, `deps/ara/toolchain/verilator` | GCC toolchain / RTL simulation of Ara |
| `sw/deps/printf` | fetched automatically by the build |
| `sw/deps/cva6-sdk`, `deps/ara/cheshire/sw/cva6-sdk` | Linux on CVA6 (not used here) |

---

## 4. Building a bitstream

All builds go through the Makefile in `deps/ara/cheshire/`. It regenerates the
source list with the selected defines and then calls Cheshire's Xilinx flow.

```bash
cd deps/ara/cheshire
make ara-chs-xilinx BOARD=zcu102 MODE=batch VIVADO="vivado" \
     nr_lanes=4 vlen=2048 llc=1024 fpu=16
```

- `VIVADO` is the command that starts Vivado 2021.1 on your machine. Always set
  it, because `target/xilinx/xilinx.mk` defaults to a site-specific wrapper.
- Output: `target/xilinx/out/cheshire.zcu102.bit`, plus `cheshire.zcu102.ltx` when
  ILA probes are enabled. Reports are in
  `target/xilinx/build/zcu102.cheshire/reports.impl/`.
- The next build **overwrites** both. Copy them away, or use the sweep scripts
  ([section 5](#5-building-many-bitstreams-sweep-scripts)), which archive every
  build under a unique name.

### Build knobs

| Knob | Default | Meaning |
|---|---|---|
| `nr_lanes` | from `ARA_CONFIGURATION` | Ara lanes (2 or 4 were used). The AXI width follows from it |
| `vlen` | from `ARA_CONFIGURATION` | vector register length in bits |
| `llc` | `1024` | LLC size in KiB, shared by the cache and SPM ways |
| `fpu` | `16` | Ara vector FPU: `16` = FP16 only, `32` = FP32 only, `1632` = both |
| `atomics` | `0` | `1` adds the RISC-V atomics shims (~13k LUT). Needed only for Linux on CVA6 |
| `dbg` | `0` | `1` adds the RISC-V debug module and JTAG TAP (~11k LUT) |
| `probes` | *(empty)* | ILA probe groups, comma-separated: `mem` (AXI memory path), `vec` (CVA6↔Ara and the Ara sequencer), `ddr` (DRAM CDC input). Empty = no ILA |
| `soc_mhz` | `50` | SoC clock (CVA6, Ara, LLC). Must divide 1200. Timing closes at 50 MHz; 75 MHz closed only for L2/VLEN 1024 |
| `hp0_mhz` | *(= soc)* | PS HP0 port / DRAM-side clock. Must divide 1200, max 300 |

An ILA costs about 8–10k LUTs. Compare area and timing only between builds with
the same `probes` setting.

Reference numbers (50 MHz, no probes, FP16):

| Config | LUT | RAMB36 | WNS |
|---|---|---|---|
| 2 lanes, VLEN 1024, LLC 1 MiB | ~142k (52 %) | 336 | +3.2 ns |
| 4 lanes, VLEN 2048, LLC 1 MiB | ~228k (83 %) | 360 | +2.1 ns |

---

## 5. Building many bitstreams: sweep scripts

These scripts live in `deps/ara/cheshire/`. Each one builds its configurations
one after the other. After every build it copies the `.bit`, `.ltx`, timing and
utilization reports and the generated source list to `bitstream_archive/`, under
a name like this:

```
cheshire_top_xilinx_L4_V2048_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_<date>.bit
```

It also appends one row to a summary table (`*_SWEEP_SUMMARY.txt`). Configurations
that are already archived are skipped, so running the same command again resumes
an interrupted sweep.

| Script | Builds |
|---|---|
| `build_arch_sweep.sh` | lanes × VLEN × LLC grid (2/4 lanes, VLEN 256–8192, LLC 1/2 MiB) |
| `build_probe_sweep.sh` | the same geometry with ILA probes (`probes=…`), and archives the `.ltx` |
| `build_clock_sweep.sh` | one geometry at different `soc_mhz` / `hp0_mhz` |

```bash
cd deps/ara/cheshire
./build_arch_sweep.sh --list                    # configurations + what is archived
./build_arch_sweep.sh L4_V2048_1M               # build one
VIVADO="vivado" nohup ./build_arch_sweep.sh &   # build everything still missing
```

Options are documented at the top of each script: `FORCE=1`, `ARCHIVE=<dir>`,
`LLC=<KiB>`, `FPU=<16|32|1632>`, `RTLTAG=<tag>`.

---

## 6. The apps

The apps live in `deps/ara/apps/`. Besides the upstream Ara benchmarks
(`fmatmul`, `fconv2d`, `fft`, …) there are the custom apps below.

**Targets:**
- `bin/<app>.fpga16` is the FPGA build **without FP64**
  (`rv64imac_zve64f_zvfh`, ABI `lp64`). It is the right target for every app that
  runs on these bitstreams, FP16 and FP32 alike. Despite the name, the "16" does
  not mean FP16 only ([section 7](#fp16-vs-fp32-what-differs)).
- `bin/<app>.spike` runs in Spike and serves as the reference.
- `bin/<app>.fpga` is the upstream FPGA build (`rv64gcv`, `lp64d`). It contains
  FP64 instructions and does **not** work on these bitstreams.

Every FPGA target also produces `bin/<app>.<target>.bin`, the flat binary that
goes on the SD card.

**Apps marked †** must be built with `ENV_DEFINES="-DNO_BOOT_LLC_FLUSH=1"`,
otherwise they hang before `main()`. The flag skips the boot-time LLC flush in
`crt0`. Results still reach DDR through the flush at exit, but you must reprogram
the FPGA before every run.

### Neural-network workloads

All of them train for one step: forward pass, loss, backward pass and weight
update. They print the loss and a per-stage cycle breakdown.

| App | Precision | Bitstream | What it does |
|---|---|---|---|
| `fc_layer16only` | FP16 | `fpu=16` / `1632` | AlexNet fully-connected layers (default 1536→192, batch 4). The main FC benchmark |
| `conv_layer16only` | FP16 | `fpu=16` / `1632` | AlexNet 3×3 convolution layer (default 12→12 channels, 32×32, batch 4) |
| `vggnet16` | FP16 | `fpu=16` / `1632` | MiniVGGNet, fine-tuning on a CIFAR-100 subset. `VGGNET16_*` variables in the Makefile set batch, steps, variant and augmentation |
| `fc_layer32` | FP32 | `fpu=32` / `1632` | the FC layers in FP32 |
| `conv_layer32` | FP32 | `fpu=32` / `1632` | the convolution layer in FP32 |
| `vggnet` | FP32 | `fpu=32` / `1632` | MiniVGGNet in FP32 |
| `fc_layer`, `conv_layer` | FP16 data, FP32 accumulation | Spike | mixed-precision versions of the layers |
| `fc_layer_test` | both | Spike | equivalence suite: the mixed-precision FC kernels against the FP32 ones, kernel by kernel and end to end |

All of them build as `.fpga16`. The FP32 apps build and contain no FP64
instructions, but they have **not yet been run on the board**. They have been
validated in Spike only.

Layer sizes, batch, epochs, learning rate and seed are Makefile variables
(`FC_LAYER16ONLY_*`, `CONV_LAYER16ONLY_*`, …). Test vectors are generated by each
app's `script/` and regenerated automatically when a parameter changes.

### Memory latency and ILA measurements

| App | What it measures |
|---|---|
| `memlat` | latency of a vector load: LLC→VRF, DDR→VRF, and the difference |
| `memmatrix` † | latency matrix: hit/miss × unit/strided × access size × element width |
| `latprobe` † | one access pattern in a long loop, for ILA captures on the `probes=mem` points. `-DLAT_CASE=<n>` |
| `sldprobe` | one vector load or one `vfslide1down` in a long loop, for `probes=vec` captures. `sldprobe/build_variants.sh` builds every case × LMUL |

All four build as `.fpga16`.

### Kernel comparisons (correctness + cycles)

| App | Target | What it compares |
|---|---|---|
| `fconv_cmp` | `.fpga16` | dataflow variants of the FP16 3×3×C convolution kernel against the reference kernel and a scalar oracle |
| `fmatmul_cmp` | `.spike` | the two FP32 matmul strategies of `fc_layer32` (`vfmacc.vf` vs `vfmacc.vv` with deferred reduction) |
| `pluto_conv_stream` | `.spike` | a convolution hand-vectorised from Pluto output against three other implementations |
| `fmatmul-loop`, `fmatmul_no_print` | `.spike` | `fmatmul` variants: repeated loop, no console output |
| `vfleak` | Verilator | reproducer for a `.vf` instruction-queue leak seen on the FPGA |
| `rivec-bmarks` | | RiVEC benchmark suite |

---

## 7. Building the apps

```bash
cd deps/ara/apps
make bin/fc_layer16only.fpga16   ARA_CONFIGURATION=zcu102_l4_v2048
make bin/conv_layer16only.fpga16 ARA_CONFIGURATION=zcu102_l4_v2048
make bin/vggnet16.fpga16         ARA_CONFIGURATION=zcu102_l4_v2048
make bin/fc_layer32.fpga16       ARA_CONFIGURATION=zcu102_l4_v2048   # FP32: needs an fpu=32/1632 bitstream
make bin/memmatrix.fpga16        ARA_CONFIGURATION=zcu102_l4_v2048 ENV_DEFINES="-DNO_BOOT_LLC_FLUSH=1"
#  -> bin/<app>.fpga16.bin   (copy this to the SD card)
```

- `ARA_CONFIGURATION=zcu102_l4_v2048` (`deps/ara/config/zcu102_l4_v2048.mk`)
  describes the 4-lane / VLEN 2048 bitstream. The kernels choose the vector
  length at run time with `vsetvli`, so the same binary also runs on other VLEN
  bitstreams. Exception: VLEN-2048 binaries hang on VLEN-1024 bitstreams, so build
  those with a matching configuration. FP16 reductions can give slightly
  different results across VLENs, because their order depends on VLMAX.
- Binaries are linked at `0x4000_0000` (`common/link.fpga.ld`). That is where the
  loader puts them in DDR.
- When you change only `-D` defines, delete the app's `*.o.fpga16` files before
  rebuilding, so that no stale objects are linked.
- Simulate first: `make spike-run-<app> ARA_CONFIGURATION=zcu102_l4_v2048` gives
  the reference output to compare against the board.
- To add an app to the FPGA build, put it in `FP16ONLY_APPS` in `apps/Makefile`. If
  its `data.S` uses `.incbin`, also add a
  `bin/<app>.fpga16: RISCV_CCFLAGS_FPGA16 += -Wa,-I$(CURDIR)/<app>` line next to the
  existing ones.

### FP16 vs FP32: what differs

What the hardware supports:

| | Scalar (CVA6) | Vector (Ara) |
|---|---|---|
| FP16 | yes (`Zfh`), every bitstream | only on `fpu=16` and `fpu=1632` bitstreams |
| FP32 | yes (`F`), every bitstream | only on `fpu=32` and `fpu=1632` bitstreams |
| FP64 | **no** (RVD=0) | **no** |

So **FP16 and FP32 code use exactly the same compiler settings.** The difference is
the bitstream you run on:

- Compared with the upstream build, the only change is dropping FP64. Both
  precisions must be compiled **without** it: `-march=rv64imac_zve64f_zvfh -mabi=lp64`. `double` arithmetic,
  including what `printf("%f")` does internally, then becomes software calls
  (`__adddf3`, `__muldf3`, …) into compiler-rt.
- Vector FP code compiled this way runs only if the bitstream's vector FPU supports
  that width. An FP32 kernel (`vsetvli … e32` + `vf*`) fails on an `fpu=16`
  bitstream, and an FP16 kernel fails on an `fpu=32` one.
- The libraries must also be free of FP64 and use the same ABI. The default newlib
  and compiler-rt of `make toolchain-llvm` are built for `rv64gc` / `lp64d`. They
  contain real FP64 instructions, and `ld.lld` links them **without any error**
  into an `lp64` program. The `.fpga16` target therefore links against
  dedicated `lp64` libraries:

| Library | Built for | Location | Built by |
|---|---|---|---|
| compiler-rt builtins | `rv64imac_zve64f_zvfh`, `lp64` | `deps/ara/install/riscv-llvm-fp16only-rt/resource-dir` (passed as `-resource-dir`) | `make -C deps/ara toolchain-llvm-rt-fpga16` |
| newlib (libc, libm, libgloss) | `rv64imac`, `lp64` | `deps/ara/install/riscv-llvm/riscv64-unknown-elf/lib/rv64imac/lp64/` (passed with `-L` and as an explicit `libm.a` path) | `make -C deps/ara toolchain-llvm-newlib-lp64` |

`apps/common/runtime.mk` (`*_FPGA16` variables) holds the exact flags and explains
each one. Two details matter if you write your own flags:

- `-march` is **not** "last one wins" like `-mabi`. Appending a second `-march` to
  flags that already enable `D` merges the features and leaves `D` on. The
  `.fpga16` flags are therefore a separate chain and do not extend the upstream
  `.fpga` flags.
- `Zvfh` requires `Zve32f`, which requires scalar `F`. So the compiler always
  emits hardware FP32 for scalar `float` code. That is correct here, because
  CVA6 has `F`.

The build also runs a guard that rejects `fcvt.s.l` / `fcvt.s.lu` / `fcvt.l.s` /
`fcvt.lu.s` (int64 ↔ f32 conversions), which are broken in the current FPU
([section 13](#13-known-hardware-issues)). Convert through `int32_t` instead.

### Building the toolchain

```bash
git submodule update --init deps/ara/toolchain/riscv-llvm deps/ara/toolchain/newlib
make -C deps/ara toolchain-llvm          # clang/lld + default newlib + compiler-rt
make -C deps/ara toolchain-llvm-nofp64   # the two lp64 libraries above (needed for .fpga16)
git submodule update --init deps/ara/toolchain/riscv-isa-sim
make -C deps/ara riscv-isa-sim           # Spike (optional)
```

To use an existing install instead, pass `INSTALL_DIR=…` or `LLVM_INSTALL_DIR=…`
to `make`. The library locations can be overridden with `NEWLIB_LP64_DIR=…` and
`RT_FPGA16_DIR=…` when building them, and with `RISCV_RESOURCE_DIR_FPGA16=…` when
building apps.

---

## 8. Working with the ZCU102

### How it fits together

```
  host PC ──USB──┬── JTAG cable (FTDI FT232H, 0403:6014) → programs the PL with the .bit
                 └── CP2108 (10c4:ea71, on the board)    → UART → shell on the PS (ARM Linux)

  ZCU102:  PS (ARM, Linux from the SD card) ── HP0 AXI ── PL (Cheshire: CVA6 + Ara + LLC)
                         └────────── shared PS DDR ──────────┘
```

- You get **one shell**: Linux on the PS, over the CP2108 serial console, in `screen`.
- The **CVA6/Ara program is bare-metal** and has no UART. It writes its `printf`
  output into a **mailbox in the shared DDR**, and the PS reads it with `devmem`.
- PS Linux is limited to the first 1 GiB of DDR (`mem=1024M` in `uEnv.txt`).
  The program is loaded at `0x4000_0000`, which is above that.
- PS GPIO **`gpio412`** drives the CVA6 **reset**: `1` = held in reset, `0` = running.
- **Reprogram the FPGA before every run.** This resets the LLC. Small-LLC builds
  in particular can hang on LLC/DDR state left over from the previous run.
- Binaries reach the board on the **SD card**, which you move between the board's
  slot and a card reader on the host. The board mounts it at `/mnt/sd`
  (`/dev/mmcblk0p1`).

### The helper scripts (`tools/zcu102/`)

| File | Runs on | Purpose |
|---|---|---|
| `program.tcl` | host | programs the PL over JTAG: `vivado_lab -mode batch -source program.tcl -tclargs <bit>` |
| `load.c` → `load` | board | writes a flat `.bin` into DDR at `0x40000000` through `/dev/mem` and checks the first and last word |
| `k4_app_prep.sh <bin>` | board | puts CVA6 in reset, clears the mailbox, sets the sentinel, loads `<bin>` and **leaves the core in reset** |
| `k4_app_poll.sh <secs>` | board | releases reset and polls the sentinel until the program exits or the timeout expires |
| `k4_console.sh` | board | prints the program's console buffer as text |
| `uEnv.txt` | SD card | kernel bootargs: `mem=1024M` keeps Linux out of the upper DDR |
| `sweep_layers_over_bitstreams.py` | host | unattended runs over many bitstreams ([section 11](#11-unattended-runs-over-many-bitstreams)) |

### Mailbox addresses (read/write from the PS shell with `devmem`)

| Address | Meaning | Values |
|---|---|---|
| `0x5FFFF010` | **sentinel / exit code** | `0xDEADDEAD` = staged or still running · `0x00000000` = pass · `0x0000000N` = N failed checks (tests) or exit code N (apps) |
| `0x50000004` | console byte count | valid bytes in the buffer below |
| `0x50002000` | console text buffer | the program's `printf` output, little-endian words |
| `0x50000050` | **trap flag** | `0x7A7A7A7A` = the core trapped. Any other value = no trap |
| `0x50000040` | `mcause` | meaningful only if the trap flag is set |
| `0x50000048` | `mepc` | 〃 |
| `0x5000004C` | `mtval` | for an illegal instruction (`mcause=2`), the instruction word |
| `0x50000070`–`0x50000094` | scratch markers | app-specific progress markers |

> A trap is real **only** when `0x50000050` reads `0x7A7A7A7A`. Otherwise
> `mcause/mepc/mtval` contain whatever was in DDR before.

### One-time SD card setup

Make a FAT32 partition with these files:

| File | Where from |
|---|---|
| `BOOT.BIN`, `boot.scr`, `image.ub` | Xilinx PetaLinux **2021.1** pre-built images for the ZCU102 (ZCU102 BSP, `pre-built/linux/images/`) |
| `uEnv.txt` | `tools/zcu102/uEnv.txt` |
| `load` | `aarch64-linux-gnu-gcc -O2 -static -o load tools/zcu102/load.c` |
| `k4_app_prep.sh`, `k4_app_poll.sh`, `k4_console.sh` | `tools/zcu102/` |
| your `*.fpga16.bin` files | `deps/ara/apps/bin/` |

Set the boot-mode switches (SW6) to SD boot and power on. JTAG programming
replaces the PL bitstream that is in `BOOT.BIN`, so it does not matter which one
is there.

### Connecting the console

The CP2108 exposes **4** tty nodes, and their numbering is **not stable**. After a
reboot or a USB reseat the block can shift (`ttyUSB0-3` ↔ `ttyUSB1-4`), and the
JTAG cable sometimes takes `ttyUSB0`. Check which node is which:

```bash
lsusb | grep -iE '10c4:ea71|0403:6014'          # 10c4:ea71 = console, 0403:6014 = JTAG
for n in /dev/ttyUSB*; do
  p=$(readlink -f "/sys/class/tty/$(basename $n)/device")
  while [ -n "$p" ] && [ ! -e "$p/idVendor" ]; do p=$(dirname "$p"); done
  echo "$n -> $(cat $p/idVendor):$(cat $p/idProduct)"
done
```

Use the **lowest-numbered `10c4` node**:

```bash
screen -dmS board /dev/ttyUSB1 115200      # <-- the node found above
screen -r board                            # attach; Ctrl-A d to detach
```

Press Enter: you should get the PS shell prompt.

- Do not start the console with `sudo screen`. A root-owned `screen` keeps the
  port busy, and your user cannot see it with `fuser`/`lsof`. Add yourself to the
  `dialout` group instead.
- If the CP2108 is missing from `lsusb`, reseat its USB cable. Moving the SD card
  often knocks it off.

### Checking the reset line (before every run)

In the board shell:

```sh
cat /sys/class/gpio/gpio412/direction     # MUST print: out
cat /sys/class/gpio/gpio412/value

# if gpio412 is missing or its direction is "in":
echo 412 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio412/direction
echo 1   > /sys/class/gpio/gpio412/value   # hold CVA6 in reset
```

If `direction` is `in`, `echo 0 > value` silently does nothing, and **every run
looks like a hang** with all-zero results.

### Programming the FPGA (before every run)

On the host:

```bash
vivado_lab -mode batch -nojournal -nolog \
    -source tools/zcu102/program.tcl -tclargs /path/to/cheshire.zcu102.bit
```

It takes 1–2 minutes. It worked if the log shows **`End of startup status: HIGH`**
and `PROGRAM_DONE`. A second argument selects a remote `hw_server`
(default `localhost:3121`).

---

## 9. Running a program, step by step

**1. Copy the binary to the SD card** (host, card in the reader):

```bash
cp deps/ara/apps/bin/mytest.fpga16.bin /media/$USER/BOOT/
md5sum /media/$USER/BOOT/mytest.fpga16.bin
sync && umount /media/$USER/BOOT
```

Move the card into the board's slot.

**2. Program the FPGA** (host): see [above](#programming-the-fpga-before-every-run).

**3. Stage the binary** (board shell):

```sh
cat /sys/class/gpio/gpio412/direction            # out
umount -l /mnt/sd 2>/dev/null
mkdir -p /mnt/sd && mount -t vfat /dev/mmcblk0p1 /mnt/sd
md5sum /mnt/sd/mytest.fpga16.bin                 # must match the host md5

sh /mnt/sd/k4_app_prep.sh /mnt/sd/mytest.fpga16.bin
```

Expected output:

```
LOAD_EXIT=0 LOAD_OUTPUT_LINES=...
STAGED, board HELD IN RESET
K4_APP_PREP_DONE
```

If you see `FATAL: LOAD FAILED` instead, the DDR write did not verify. Stop here.

**4. Run** (board shell):

```sh
sh /mnt/sd/k4_app_poll.sh 120        # release reset, wait up to 120 s
```

```
DONE after 7s, exit code = 0x00000000     <- 0x0 = pass; 0xN = N failures / exit code N
POLL_DONE final=0x00000000
```

Typical run times: tests ~15 s, `fc_layer16only` / `conv_layer16only` ~30 s,
`vggnet16` 60–120 s.

**5. Check the result registers and read the output:**

```sh
echo "sentinel : $(devmem 0x5FFFF010)"
echo "bytes    : $(devmem 0x50000004)"
echo "trap flag: $(devmem 0x50000050)"      # 0x7A7A7A7A = trapped
echo "mcause   : $(devmem 0x50000040)"
echo "mepc     : $(devmem 0x50000048)"
echo "mtval    : $(devmem 0x5000004C)"
sh /mnt/sd/k4_console.sh                     # the program's printf output
```

**6. Finish:**

```sh
echo 1 > /sys/class/gpio/gpio412/value      # hold CVA6 in reset
sync && umount /mnt/sd
```

Unmount the card before you pull it, on both sides. A card pulled while mounted
can corrupt the FAT, and the board then falls into a U-Boot PXE loop on the next
boot.

---

## 10. Reading the output

> **Important:** the console buffer, the markers and the sentinel all live in a
> cached region. CVA6 writes them to the LLC, and they reach DDR only when the
> program flushes the LLC at exit. A program that hangs therefore usually shows
> `bytes=0`, however far it got. "Nothing printed" does not prove "nothing ran".
> To get evidence out of a run that may hang, write a marker and flush the LLC
> after each step.

### Option A: as text, on the board

```sh
sh /mnt/sd/k4_console.sh
```

It decodes the buffer word by word. The output is slow, because the serial
console is slow, but verbatim. To keep a copy on the host, turn on `screen`
logging first:

```bash
screen -S board -X logfile /tmp/board.log
screen -S board -X log on
#   ... run k4_console.sh in the session ...
screen -S board -X log off
```

### Option B: raw words on the board, decoded on the host

Board:

```sh
n=$(( $(devmem 0x50000004) )); i=0
while [ $i -lt $n ]; do devmem $(printf '0x%X' $((0x50002000 + i))); i=$((i+4)); done
```

Host, on the captured screen log:

```bash
python3 - <<'EOF'
import re, struct
seg = open('/tmp/board.log').read()
w = [int(m, 16) for m in re.findall(r'^0x([0-9A-Fa-f]{8})\s*$', seg, re.M)]
print(b''.join(struct.pack('<I', x) for x in w).decode('ascii', errors='replace'))
EOF
```

### Option C: drive everything from the host

`screen -X stuff` types into the session. It **eats `$`**, so send only literal
command lines and expand variables on the host. Wait about 1.1 s per line.

```bash
NB=$(printf '0x%X' 1600)     # <- the real byte count from devmem 0x50000004
python3 -c "
base, n = 0x50002000, $NB
nw = (n + 3)//4
for c in range(0, nw, 8):
    print('; '.join(f'devmem {hex(base+(c+k)*4)}' for k in range(8) if c+k < nw))
" > /tmp/dump.txt

: > /tmp/board.log
screen -S board -X logfile /tmp/board.log ; screen -S board -X log on ; sleep 0.5
screen -S board -X stuff "echo DUMP_START$(printf '\r')" ; sleep 0.5
while IFS= read -r L; do screen -S board -X stuff "$L$(printf '\r')"; sleep 1.1; done < /tmp/dump.txt
sleep 2 ; screen -S board -X stuff "echo DUMP_END$(printf '\r')" ; sleep 2
screen -S board -X log off

python3 -c "
import re, struct
seg = open('/tmp/board.log').read().split('DUMP_START',1)[1].split('DUMP_END',1)[0]
w = [int(m,16) for m in re.findall(r'^0x([0-9A-Fa-f]{8})\s*\$', seg, re.M)]
print(b''.join(struct.pack('<I', x) for x in w)[:$NB].decode('ascii', errors='replace'))
"
```

To see what is on the board's screen without attaching:

```bash
screen -S board -X hardcopy /tmp/cap.txt ; tail -20 /tmp/cap.txt
```

### Interpreting cycle counts

Results (loss, PASS/FAIL) are deterministic. Cycle counts vary by about 0.5 %
between runs on the same bitstream, so report the median of 3 runs.

---

## 11. Unattended runs over many bitstreams

`tools/zcu102/sweep_layers_over_bitstreams.py` automates sections 8–10. For each
bitstream it programs the FPGA, then drives the board shell over pyserial. The SD
helper scripts and the binaries must already be on the card. It runs
`fc_layer16only` / `conv_layer16only` N times and writes the loss and every cycle
field to CSV (`runs.csv`, `cycles_long.csv`, plus raw console captures). If
interrupted, running it again resumes where it stopped. When the board needs a
power-cycle, it stops and says so.

```bash
pip install pyserial
export BIT_DIR=~/bitstreams                              # where the .bit files are
export VIVADO_LAB=/tools/Xilinx/Vivado_Lab/2021.1/bin/vivado_lab
export APPS_BIN_DIR=$PWD/deps/ara/apps/bin               # md5-checks the SD copies
tools/zcu102/sweep_layers_over_bitstreams.py --list
tools/zcu102/sweep_layers_over_bitstreams.py --preflight              # one program + harness
tools/zcu102/sweep_layers_over_bitstreams.py --bitstreams "$BIT_DIR/*.bit" --repeats 3
```

The default bitstream globs, binary names and timeouts are at the top of the
script.

---

## 12. Troubleshooting

### "It hung": confirm it first

An all-zero result (`sentinel=0xDEADDEAD`, `bytes=0`, no trap) is usually a setup
problem:

1. Is the `gpio412` direction `out`?
2. Did programming succeed (`End of startup status: HIGH`)?
3. Run a known-good binary (e.g. `fc_layer16only`) on the same freshly programmed
   bitstream. If that one passes and yours does not, the hang is in your program.

Once a run has really hung, reprogramming does **not** always bring CVA6 back. If
even the known-good binary then hangs, **power-cycle the ZCU102**.

### Pitfalls

| Symptom | Cause / fix |
|---|---|
| every run all-zero, "hang" | `gpio412` came back as `in` after re-export: `echo out > .../direction` |
| `vivado_lab`: "No matching targets" | JTAG cable dropped: reseat it, check `lsusb \| grep 0403:6014` |
| `vivado_lab`: "Cannot start server on port 3121" | kill the stale `hw_server`, retry |
| `screen` attaches to nothing | wrong `ttyUSB` node: map them again |
| serial port busy (EBUSY) | a leftover root `screen` holds it: `sudo pkill -f 'SCREEN /dev/ttyUSB'` |
| CP2108 gone after moving the SD card | reseat the CP2108 USB cable |
| `/mnt/sd`: "Directory bread failed" | `umount -l /mnt/sd`, then mount again |
| board stuck in a U-Boot PXE loop | SD was pulled while mounted: power-cycle |
| `dd`/`hexdump` on `/dev/mem` → "Bad address" | that window only works through `mmap` (`devmem`, `load`) |
| `mcause/mepc/mtval` look like a trap | not a trap unless `0x50000050 == 0x7A7A7A7A` |
| test hangs before printing anything | built without `ENV_DEFINES="-DNO_BOOT_LLC_FLUSH=1"` (apps marked † in [section 6](#6-the-apps)) |
| loss is a huge number instead of `nan` | `-ffast-math` removes NaN checks, so "a number" does not prove "finite" |
| binary traps with `mcause=2` on an FP instruction | it contains FP64 code. Build the `.fpga16` target with the `lp64` libraries ([section 7](#toolchain)) |

---

## 13. Known hardware issues

None of these affect `fc_layer16only`, `conv_layer16only` or `vggnet16`, which do not
use the instructions involved.

- **`fcvt.s.l` / `fcvt.s.lu` (int64 → f32) return a constant.** This comes from the
  FPU configuration with RVD=0. The app build rejects binaries that contain them.
- **Ara mask unit** (upstream RTL, reproduced both in RTL simulation and on the
  FPGA):
  - `vid.v` leaves a stale ALU payload, which the **next** mask comparison
    consumes instead of its own operand.
  - `vcompress` never terminates when the last active mask bit is 0, including an
    all-zero mask (upstream issue #450).
  - `vcpop.m` / `vfirst.m` count tail bits of the last 16-bit slice.
  - `vlm.v` is decoded with the generic EMUL instead of EMUL=1, so it traps at
    LMUL > 1.

---

## 14. Upstream Cheshire

Cheshire is a minimal Linux-capable host platform built around the RISC-V
[CVA6](https://github.com/openhwgroup/cva6) core. It is developed as part of the
PULP project, a joint effort between ETH Zurich and the University of Bologna.
Upstream documentation: [Getting Started](https://pulp-platform.github.io/cheshire/gs/),
[Targets](https://pulp-platform.github.io/cheshire/tg),
[User Manual](https://pulp-platform.github.io/cheshire/um/).

### License

Unless specified otherwise in the respective file headers, all code checked into this repository is made available under a permissive license. All hardware sources and tool scripts are licensed under the Solderpad Hardware License 0.51 (see `LICENSE`) or compatible licenses. Register file code (e.g. `hw/regs/*.sv`) is generated by a fork of lowRISC's [`regtool`](https://github.com/lowRISC/opentitan/blob/master/util/regtool.py) and licensed under Apache 2.0. The USB OHCI controller (`hw/future/UsbOhciAxi4.v`) is generated from the [SpinalHDL](https://github.com/SpinalHDL/SpinalHDL) library licensed under the MIT license. All software sources are licensed under Apache 2.0. Ara and CVA6 keep their own licenses (see `deps/ara/LICENSE` and `cva6_patched/LICENSE`).

### Publication

If you use Cheshire in your work, you can cite:

```
@article{ottaviano2023cheshire,
      title   = {Cheshire: A Lightweight, Linux-Capable RISC-V Host
                 Platform for Domain-Specific Accelerator Plug-In},
      author  = {Alessandro Ottaviano and Thomas Benz and
                 Paul Scheffler and Luca Benini},
      journal = {IEEE Transactions on Circuits and Systems II: Express Briefs},
      year    = {2023},
      volume  = {70},
      number  = {10},
      pages   = {3777-3781},
      doi     = {10.1109/TCSII.2023.3289186}
}
```
