# Building bitstreams and apps for the ZCU102

This guide covers the build side: getting the sources, building a bitstream with
the configuration you want, and compiling the bare-metal apps that run on
CVA6 + Ara. Running them on the board is covered in [running.md](running.md).

## 1. Requirements

| What | Version used | Needed for |
|---|---|---|
| Vivado (full, with a licence for `xczu9eg`) | 2021.1 | synthesis / implementation |
| Vivado Lab (or full Vivado) | 2021.1 | programming over JTAG |
| [bender](https://github.com/pulp-platform/bender) | 0.31.0 | resolving the hardware sources |
| Python 3 + `pip install -r requirements.txt` | 3.6+ | register / IP generators run by the build |
| RISC-V LLVM toolchain (see section 5) | Ara's `make toolchain-llvm` | building the apps only |

All archived bitstreams were built with Vivado 2021.1. A build takes 1.5–3 h on a
40-core machine with 192 GB of RAM. The run time depends mostly on the lane
count.

## 2. Getting the sources

```bash
git clone https://github.com/StavrosMitro/cheshire_ara.git
cd cheshire_ara
git checkout fp16_v4_dma_spm
git submodule update --init deps/ara      # Ara: RTL, build knobs, apps
bender checkout                           # all other hardware dependencies
```

Do **not** use `--recurse-submodules`. Ara has submodules of its own
(the GCC/LLVM toolchain sources, the CVA6 SDK) that add several GB and are not
needed for a bitstream.

### Where the hardware comes from

`Bender.yml` still lists the upstream git dependencies, but `Bender.lock`
redirects four of them to the patched copies in this repository:

| Dependency | Built from | What is patched |
|---|---|---|
| `ara`  | `deps/ara` (submodule, [ara_zcu102_working](https://github.com/StavrosMitro/ara_zcu102_working)) | FLEN-aware scalar NaN-boxing in the dispatcher, optional ILA probes in the sequencer, ZCU102 build knobs |
| `cva6` | `cva6_patched/` | RVD=0 / FP16 config, FPR write-port fix, optional ILA probes |
| `axi`  | `axi_patched/` | `axi_dw_upsizer` multiple outstanding reads per ID, see `axi_patched/PATCH_NOTES.md` |
| `idma` | `idma_patched/` | 128-bit slave port with width converter |

> **Do not run `bender update`.** It re-resolves the dependencies from
> `Bender.yml` and drops these redirects. The upstream Ara branch does not work on
> this SoC. To check what a build actually used, look at the generated
> `target/xilinx/scripts/add_sources.zcu102.tcl`. Every Ara path should start with
> `$ROOT/deps/ara/`.

## 3. Building a bitstream

All builds go through the Makefile in `deps/ara/cheshire/`. It regenerates the
source list with the selected defines and then calls Cheshire's Xilinx flow.

```bash
cd deps/ara/cheshire
make ara-chs-xilinx BOARD=zcu102 MODE=batch VIVADO="vivado" \
     nr_lanes=4 vlen=2048 llc=1024 fpu=16
```

`VIVADO` is the command that starts Vivado 2021.1 on your machine. Set it
explicitly: `target/xilinx/xilinx.mk` defaults to a site-specific wrapper.

Result: `target/xilinx/out/cheshire.zcu102.bit`, plus `.ltx` when probes are on.
Reports are in `target/xilinx/build/zcu102.cheshire/reports.impl/`.

> The next build overwrites `out/cheshire.zcu102.bit` and the reports. Copy them
> away right after the build, or use the sweep scripts (section 4), which archive
> every build under a unique name.

### Build knobs

| Knob | Default | Meaning |
|---|---|---|
| `nr_lanes` | from `ARA_CONFIGURATION` | Ara lanes (2 or 4 used here). The SoC AXI width follows as `max(32·lanes, 64)`: 2 lanes → 64 bit, 4 lanes → 128 bit |
| `vlen` | from `ARA_CONFIGURATION` | vector register length in bits |
| `llc` | `1024` | LLC size in KiB (cache + SPM ways share it) |
| `fpu` | `16` | Ara vector FPU: `16` = FP16 only, `32` = FP32 only, `1632` = both |
| `atomics` | `0` | `1` adds the RISC-V atomics shims (~13k LUT). Needed only for Linux on CVA6 |
| `dbg` | `0` | `1` adds the RISC-V debug module + JTAG TAP (~11k LUT) |
| `probes` | *(empty)* | ILA probe groups: `mem`, `vec`, `ddr`, or a comma-separated combination. Empty = no ILA |
| `soc_mhz` | `50` | SoC clock (CVA6, Ara, LLC). Must divide 1200. Timing closes at 50; 75 closed only for L2_V1024 |
| `hp0_mhz` | *(= soc)* | PS HP0 port / DRAM-side clock. Must divide 1200, max 300 |

Compare area and timing only between builds with the same `probes` setting. An
ILA costs about 8–10k LUTs.

Approximate numbers for reference (50 MHz, no probes, FP16):

| Config | LUT | RAMB36 | WNS |
|---|---|---|---|
| L2, VLEN 1024, LLC 1 MiB | ~142k (52 %) | 336 | +3.2 ns |
| L4, VLEN 2048, LLC 1 MiB | ~228k (83 %) | 360 | +2.1 ns |

## 4. Building many configurations: the sweep scripts

In `deps/ara/cheshire/`. Each script builds its configurations one after the
other in the same tree. It copies every `.bit`, `.ltx`, timing and utilization
report and the generated source list to `bitstream_archive/` under a name like
`cheshire_top_xilinx_L4_V2048_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_<date>.bit`,
and appends a line to a summary table. Configurations that are already archived
are skipped, so re-running the same command resumes an interrupted sweep.

| Script | Builds |
|---|---|
| `build_arch_sweep.sh` | lanes × VLEN × LLC grid (2/4 lanes, VLEN 256–8192, LLC 1/2 MiB) |
| `build_probe_sweep.sh` | the same geometry with ILA probes (`probes=…`), archives the `.ltx` |
| `build_clock_sweep.sh` | one geometry at different `soc_mhz` / `hp0_mhz` |

```bash
cd deps/ara/cheshire
./build_arch_sweep.sh --list                 # configurations + what is archived
./build_arch_sweep.sh L4_V2048_1M            # build one
VIVADO="vivado" nohup ./build_arch_sweep.sh &  # build everything missing
```

Options are documented at the top of each script (`FORCE=1`, `ARCHIVE=…`,
`LLC=…`, `FPU=…`, `RTLTAG=…`).

## 5. Building the apps

The bare-metal programs live in `deps/ara/apps/`. The FPGA flavour of a target is
`bin/<app>.fpga` (normal FP32/FP64 build) or `bin/<app>.fpga16` (FP16-only build
that matches the `fpu=16` bitstreams). Each produces an ELF, a `.dump` and the
flat `bin/<app>.fpga16.bin` that goes on the SD card.

```bash
cd deps/ara/apps
make bin/fc_layer16only.fpga16   ARA_CONFIGURATION=zcu102_l4_v2048
make bin/conv_layer16only.fpga16 ARA_CONFIGURATION=zcu102_l4_v2048
make bin/vggnet16.fpga16         ARA_CONFIGURATION=zcu102_l4_v2048
```

- `ARA_CONFIGURATION=zcu102_l4_v2048` (`deps/ara/config/zcu102_l4_v2048.mk`)
  describes the 4-lane / VLEN 2048 hardware. The kernels pick the vector length
  at run time with `vsetvli`, so one binary also runs on the other VLEN
  bitstreams. Only FP16 reductions can give slightly different results, because
  their order depends on VLMAX.
- Binaries are linked at `0x4000_0000` (`common/link.fpga.ld`). That address is
  where the loader puts them in DDR (see [running.md](running.md)).
- Test vectors are generated by each app's `script/` and regenerated
  automatically when the size parameters change (`make fc_layer16only-data-force`
  forces it for the FC layers).
- After you change only `-D` defines, delete the app's `*.o.fpga16` files and
  rebuild, so that no stale objects are linked.

### Toolchain

The apps use the LLVM toolchain under `deps/ara/install/riscv-llvm`, built
with Ara's `make toolchain-llvm` from `deps/ara`. You can also point
`INSTALL_DIR` / `LLVM_INSTALL_DIR` at an existing install.

The `.fpga16` targets compile for `rv64imac_zve64f_zvfh` / `lp64`, because the
bitstreams have no scalar or vector FP64. On top of the standard toolchain they
need two libraries built for that arch/ABI:

- compiler-rt builtins in `install/riscv-llvm-fp16only-rt/resource-dir`
  (override with `RISCV_RESOURCE_DIR_FPGA16=…`)
- newlib in `install/riscv-llvm/riscv64-unknown-elf/lib/rv64imac/lp64/`

Without them, the link silently pulls in hard-float FP64 code from the default
libraries, and the binary traps on the board. `common/runtime.mk` explains the
details. The build also runs a guard that rejects `fcvt.s.l`/`fcvt.s.lu`
(int64 → f32): that conversion is broken in the current FPU configuration.

### Simulating first

Every app also has a Spike target (`make spike-run-<app> ARA_CONFIGURATION=zcu102_l4_v2048`).
Use it as the reference result before you run on the board.
