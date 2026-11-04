# Utilization reports

Post-route utilization of every archived ZCU102 bitstream, as written by Vivado
2021.1 (`report_utilization -hierarchical`). Device: `xczu9eg-ffvb1156-2` with
274 080 LUTs, 548 160 FFs, 912 RAMB36 and 2 520 DSPs. Each report breaks the area down by
instance. The interesting subtrees are `i_cheshire_soc` (CVA6, Ara, LLC, iDMA,
interconnect), `i_dram_wrapper` (the path to the PS DDR) and, when present,
`i_ila` + `dbg_hub` (the ILA debug cores).

The configuration is encoded in the file name, the same way the sweep scripts
name the bitstreams ([README, section 5](../README.md#5-building-many-bitstreams-sweep-scripts)):
`L<lanes>_V<VLEN>_LLC<size>_FPU<H=FP16|S=FP32>_DMA1_AXI<width>_noAtomics_noDbg_allfixes[_<tag>]_<date>`.

## Reading the numbers

- **ILA debug cores are included in the totals.** Until 2026-10-26 the memory-path
  ILA was always built in. All builds from 2026-09-10 to 2026-10-15 therefore carry
  ~8.7k LUTs of `i_ila` + `dbg_hub`. Since then probes are a build knob (`probes=`),
  and the tag in the name says which groups were enabled. To compare builds
  fairly, use **LUT w/o debug**: the total minus the `i_ila` and `dbg_hub`
  instances. It is approximate, because the nets marked for debug also keep some
  logic from being optimised away.
- **Builds before 2026-09-09 predate the `axi_dw_upsizer` patch** (`axi_patched/`).
  The patch costs ~2.3k LUTs; compare the two `L2_V2048_LLC1M_FPUH` rows.
- **No archived build matches the current RTL with probes off.** For exact
  numbers, rebuild with `probes=` empty.
- The AXI width follows from the lane count (2 lanes → 64 bit, 4 lanes → 128 bit).
  At 64 bit an extra width converter sits in `i_dram_wrapper`, so a 2-lane build
  is not half the area of a 4-lane one.
- **WNS** is the worst negative slack over all clocks, taken from the timing report
  of the same build. It is positive when timing is met. The SoC clock is 50 MHz
  unless the Clock column says otherwise.

## All builds

| Config (`utilization/<config>.rpt`) | Lanes | VLEN | LLC | FPU | AXI | Clock MHz (SoC/HP0) | ILA probes | LUT (total) | LUT w/o debug | FF | RAMB36 | RAMB18 | DSP | WNS ns | Built |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| [`L2_V256_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261001`](utilization/L2_V256_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261001.rpt) | 2 | 256 | 1M | 16 | 64 | 50 | mem (always on) | 150351 (55 %) | 141610 | 91189 | 339 | 9 | 130 | 2.194 | 2026-10-01 |
| [`L2_V256_LLC1M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015`](utilization/L2_V256_LLC1M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015.rpt) | 2 | 256 | 1M | 32 | 64 | 50 | mem (always on) | 151042 (55 %) | 142295 | 91344 | 339 | 9 | 130 | 0.987 | 2026-10-15 |
| [`L2_V256_LLC2M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261001`](utilization/L2_V256_LLC2M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261001.rpt) | 2 | 256 | 2M | 16 | 64 | 50 | mem (always on) | 151525 (55 %) | 142787 | 91197 | 611 | 1 | 130 | 1.758 | 2026-10-01 |
| [`L2_V256_LLC2M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261014`](utilization/L2_V256_LLC2M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261014.rpt) | 2 | 256 | 2M | 32 | 64 | 50 | mem (always on) | 152041 (55 %) | 143302 | 91352 | 611 | 1 | 130 | 1.577 | 2026-10-14 |
| [`L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20260902`](utilization/L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20260902.rpt) | 2 | 1024 | 1M | 16 | 64 | 50 | none | 141633 (52 %) | 141633 | 81891 | 336 | 8 | 130 | 3.179 | 2026-09-02 |
| [`L2_V1024_LLC1M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015`](utilization/L2_V1024_LLC1M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015.rpt) | 2 | 1024 | 1M | 32 | 64 | 50 | mem (always on) | 152959 (56 %) | 144211 | 91896 | 339 | 9 | 130 | 0.773 | 2026-10-15 |
| [`L2_V1024_LLC2M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261002`](utilization/L2_V1024_LLC2M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261002.rpt) | 2 | 1024 | 2M | 16 | 64 | 50 | mem (always on) | 155432 (57 %) | 146674 | 91794 | 611 | 1 | 130 | 2.398 | 2026-10-02 |
| [`L2_V1024_LLC2M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261014`](utilization/L2_V1024_LLC2M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261014.rpt) | 2 | 1024 | 2M | 32 | 64 | 50 | mem (always on) | 152657 (56 %) | 143915 | 91907 | 611 | 1 | 130 | 0.960 | 2026-10-14 |
| [`L2_V2048_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20260902`](utilization/L2_V2048_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20260902.rpt) | 2 | 2048 | 1M | 16 | 64 | 50 | none | 143020 (52 %) | 143020 | 81449 | 336 | 8 | 130 | 3.095 | 2026-09-02 |
| [`L2_V2048_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_upsizerfix_20260909`](utilization/L2_V2048_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_upsizerfix_20260909.rpt) | 2 | 2048 | 1M | 16 | 64 | 50 | none | 145321 (53 %) | 145321 | 82907 | 336 | 8 | 130 | 1.429 | 2026-09-09 |
| [`L2_V4096_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261001`](utilization/L2_V4096_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261001.rpt) | 2 | 4096 | 1M | 16 | 64 | 50 | mem (always on) | 155331 (57 %) | 146581 | 91435 | 339 | 9 | 130 | 1.869 | 2026-10-01 |
| [`L2_V4096_LLC1M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015`](utilization/L2_V4096_LLC1M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015.rpt) | 2 | 4096 | 1M | 32 | 64 | 50 | mem (always on) | 153598 (56 %) | 144860 | 91572 | 339 | 9 | 130 | 1.656 | 2026-10-15 |
| [`L2_V4096_LLC2M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261002`](utilization/L2_V4096_LLC2M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_20261002.rpt) | 2 | 4096 | 2M | 16 | 64 | 50 | mem (always on) | 155810 (57 %) | 147066 | 91441 | 611 | 1 | 130 | 1.693 | 2026-10-02 |
| [`L2_V4096_LLC2M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015`](utilization/L2_V4096_LLC2M_FPUS_DMA1_AXI64_noAtomics_noDbg_allfixes_20261015.rpt) | 2 | 4096 | 2M | 32 | 64 | 50 | mem (always on) | 155222 (57 %) | 146469 | 91581 | 611 | 1 | 130 | 2.086 | 2026-10-15 |
| [`L4_V512_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261001`](utilization/L4_V512_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261001.rpt) | 4 | 512 | 1M | 16 | 128 | 50 | mem (always on) | 234613 (86 %) | 225895 | 114641 | 363 | 9 | 234 | 2.326 | 2026-10-01 |
| [`L4_V512_LLC1M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015`](utilization/L4_V512_LLC1M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015.rpt) | 4 | 512 | 1M | 32 | 128 | 50 | mem (always on) | 231016 (84 %) | 222306 | 114881 | 363 | 9 | 234 | 2.321 | 2026-10-15 |
| [`L4_V512_LLC2M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261002`](utilization/L4_V512_LLC2M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261002.rpt) | 4 | 512 | 2M | 16 | 128 | 50 | mem (always on) | 235564 (86 %) | 226854 | 114656 | 627 | 1 | 234 | 2.161 | 2026-10-02 |
| [`L4_V512_LLC2M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015`](utilization/L4_V512_LLC2M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015.rpt) | 4 | 512 | 2M | 32 | 128 | 50 | mem (always on) | 234347 (86 %) | 225648 | 114893 | 627 | 1 | 234 | 1.730 | 2026-10-15 |
| [`L4_V2048_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20260904`](utilization/L4_V2048_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20260904.rpt) | 4 | 2048 | 1M | 16 | 128 | 50 | none | 227604 (83 %) | 227604 | 106340 | 360 | 8 | 234 | 2.072 | 2026-09-04 |
| [`L4_V2048_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20260910`](utilization/L4_V2048_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20260910.rpt) | 4 | 2048 | 1M | 16 | 128 | 50 | mem (always on) | 233389 (85 %) | 224679 | 116302 | 363 | 9 | 234 | 1.311 | 2026-09-10 |
| [`L4_V2048_LLC1M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015`](utilization/L4_V2048_LLC1M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015.rpt) | 4 | 2048 | 1M | 32 | 128 | 50 | mem (always on) | 237471 (87 %) | 228771 | 116556 | 363 | 9 | 234 | 1.874 | 2026-10-15 |
| [`L4_V2048_LLC2M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261002`](utilization/L4_V2048_LLC2M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261002.rpt) | 4 | 2048 | 2M | 16 | 128 | 50 | mem (always on) | 237318 (87 %) | 228622 | 116311 | 627 | 1 | 234 | 0.853 | 2026-10-02 |
| [`L4_V2048_LLC2M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015`](utilization/L4_V2048_LLC2M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015.rpt) | 4 | 2048 | 2M | 32 | 128 | 50 | mem (always on) | 236954 (86 %) | 228241 | 116574 | 627 | 1 | 234 | 1.091 | 2026-10-15 |
| [`L4_V4096_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20260902`](utilization/L4_V4096_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20260902.rpt) | 4 | 4096 | 1M | 16 | 128 | 50 | none | 233863 (85 %) | 233863 | 106958 | 360 | 8 | 234 | 0.912 | 2026-09-02 |
| [`L4_V8192_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261001`](utilization/L4_V8192_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261001.rpt) | 4 | 8192 | 1M | 16 | 128 | 50 | mem (always on) | 239154 (87 %) | 230438 | 116842 | 363 | 9 | 234 | 1.041 | 2026-10-01 |
| [`L4_V8192_LLC1M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015`](utilization/L4_V8192_LLC1M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015.rpt) | 4 | 8192 | 1M | 32 | 128 | 50 | mem (always on) | 240572 (88 %) | 231858 | 117707 | 363 | 9 | 234 | 0.763 | 2026-10-15 |
| [`L4_V8192_LLC2M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261002`](utilization/L4_V8192_LLC2M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_20261002.rpt) | 4 | 8192 | 2M | 16 | 128 | 50 | mem (always on) | 237835 (87 %) | 229113 | 116849 | 627 | 1 | 234 | 2.142 | 2026-10-02 |
| [`L4_V8192_LLC2M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015`](utilization/L4_V8192_LLC2M_FPUS_DMA1_AXI128_noAtomics_noDbg_allfixes_20261015.rpt) | 4 | 8192 | 2M | 32 | 128 | 50 | mem (always on) | 240009 (88 %) | 231301 | 117713 | 627 | 1 | 234 | 1.266 | 2026-10-15 |
| [`L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC25_20261027`](utilization/L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC25_20261027.rpt) | 2 | 1024 | 1M | 16 | 64 | 25 | ddr,mem | 150334 (55 %) | 140374 | 92727 | 340 | 8 | 130 | 14.882 | 2026-10-27 |
| [`L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-mem-vec_20261026`](utilization/L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-mem-vec_20261026.rpt) | 2 | 1024 | 1M | 16 | 64 | 50 | mem,vec | 159235 (58 %) | 145739 | 95938 | 342 | 8 | 130 | 1.987 | 2026-10-26 |
| [`L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC50_20261028`](utilization/L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC50_20261028.rpt) | 2 | 1024 | 1M | 16 | 64 | 50 | ddr,mem | 155228 (57 %) | 145273 | 92732 | 340 | 8 | 130 | 1.787 | 2026-10-28 |
| [`L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC50_HP0100_20261027`](utilization/L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC50_HP0100_20261027.rpt) | 2 | 1024 | 1M | 16 | 64 | 50/100 | ddr,mem | 153393 (56 %) | 143429 | 92720 | 340 | 8 | 130 | 2.320 | 2026-10-27 |
| [`L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC75_20261027`](utilization/L2_V1024_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-ddr-mem_SOC75_20261027.rpt) | 2 | 1024 | 1M | 16 | 64 | 75 | ddr,mem | 155936 (57 %) | 145961 | 92742 | 340 | 8 | 130 | 0.003 | 2026-10-27 |
| [`L2_V4096_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-mem-vec_20261026`](utilization/L2_V4096_LLC1M_FPUH_DMA1_AXI64_noAtomics_noDbg_allfixes_probes-mem-vec_20261026.rpt) | 2 | 4096 | 1M | 16 | 64 | 50 | mem,vec | 157634 (58 %) | 144151 | 95587 | 342 | 8 | 130 | 1.925 | 2026-10-26 |
| [`L4_V1024_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_probes-mem-vec_20261026`](utilization/L4_V1024_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_probes-mem-vec_20261026.rpt) | 4 | 1024 | 1M | 16 | 128 | 50 | mem,vec | 241619 (88 %) | 228186 | 119940 | 366 | 8 | 234 | 1.398 | 2026-10-26 |
| [`L4_V4096_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_probes-mem-vec_20261026`](utilization/L4_V4096_LLC1M_FPUH_DMA1_AXI128_noAtomics_noDbg_allfixes_probes-mem-vec_20261026.rpt) | 4 | 4096 | 1M | 16 | 128 | 50 | mem,vec | 244899 (89 %) | 231388 | 120475 | 366 | 8 | 234 | 0.742 | 2026-10-26 |
