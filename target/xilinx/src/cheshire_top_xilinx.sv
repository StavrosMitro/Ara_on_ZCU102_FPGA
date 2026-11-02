// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Nicole Narr <narrn@student.ethz.ch>
// Christopher Reinwardt <creinwar@student.ethz.ch>
// Cyril Koenig <cykoenig@iis.ee.ethz.ch>
// Yann Picod <ypicod@ethz.ch>
// Paul Scheffler <paulsc@iis.ee.ethz.ch>

`include "cheshire/typedef.svh"
`include "phy_definitions.svh"

// TODO: Expose more IO: unused SPI CS, Serial Link, etc.

module cheshire_top_xilinx import cheshire_pkg::*; (
  input  logic  sys_clk_p,
  input  logic  sys_clk_n,

`ifdef USE_RESET
  input  logic  sys_reset,
`endif
`ifdef USE_RESETN
  input  logic  sys_resetn,
`endif

`ifdef USE_SWITCHES
  input logic       test_mode_i,
  input logic [1:0] boot_mode_i,
`endif

`ifdef USE_JTAG
  input  logic  jtag_tck_i,
  input  logic  jtag_tms_i,
  input  logic  jtag_tdi_i,
  output logic  jtag_tdo_o,
`ifdef USE_JTAG_TRSTN
  input  logic  jtag_trst_ni,
`endif
`ifdef USE_JTAG_VDDGND
  output logic  jtag_vdd_o,
  output logic  jtag_gnd_o,
  `endif
`endif

`ifdef USE_I2C
  inout  wire   i2c_scl_io,
  inout  wire   i2c_sda_io,
`endif

`ifdef USE_SD
  input  logic        sd_cd_i,
  output logic        sd_cmd_o,
  inout  wire  [3:0]  sd_d_io,
  output logic        sd_reset_o,
  output logic        sd_sclk_o,
`endif

`ifdef USE_FAN
  input  logic [3:0]  fan_sw,
  output logic        fan_pwm,
`endif

`ifdef USE_VGA
  // VGA Colour signals
  output logic        vga_hsync_o,
  output logic        vga_vsync_o,
  output logic [4:0]  vga_red_o,
  output logic [5:0]  vga_green_o,
  output logic [4:0]  vga_blue_o,
`endif

`ifdef USE_DDR4
  `DDR4_INTF
`endif
`ifdef USE_DDR3
  `DDR3_INTF
`endif

  `ifndef USE_ZYNQMP
    output logic  uart_tx_o,
    input  logic  uart_rx_i,
  `endif

  `ifdef USE_ZYNQMP
    // Η διεπαφή AXI (Μπαλαντέζα) προς το Zynq PS
    //`ZYNQMP_HP0_MST_INTF ---> INTERNAL SIGNALS
    //`ZYNQMP_HP0_WIRE_DECL
    // Τα φυσικά pins του ARM (MIOs) και της DDR4 μνήμης του
  `endif

  inout  wire [UsbNumPorts-1:0] usb_dm_io,
  inout  wire [UsbNumPorts-1:0] usb_dp_io
);

`ifdef USE_ZYNQMP  
	`ZYNQMP_HP0_WIRE_DECL
`endif

  ///////////////////////
  //  Cheshire Config  //
  ///////////////////////

  // Use default config as far as possible
  // Target size of the LLC data array in BYTES. Held constant across AXI
  // widths by deriving LlcNumLines from it below; change this, not NumLines.
  // Set from the build command line, e.g.
  //   make ara-chs-xilinx BOARD=zcu102 nr_lanes=4 vlen=2048 llc=1024
  // (deps/ara/cheshire/Makefile turns `llc` into --define LLC_KIB). This is the
  // TOTAL LLC RAM: cache ways and SPM ways share it, and the split between them
  // is a runtime bitmask (cfg_spm at AmLlc+0x00), not a build-time choice.
  localparam int unsigned LlcTargetBytes =
      1024 * (`ifdef LLC_KIB `LLC_KIB `else 1024 `endif);

  function automatic cheshire_cfg_t gen_cheshire_xilinx_cfg();
    cheshire_cfg_t ret  = DefaultCfg;
    ret.RtcFreq         = 1000000;
    ret.SerialLink      = 0;
    ret.Vga             = 0;
    ret.SpiHost         = 0;
    ret.I2c             = 0;
    ret.BusErr          = 0;
    ret.Gpio            = 0;
    // iDMA ENABLED for LLC-SPM latency hiding. Previously 0 because nothing
    // used it (apps do RVV load/store + software memcpy; the boot ROM, the
    // other DMA user, is bypassed -- FPGA apps link -nostartfiles with their
    // own apps/common/crt0.S and are loaded by the ARM PS, so boot-ROM DMA is
    // irrelevant here either way).
    // Now needed: to overlap DDR<->SPM transfer with compute (double buffering)
    // the mover must NOT be CVA6 (blocks the scalar core) or Ara's own LSU
    // (occupies the very unit we are trying to keep busy). The DMA is an AXI
    // crossbar master (axi_in_req[AxiIn.dma]) so it can address DDR
    // (LlcOutRegionStart=0x4000_0000), SPM (0x1000_0000 cached / 0x1400_0000
    // uncached) and peripherals alike -- DDR->SPM, SPM->DDR and SPM->SPM are
    // all just descriptors. DmaConfEnableTwoD=1 gives strided/tiled copies.
    ret.Dma             = 1;
    ret.LlcNotBypass    = 1;
    // RISC-V atomics (AMO + LR/SC) on the four AXI slave shims. Verified 2026-08-26
    // that nothing in this workload issues one: zero amo/lr/sc in the .text of
    // vggnet16, fc_layer16only and conv_layer16only (which include crt0.S and the
    // static libc), and zero in the 8 KiB bootrom. serial.c/printf.c use
    //   __sync_synchronize(), which is a barrier -> `fence`, not an atomic.
    // Disabling drops ~13.2k LUTs AND removes the LlcMaxReadTxns=16 in-flight read
    // throttle on the SoC->LLC path. MUST stay paired with CVA6ConfigAExtEn=0 so a
    // stray atomic traps instead of silently passing through as a normal access.
    // Re-enable (atomics=1) for Linux or any multi-hart / locking software.
    ret.AtomicsEnable   = `ifdef NO_ATOMICS 1'b0 `else 1'b1 `endif;
    // RISC-V debug module. `USE_JTAG is defined nowhere for TARGET_ZCU102, so the
    // DM has no top-level pins and is pure dead weight (~10.8k LUTs). Its 128->64
    // isolation converter also caused the DRC LUTLP-1 loop on 2026-08-26. The
    // crossbar port and address map are unchanged -- see cheshire_soc.sv.
    // Build with dbg=1 to restore it (needed only if `USE_JTAG is ever defined).
    ret.DbgEnable       = `ifdef NO_DBG 1'b0 `else 1'b1 `endif;
    // SoC AXI 64 -> 128 bit. Ara's port is AraDataWideWidth = 32*NrLanes bits
    // (= 4*NrLanes bytes/cycle, Ara's documented L2 bandwidth). At 2 lanes that
    // is 64b and matches the SoC, so the Ara<->SoC converter degenerates away.
    // At 4 lanes Ara wants 128b and a 64b SoC would DOWNSIZE it -- halving both
    // DDR *and* SPM bandwidth (SPM is reached through the same crossbar), which
    // would waste the extra lanes. 128b also matches the PS HP0 port
    // (dram_wrapper_xilinx.sv cfg.DataWidth=128), so the 64->128 upsizer there
    // hits axi_dw_converter's gen_no_dw_conversion branch and disappears
    // (~18.7k LUTs at MaxReads=24), partly paying for the wider crossbar.
    // NB: gen_cva6_cfg does ret.AxiDataWidth = cfg.AxiDataWidth, so CVA6's AXI
    // widens too (DcacheLineWidth=256 -> 2 beats; no assertion constrains it).
    // RESOLVED 2026-08-26 -- 128b is LIVE and has passed synth+place+route with
    // timing met (WNS +1.785). The old blocker is recorded here because the
    // reasoning still applies to any other width-sensitive IP:
    //   dm_csrs.sv:172 declares `logic [63:0] sbdata_q` but indexes it
    //   [BusWidth-1:0], so BusWidth=128 was an out-of-range part-select. This
    //   is not a bug: the RISC-V debug spec defines system-bus access as 32-bit
    //   sbdata register pairs, so 64 bit is its hard architectural ceiling.
    // First fix was to isolate the DM at 64b behind dw converters. That worked
    // but cost 8,265 LUTs AND created a DRC LUTLP-1 combinational loop with
    // axi_to_mem_interleaved (which ties mem_gnt_i to mem_req_o), killing the
    // build at write_bitstream. Since `USE_JTAG is defined nowhere here, the
    // whole DM was dead weight -- so it is now disabled outright (DbgEnable
    // above), which removes the converters, the loop and ~10.8k LUTs together.
    // Measured net effect of 64->128b: -20,577 (DRAM dw_converter vanishes,
    // SoC 128 == HP0 128), -4,702 (Ara downsizer vanishes), +3,019 (wider xbar/
    // LLC/DMA) = about -14k LUTs. NB dw_converter cost is a STEP function, not
    // a ratio: it is either its full size or exactly zero. Check both widths.
    // The SPM/cache split itself is NOT fixed here -- cfg_spm at AmLlc+0x00 is
    // a runtime way-mask, so 0xFF (all SPM) vs 0x3F (6 SPM + 2 cache ways as
    // L2 for CVA6's 4 KiB L1I / 8 KiB L1D) can be compared on this same
    // bitstream without a rebuild.
  `ifdef USE_USB
    ret.Usb = 1;
  `else
    ret.Usb = 0;
  `endif
  `ifdef ARA
    ret.Ara = 1;
    ret.AraVLEN = `ifdef VLEN `VLEN `else 0 `endif;
    ret.AraNrLanes = `ifdef NR_LANES `NR_LANES `else 0 `endif;
  `endif

    ///////////////////////////////////////////////////////////////////////
    // Lane-parametric SoC AXI width + LLC geometry. KEEP THIS ORDERING:  //
    // AxiDataWidth must be set AFTER AraNrLanes and BEFORE LlcNumLines.  //
    ///////////////////////////////////////////////////////////////////////

    // Ara's memory port is AraDataWideWidth = 32*NrLanes bits (= 4*NrLanes
    // bytes/cycle, its documented L2 bandwidth). A narrower SoC AXI makes
    // cheshire_soc.sv insert a downsizer that throttles Ara to the SoC width --
    // and since SPM lives behind the same crossbar, that halves SPM bandwidth
    // too, not just DDR. Deriving the width from the lane count keeps them
    // matched at every configuration and makes the converters disappear:
    // axi_dw_converter has a gen_no_dw_conversion branch for equal widths, so
    // no `ifdef`/lane test is needed anywhere -- the hardware self-eliminates.
    //   2 lanes ->  64b : Ara converter absent (already the case today)
    //   4 lanes -> 128b : Ara converter absent AND the DRAM upsizer disappears
    //                     (PS HP0 is 128b -> equal widths), ~20.6k LUTs freed
    //   8 lanes -> 256b : NB the DRAM side then becomes a 256->128 *downsizer*;
    //                     HP0 is the bandwidth wall from there on.
    // Floor of 64 covers CVA6/peripherals and the Ara-disabled case (lanes=0).
    ret.AxiDataWidth = (32*ret.AraNrLanes > 64) ? 32*ret.AraNrLanes : 64;

    // LLC RAM sized in BYTES, independent of AXI width. Blocks are
    // AxiDataWidth/8 bytes wide, so NumLines must scale inversely or the SPM
    // silently doubles when the bus widens:
    //   SizeSpm = SetAssoc * NumLines * NumBlocks * AxiDataWidth/8
    // 1 MiB gives 2048 lines @64b, 1024 @128b, 512 @256b.
    // NumLines is the right knob: NumBlocks would inflate the cache line
    // (worse refills), SetAssoc would inflate tag-comparator area. Cost is
    // BRAM, not LUTs (~320 RAMB36 for 1 MiB), and BRAM is what we have spare.
    ret.LlcNumLines = LlcTargetBytes /
                      (ret.LlcSetAssoc * ret.LlcNumBlocks * (ret.AxiDataWidth/8));
  `ifdef TARGET_ZCU102
    ret.Cva6NiDramRule = 0;
  `endif
    return ret;
  endfunction

  // Configure cheshire for FPGA mapping
  localparam cheshire_cfg_t FPGACfg = gen_cheshire_xilinx_cfg();
  `CHESHIRE_TYPEDEF_ALL(, FPGACfg)

  ////////////////////////
  //  Clock Generation  //
  ////////////////////////

  wire sys_clk;
  wire soc_clk;
  wire usb_clk;
  wire mmcm_locked;   // ILA-DEBUG: clkwiz lock status (was previously left unconnected)

  IBUFDS #(
    .IBUF_LOW_PWR ("FALSE")
  ) i_bufds_sys_clk (
    .I  ( sys_clk_p ),
    .IB ( sys_clk_n ),
    .O  ( sys_clk   )
  );

`ifdef HP0_MHZ
`ifndef SOC_MHZ
  `define SOC_MHZ 50       // hp0_mhz= alone: SoC stays at 50, HP0 moves
`endif
`endif
`ifdef SOC_MHZ
  // Clock knob, OFF by default (deps/ara/cheshire/Makefile: soc_mhz= / hp0_mhz=).
  // With a knob set, the clkwiz IP is NOT used: one MMCM instantiated right here,
  // same input and VCO as the clkwiz (300 MHz x4 = 1200 MHz), each output an
  // integer divide of 1200 -- the Makefile only accepts such frequencies.
  // Without a knob this whole block is skipped and the original clkwiz below is
  // compiled unchanged, so default builds and the cached clkwiz IP are untouched.
  //   CLKOUT0  soc_clk   1200 / SOC_MHZ
  //   CLKOUT1  usb_clk   1200 / 25 = 48 MHz   (as clk_48 of the clkwiz)
  //   CLKOUT2  hp0_clk   1200 / HP0_MHZ       (only with `HP0_MHZ)
  // The BUFG outputs drive the nets soc_clk / usb_clk DIRECTLY so they keep their
  // names: zcu102.xdc and insert_ilas {soc_clk} look soc_clk up by name.
`ifdef HP0_MHZ
  wire hp0_clk;
  localparam int unsigned Hp0Div = 1200 / `HP0_MHZ;
`else
  localparam int unsigned Hp0Div = 12;        // output unused
`endif
  wire soc_clk_mmcm, usb_clk_mmcm, hp0_clk_mmcm, clkgen_fb;
  MMCME4_BASE #(
    .CLKIN1_PERIOD    ( 3.333                 ),
    .DIVCLK_DIVIDE    ( 1                     ),
    .CLKFBOUT_MULT_F  ( 4.0                   ),
    .CLKOUT0_DIVIDE_F ( 1200.0 / `SOC_MHZ     ),
    .CLKOUT1_DIVIDE   ( 25                    ),
    .CLKOUT2_DIVIDE   ( Hp0Div                )
  ) i_clkgen (
    .CLKIN1   ( sys_clk      ),
    .CLKFBIN  ( clkgen_fb    ),
    .CLKFBOUT ( clkgen_fb    ),
    .CLKOUT0  ( soc_clk_mmcm ),
    .CLKOUT1  ( usb_clk_mmcm ),
    .CLKOUT2  ( hp0_clk_mmcm ),
    .LOCKED   ( mmcm_locked  ),
    .PWRDWN   ( 1'b0         ),
    .RST      ( 1'b0         ),
    .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
  );
  BUFG i_bufg_soc_clk ( .I ( soc_clk_mmcm ), .O ( soc_clk ) );
  BUFG i_bufg_usb_clk ( .I ( usb_clk_mmcm ), .O ( usb_clk ) );
`ifdef HP0_MHZ
  BUFG i_bufg_hp0_clk ( .I ( hp0_clk_mmcm ), .O ( hp0_clk ) );
`endif
`else
  clkwiz i_clkwiz (
    .clk_in1  ( sys_clk ),
  //.locked   ( ),                 // ILA-DEBUG: was unconnected
    .locked   ( mmcm_locked ),     // ILA-DEBUG: expose lock status
    .clk_50   ( soc_clk ),
    .clk_48   ( usb_clk ),
    .clk_20   ( ),
    .clk_10   ( )
  );
`endif

  /////////////////////
  //  System Inputs  //
  /////////////////////

  // Select SoC reset
// Select SoC reset
`ifdef USE_RESET
  logic sys_resetn;
  assign sys_resetn = ~sys_reset;
`elsif USE_RESETN
  logic sys_reset;
  assign sys_reset  = ~sys_resetn;
`elsif USE_ZYNQMP
  // Το Reset προέρχεται από το GPIO του PS (ARM) — δεν είναι κουμπί της πλακέτας.
  logic sys_reset, sys_resetn;
  logic ps_gpio_o;
  assign sys_reset  = ps_gpio_o;
  assign sys_resetn = ~sys_reset;
`endif

  // Tie off inputs of no switches
`ifndef USE_SWITCHES
  logic       test_mode_i;
  logic [1:0] boot_mode_i;
  assign test_mode_i = '0;
  assign boot_mode_i = '0;
`endif

  ////////////
  //  VIOs  //
  ////////////

  logic       vio_reset, vio_boot_mode_sel;
  logic [1:0] boot_mode, vio_boot_mode;
  logic       sys_rst;

  // K5 3b: the K1/K3/K4 ni_disable_i diagnostic switch (VIO probe_out3,
  // USE_NI_VIO macro) is removed -- the icache/load_unit/wbuffer deadlock it
  // was used to gate around is now fixed at the config source (see
  // gen_cheshire_xilinx_cfg() above, Cva6NiDramRule). impl_ip.tcl reverted
  // to C_NUM_PROBE_OUT=3 (matching genesys2/vcu128) alongside this.
`ifdef USE_VIO
  vio i_vio (
    .clk        ( soc_clk ),
    .probe_out0 ( vio_reset         ),
    .probe_out1 ( vio_boot_mode     ),
    .probe_out2 ( vio_boot_mode_sel )
  );
`else
  assign vio_reset          = '0;
  assign vio_boot_mode      = '0;
  assign vio_boot_mode_sel  = '0;
`endif

  assign sys_rst = ~sys_resetn | vio_reset;
  assign boot_mode = vio_boot_mode_sel ? vio_boot_mode : boot_mode_i;

  //////////////////
  //  Reset Sync  //
  //////////////////

  wire rst_n;

  rstgen i_rstgen (
    .clk_i        ( soc_clk     ),
    .rst_ni       ( ~sys_rst    ),
    .test_mode_i  ( test_mode_i ),
    .rst_no       ( rst_n       ),
    .init_no      ( )
  );


  ////////////
  //  JTAG  //
  ////////////

`ifdef USE_JTAG_VDDGND
  assign jtag_vdd_o = 1'b1;
  assign jtag_gnd_o = 1'b0;
`endif
`ifndef USE_JTAG_TRSTN
  logic jtag_trst_ni;
  assign jtag_trst_ni = 1'b1;
`endif

  //////////////////
  // I2C Adaption //
  //////////////////

  logic i2c_sda_soc_out;
  logic i2c_sda_soc_in;
  logic i2c_scl_soc_out;
  logic i2c_scl_soc_in;
  logic i2c_sda_en;
  logic i2c_scl_en;

`ifdef USE_I2C
  IOBUF #(
    .DRIVE        ( 12        ),
    .IBUF_LOW_PWR ( "FALSE"   ),
    .IOSTANDARD   ( "DEFAULT" ),
    .SLEW         ( "FAST"    )
  ) i_scl_iobuf (
    .O  ( i2c_scl_soc_in  ),
    .IO ( i2c_scl_io      ),
    .I  ( i2c_scl_soc_out ),
    .T  ( ~i2c_scl_en     )
  );

  IOBUF #(
    .DRIVE        ( 12        ),
    .IBUF_LOW_PWR ( "FALSE"   ),
    .IOSTANDARD   ( "DEFAULT" ),
    .SLEW         ( "FAST"    )
  ) i_sda_iobuf (
    .O  ( i2c_sda_soc_in  ),
    .IO ( i2c_sda_io      ),
    .I  ( i2c_sda_soc_out ),
    .T  ( ~i2c_sda_en     )
  );
`endif

  ///////////////
  // SPI to SD //
  ///////////////

  logic spi_sck_soc;
  logic [1:0] spi_cs_soc;
  logic [3:0] spi_sd_soc_out;
  logic [3:0] spi_sd_soc_in;

  logic spi_sck_en;
  logic [1:0] spi_cs_en;
  logic [3:0] spi_sd_en;

`ifdef USE_SD
  // Assert reset low => Apply power to the SD Card
  assign sd_reset_o       = 1'b0;
  // SCK  - SD CLK signal
  assign sd_sclk_o        = spi_sck_en    ? spi_sck_soc       : 1'b1;
  // CS   - SD DAT3 signal
  assign sd_d_io[3]       = spi_cs_en[0]  ? spi_cs_soc[0]     : 1'b1;
  // MOSI - SD CMD signal
  assign sd_cmd_o         = spi_sd_en[0]  ? spi_sd_soc_out[0] : 1'b1;
  // MISO - SD DAT0 signal
  assign spi_sd_soc_in[1] = sd_d_io[0];
  // SD DAT1 and DAT2 signal tie-off - Not used for SPI mode
  assign sd_d_io[2:1]     = 2'b11;
  // Bind input side of SoC low for output signals
  assign spi_sd_soc_in[0] = 1'b0;
  assign spi_sd_soc_in[2] = 1'b0;
  assign spi_sd_soc_in[3] = 1'b0;
`endif

  ////////////
  //  QSPI  //
  ////////////

`ifdef USE_QSPI
  logic                 qspi_clk;
  logic                 qspi_clk_ts;
  logic [3:0]           qspi_dqi;
  logic [3:0]           qspi_dqo_ts;
  logic [3:0]           qspi_dqo;
  logic [SpihNumCs-1:0] qspi_cs_b;
  logic [SpihNumCs-1:0] qspi_cs_b_ts;

  assign qspi_clk      = spi_sck_soc;
  assign qspi_cs_b     = spi_cs_soc;
  assign qspi_dqo      = spi_sd_soc_out;
  assign spi_sd_soc_in = qspi_dqi;

  // Tristate enables
  assign qspi_clk_ts  = ~spi_sck_en;
  assign qspi_cs_b_ts = ~spi_cs_en;
  assign qspi_dqo_ts  = ~spi_sd_en;

  // On VCU128/ZCU102, SPI ports are not directly available
`ifdef USE_STARTUPE3
  STARTUPE3 #(
    .PROG_USR("FALSE"),
    .SIM_CCLK_FREQ(0.0)
  ) i_startupe3 (
    .CFGCLK     ( ),
    .CFGMCLK    ( ),
    .DI         ( qspi_dqi ),
    .EOS        ( ),
    .PREQ       ( ),
    .DO         ( qspi_dqo ),
    .DTS        ( qspi_dqo_ts ),
    .FCSBO      ( qspi_cs_b[1] ),
    .FCSBTS     ( qspi_cs_b_ts[1] ),
    .GSR        ( 1'b0 ),
    .GTS        ( 1'b0 ),
    .KEYCLEARB  ( 1'b1 ),
    .PACK       ( 1'b0 ),
    .USRCCLKO   ( qspi_clk ),
    .USRCCLKTS  ( qspi_clk_ts ),
    .USRDONEO   ( 1'b1 ),
    .USRDONETS  ( 1'b1 )
  );
`else
  // TODO: off-chip QSPI interface
`endif
`endif

  ///////////
  //  USB  //
  ///////////

  // SoC IOs
  logic [UsbNumPorts-1:0] usb_dm_i;
  logic [UsbNumPorts-1:0] usb_dm_o;
  logic [UsbNumPorts-1:0] usb_dm_oe_o;
  logic [UsbNumPorts-1:0] usb_dp_i;
  logic [UsbNumPorts-1:0] usb_dp_o;
  logic [UsbNumPorts-1:0] usb_dp_oe_o;

  for (genvar i = 0; i < FPGACfg.Usb*UsbNumPorts; ++i) begin : gen_usb_tristate
    assign usb_dp_io [i] = usb_dp_oe_o[i] ? usb_dp_o[i] : 'z;
    assign usb_dp_i  [i] = usb_dp_io[i];
    assign usb_dm_io [i] = usb_dm_oe_o[i] ? usb_dm_o[i] : 'z;
    assign usb_dm_i  [i] = usb_dm_io[i];
  end

  /////////////////////////
  // "RTC" Clock Divider //
  /////////////////////////

  logic rtc_clk_d, rtc_clk_q;
  logic [15:0] counter_d, counter_q;

`ifdef SOC_MHZ
  // Divide soc_clk (SOC_MHZ MHz) by SOC_MHZ => 1 MHz RTC clock, same as at 50.
  // SOC_MHZ may be odd, so a toggle every SOC_MHZ/2 cycles would not be 1 MHz:
  // count a full period instead and hold rtc high for its first SOC_MHZ/2 cycles.
  localparam int unsigned SocMhz = `SOC_MHZ;
  always_comb begin
    counter_d = (counter_q == SocMhz - 1) ? '0 : counter_q + 1;
    rtc_clk_d = (counter_d < SocMhz / 2);
  end
`else
  // Divide soc_clk (50 MHz) by 50 => 1 MHz RTC Clock
  always_comb begin
    counter_d = counter_q + 1;
    rtc_clk_d = rtc_clk_q;

    if(counter_q == 24) begin
      counter_d = '0;
      rtc_clk_d = ~rtc_clk_q;
    end
  end
`endif

  always_ff @(posedge soc_clk, negedge rst_n) begin
    if(~rst_n) begin
      counter_q <= '0;
      rtc_clk_q <= 0;
    end else begin
      counter_q <= counter_d;
      rtc_clk_q <= rtc_clk_d;
    end
  end

  /////////////////
  // Fan Control //
  /////////////////

`ifdef USE_FAN
  fan_ctrl i_fan_ctrl (
    .clk_i          ( soc_clk ),
    .rst_ni         ( rst_n   ),
    .pwm_setting_i  ( fan_sw  ),
    .fan_pwm_o      ( fan_pwm )
  );
`endif

  //////////////
  // DRAM MIG //
  //////////////

  axi_llc_req_t axi_llc_mst_req;
  axi_llc_rsp_t axi_llc_mst_rsp;

`ifdef USE_DDR
  dram_wrapper_xilinx #(
    .axi_soc_aw_chan_t ( axi_llc_aw_chan_t ),
    .axi_soc_w_chan_t  ( axi_llc_w_chan_t  ),
    .axi_soc_b_chan_t  ( axi_llc_b_chan_t  ),
    .axi_soc_ar_chan_t ( axi_llc_ar_chan_t ),
    .axi_soc_r_chan_t  ( axi_llc_r_chan_t  ),
    .axi_soc_req_t     ( axi_llc_req_t     ),
    .axi_soc_resp_t    ( axi_llc_rsp_t     )
) i_dram_wrapper (
    .sys_rst_i      ( sys_rst          ),
    .soc_resetn_i   ( rst_n            ),
    .soc_clk_i      ( soc_clk          ),
`ifdef HP0_MHZ
    .dram_clk_i     ( hp0_clk          ),   // ZynqMP: clocks HP0 + CDC dst side
`else
    .dram_clk_i     ( sys_clk          ),
`endif
    .soc_req_i      ( axi_llc_mst_req  ),
    .soc_rsp_o      ( axi_llc_mst_rsp  ),
`ifdef USE_ZYNQMP
    .ps_hp0_aclk    ( ps_hp0_aclk      ),
    .ps_hp0_awid    ( ps_hp0_awid      ),
    .ps_hp0_awaddr  ( ps_hp0_awaddr    ),
    .ps_hp0_awlen   ( ps_hp0_awlen     ),
    .ps_hp0_awsize  ( ps_hp0_awsize    ),
    .ps_hp0_awburst ( ps_hp0_awburst   ),
    .ps_hp0_awlock  ( ps_hp0_awlock    ),
    .ps_hp0_awcache ( ps_hp0_awcache   ),
    .ps_hp0_awprot  ( ps_hp0_awprot    ),
    .ps_hp0_awqos   ( ps_hp0_awqos     ),
    .ps_hp0_awvalid ( ps_hp0_awvalid   ),
    .ps_hp0_awready ( ps_hp0_awready   ),
    .ps_hp0_wdata   ( ps_hp0_wdata     ),
    .ps_hp0_wstrb   ( ps_hp0_wstrb     ),
    .ps_hp0_wlast   ( ps_hp0_wlast     ),
    .ps_hp0_wvalid  ( ps_hp0_wvalid    ),
    .ps_hp0_wready  ( ps_hp0_wready    ),
    .ps_hp0_bid     ( ps_hp0_bid       ),
    .ps_hp0_bresp   ( ps_hp0_bresp     ),
    .ps_hp0_bvalid  ( ps_hp0_bvalid    ),
    .ps_hp0_bready  ( ps_hp0_bready    ),
    .ps_hp0_arid    ( ps_hp0_arid      ),
    .ps_hp0_araddr  ( ps_hp0_araddr    ),
    .ps_hp0_arlen   ( ps_hp0_arlen     ),
    .ps_hp0_arsize  ( ps_hp0_arsize    ),
    .ps_hp0_arburst ( ps_hp0_arburst   ),
    .ps_hp0_arlock  ( ps_hp0_arlock    ),
    .ps_hp0_arcache ( ps_hp0_arcache   ),
    .ps_hp0_arprot  ( ps_hp0_arprot    ),
    .ps_hp0_arqos   ( ps_hp0_arqos     ),
    .ps_hp0_arvalid ( ps_hp0_arvalid   ),
    .ps_hp0_arready ( ps_hp0_arready   ),
    .ps_hp0_rid     ( ps_hp0_rid       ),
    .ps_hp0_rdata   ( ps_hp0_rdata     ),
    .ps_hp0_rresp   ( ps_hp0_rresp     ),
    .ps_hp0_rlast   ( ps_hp0_rlast     ),
    .ps_hp0_rvalid  ( ps_hp0_rvalid    ),
    .ps_hp0_rready  ( ps_hp0_rready    )
`endif
  ); 
`endif

`ifdef USE_ZYNQMP
  // Εσωτερικά καλώδια UART
  logic uart_tx_o;
  logic uart_rx_i;

  zynqmp i_zynqmp (
    .saxihp0_fpd_aclk  ( ps_hp0_aclk    ),
    .saxigp2_awid      ( ps_hp0_awid    ),
    .saxigp2_awaddr    ( {17'b0, ps_hp0_awaddr} ),
    .saxigp2_awlen     ( ps_hp0_awlen   ),
    .saxigp2_awsize    ( ps_hp0_awsize  ),
    .saxigp2_awburst   ( ps_hp0_awburst ),
    .saxigp2_awlock    ( ps_hp0_awlock  ),
    .saxigp2_awcache   ( ps_hp0_awcache ),
    .saxigp2_awprot    ( ps_hp0_awprot  ),
    .saxigp2_awqos     ( ps_hp0_awqos   ),
    .saxigp2_awvalid   ( ps_hp0_awvalid ),
    .saxigp2_awready   ( ps_hp0_awready ),
    .saxigp2_wdata     ( ps_hp0_wdata   ),
    .saxigp2_wstrb     ( ps_hp0_wstrb   ),
    .saxigp2_wlast     ( ps_hp0_wlast   ),
    .saxigp2_wvalid    ( ps_hp0_wvalid  ),
    .saxigp2_wready    ( ps_hp0_wready  ),
    .saxigp2_bid       ( ps_hp0_bid     ),
    .saxigp2_bresp     ( ps_hp0_bresp   ),
    .saxigp2_bvalid    ( ps_hp0_bvalid  ),
    .saxigp2_bready    ( ps_hp0_bready  ),
    .saxigp2_arid      ( ps_hp0_arid    ),
    .saxigp2_araddr    ( {17'b0, ps_hp0_araddr} ),
    .saxigp2_arlen     ( ps_hp0_arlen   ),
    .saxigp2_arsize    ( ps_hp0_arsize  ),
    .saxigp2_arburst   ( ps_hp0_arburst ),
    .saxigp2_arlock    ( ps_hp0_arlock  ),
    .saxigp2_arcache   ( ps_hp0_arcache ),
    .saxigp2_arprot    ( ps_hp0_arprot  ),
    .saxigp2_arqos     ( ps_hp0_arqos   ),
    .saxigp2_arvalid   ( ps_hp0_arvalid ),
    .saxigp2_arready   ( ps_hp0_arready ),
    .saxigp2_rid       ( ps_hp0_rid     ),
    .saxigp2_rdata     ( ps_hp0_rdata   ),
    .saxigp2_rresp     ( ps_hp0_rresp   ),
    .saxigp2_rlast     ( ps_hp0_rlast   ),
    .saxigp2_rvalid    ( ps_hp0_rvalid  ),
    .saxigp2_rready    ( ps_hp0_rready  ),
    .emio_uart1_rxd    ( uart_tx_o      ),
    .emio_uart1_txd    ( uart_rx_i      ),
    .emio_gpio_i       ( 1'b0           ),
    .emio_gpio_o       ( ps_gpio_o      ),
    .emio_gpio_t       (                ),
    .maxihpm0_lpd_aclk ( soc_clk        )
  );
`endif
    
  // Cheshire SoC //
  //////////////////

  cheshire_soc #(
    .Cfg                ( FPGACfg ),
    .ExtHartinfo        ( '0 ),
    .axi_ext_llc_req_t  ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t  ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t  ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t  ( axi_mst_rsp_t ),
    .axi_ext_slv_req_t  ( axi_slv_req_t ),
    .axi_ext_slv_rsp_t  ( axi_slv_rsp_t ),
    .reg_ext_req_t      ( reg_req_t ),
    .reg_ext_rsp_t      ( reg_rsp_t )
  ) i_cheshire_soc (
    .clk_i              ( soc_clk ),
    .rst_ni             ( rst_n   ),
    .test_mode_i        ( test_mode_i ),
    .boot_mode_i        ( boot_mode   ),
    .rtc_i              ( rtc_clk_q       ),
    .axi_llc_mst_req_o  ( axi_llc_mst_req ),
    .axi_llc_mst_rsp_i  ( axi_llc_mst_rsp ),
    .axi_ext_mst_req_i  ( '0 ),
    .axi_ext_mst_rsp_o  ( ),
    .axi_ext_slv_req_o  ( ),
    .axi_ext_slv_rsp_i  ( '0 ),
    .reg_ext_slv_req_o  ( ),
    .reg_ext_slv_rsp_i  ( '0 ),
    .intr_ext_i         ( '0 ),
    .intr_ext_o         ( ),
    .xeip_ext_o         ( ),
    .mtip_ext_o         ( ),
    .msip_ext_o         ( ),
    .dbg_active_o       ( ),
    .dbg_ext_req_o      ( ),
    .dbg_ext_unavail_i  ( '0 ),
    .slink_rcv_clk_i    ( 1'b1 ),
    .slink_rcv_clk_o    ( ),
    .slink_i            ( '0 ),
    .slink_o            ( ),
`ifdef USE_JTAG
    .jtag_tck_i,
    .jtag_trst_ni,
    .jtag_tms_i,
    .jtag_tdi_i,
    .jtag_tdo_o,
    // TODO: connect to the tdo pad
    .jtag_tdo_oe_o      ( ),
`endif
    .i2c_sda_o          ( i2c_sda_soc_out ),
    .i2c_sda_i          ( i2c_sda_soc_in  ),
    .i2c_sda_en_o       ( i2c_sda_en      ),
    .i2c_scl_o          ( i2c_scl_soc_out ),
    .i2c_scl_i          ( i2c_scl_soc_in  ),
    .i2c_scl_en_o       ( i2c_scl_en      ),
    .spih_sck_o         ( spi_sck_soc     ),
    .spih_sck_en_o      ( spi_sck_en      ),
    .spih_csb_o         ( spi_cs_soc      ),
    .spih_csb_en_o      ( spi_cs_en       ),
    .spih_sd_o          ( spi_sd_soc_out  ),
    .spih_sd_en_o       ( spi_sd_en       ),
    .spih_sd_i          ( spi_sd_soc_in   ),
`ifdef USE_VGA
    .vga_hsync_o,
    .vga_vsync_o,
    .vga_red_o,
    .vga_green_o,
    .vga_blue_o,
`endif
    .uart_tx_o,
    .uart_rx_i,
    .usb_clk_i          ( usb_clk ),
    .usb_rst_ni         ( rst_n ), // Technically should sync to `usb_clk`, but pulse is long enough
    .usb_dm_i,
    .usb_dm_o,
    .usb_dm_oe_o,
    .usb_dp_i,
    .usb_dp_o,
    .usb_dp_oe_o
  );

  // ILA-DEBUG: the UART TX probes were removed -- that question is settled
  // (Cheshire transmits; PS UART1 is on MIO, not EMIO). See AGENT_NOTES §11.4.

endmodule
