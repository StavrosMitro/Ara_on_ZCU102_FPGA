// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Cyril Koenig <cykoenig@iis.ee.ethz.ch>
// Paul Scheffler <paulsc@iis.ee.ethz.ch>
//
// Resize AXI AW, IW, and DW before connecting to a Xilinx DRAM controller.

`include "cheshire/typedef.svh"
`include "phy_definitions.svh"
`include "common_cells/registers.svh"

module dram_wrapper_xilinx #(
  parameter type axi_soc_aw_chan_t = logic,
  parameter type axi_soc_w_chan_t  = logic,
  parameter type axi_soc_b_chan_t  = logic,
  parameter type axi_soc_ar_chan_t = logic,
  parameter type axi_soc_r_chan_t  = logic,
  parameter type axi_soc_req_t     = logic,
  parameter type axi_soc_resp_t    = logic
) (
  // System reset
  input  logic  sys_rst_i,
  input  logic  dram_clk_i,
  // Controller reset
  input  logic  soc_resetn_i,
  input  logic  soc_clk_i,
  // PHY interfaces
`ifdef USE_DDR4
  `DDR4_INTF
`endif
`ifdef USE_DDR3
  `DDR3_INTF
`endif
`ifdef USE_ZYNQMP
  `ZYNQMP_HP0_MST_INTF
`endif
  // DRAM AXI interface
  input  axi_soc_req_t  soc_req_i,
  output axi_soc_resp_t soc_rsp_o
);

  //////////////////////////////////////
  //  Configurations and definitions  //
  //////////////////////////////////////

  typedef struct packed {
    bit     EnCdc;
    integer CdcLogDepth;
    integer IdWidth;
    integer AddrWidth;
    integer DataWidth;
    integer StrobeWidth;
    integer MaxUniqIds;
    integer MaxTxns;
    integer MaxReads;
  } dram_cfg_t;

`ifdef TARGET_VCU128
  localparam dram_cfg_t cfg = '{
    EnCdc         : 1,    // 333 MHz AXI (cf. CdcLogDepth)
    CdcLogDepth   : 5,
    IdWidth       : 8,
    AddrWidth     : 32,
    DataWidth     : 512,
    StrobeWidth   : 64,
    MaxUniqIds    : 8,    // TODO: suboptimal, but limited by CVA6/LLC
    MaxTxns       : 24,   // TODO: suboptimal, but limited by CVA6/LLC
    MaxReads      : 24    // unchanged from MaxTxns: preserve existing behaviour
  };
`endif

`ifdef TARGET_GENESYS2
  localparam dram_cfg_t cfg = '{
    EnCdc         : 1,    // 200 MHz AXI (cf. CCdcLogDepth)
    CdcLogDepth   : 5,
    IdWidth       : 4,    // Fixed
    AddrWidth     : 30,
    DataWidth     : 64,
    StrobeWidth   : 8,
    MaxUniqIds    : 8,    // TODO: suboptimal, but limited by CVA6/LLC
    MaxTxns       : 24,   // TODO: suboptimal, but limited by CVA6/LLC
    MaxReads      : 24    // unchanged from MaxTxns: preserve existing behaviour
  };
`endif

`ifdef TARGET_ZCU102
  localparam dram_cfg_t cfg = '{
    // Same clock as HP0, but enable the CDC anyway: with EnCdc=0 the
    // iw_converter master port was wired combinationally to the PS HP0 pins --
    // the only target with zero buffering/registering at the DRAM boundary,
    // and the only one that wedges under back-to-back write bursts (fmatmul
    // vector kernel; test_deep_combo scalar stores). With EnCdc=1 the CDC
    // degenerates to a 32-deep FIFO per AXI channel and registers the
    // boundary, matching the working VCU128/Genesys2 structure. axi_cdc is
    // safe with src_clk == dst_clk (dram_axi_clk = soc_clk_i below).
    EnCdc         : 1,
    CdcLogDepth   : 5,    // 32-deep per channel, as on VCU128/Genesys2
    IdWidth       : 6,    // PS HP0 supports 6-bit AXI IDs
    AddrWidth     : 32,   // addr of ara
    DataWidth     : 128,  // data width PS HP0 port
    StrobeWidth   : 16,   // 128 / 8 = 16
    MaxUniqIds    : 32,
    MaxTxns       : 48,   // total txns (reads+writes) -> axi_iw_converter; unchanged
    // Outstanding READS only -> axi_dw_converter.AxiMaxReads, which replicates
    // R/AR registers, arbiters, comparators and upsizer FSMs *linearly* (38k
    // LUTs at 48 = ~14% of the device). Writes do NOT consume these: the W path
    // is a single FSM (w_state_q), since AXI requires W in AW order -- there is
    // no AxiMaxWrites parameter at all.
    // Ceiling = AxiMaxSlvTrans/AxiMaxMstTrans = 24 (crossbar); nothing can put
    // more than 24 reads into this path. NB: Cfg.LlcMaxReadTxns=16 is NOT a
    // bound here -- it parameterises i_llc_atomics (the atomics shim in front
    // of the LLC, cheshire_soc.sv:458), not the LLC master port.
    // 24 also matches VCU128/Genesys2 and is the ceiling the LLC deadlock fix
    // was validated against. Kept separate from MaxTxns so the deadlock-
    // sensitive iw_converter (which counts reads+writes) retains its value.
    // CAUTION: if LlcNotBypass ever goes to 0 (LLC bypassed), traffic reaches
    // this port straight from the crossbar with no LLC coalescing -- revisit
    // this and the iw_converter limits together before doing that.
    MaxReads      : 24
  };
`endif

  localparam SocDataWidth = $bits(soc_req_i.w.data);
  localparam SocIdWidth   = $bits(soc_req_i.ar.id);
  localparam SocUserWidth = $bits(soc_req_i.ar.user);
  localparam SocAddrWidth = $bits(soc_req_i.ar.addr);

  // Define type after data width and address resizer
  `AXI_TYPEDEF_ALL(axi_dw, logic[SocAddrWidth-1:0], logic[SocIdWidth-1:0],
                   logic[cfg.DataWidth-1:0], logic[cfg.StrobeWidth-1:0],
                   logic[SocUserWidth-1:0])

  // Define type after data & id width resizers
  `AXI_TYPEDEF_ALL(axi_dw_iw, logic[SocAddrWidth-1:0], logic[cfg.IdWidth-1:0],
                   logic[cfg.DataWidth-1:0], logic[cfg.StrobeWidth-1:0],
                   logic[SocUserWidth-1:0])

  // Clock on which is clocked the DRAM AXI
  logic dram_axi_clk;
  logic dram_rst_o;

  // Signals before resizing
  axi_soc_req_t  soc_dresizer_req;
  axi_soc_resp_t soc_dresizer_rsp;

  // Signals after data width resizing
  axi_dw_req_t  dresizer_iresizer_req;
  axi_dw_resp_t dresizer_iresizer_rsp;

  // Signals after id width resizing
  axi_dw_iw_req_t  iresizer_cdc_req, cdc_dram_req;
  axi_dw_iw_resp_t iresizer_cdc_rsp, cdc_dram_rsp;

  // Entry signals
  assign soc_dresizer_req = soc_req_i;
  assign soc_rsp_o = soc_dresizer_rsp;

  ////////////////////
  //  DW converter  //
  ////////////////////

  axi_dw_converter #(
    .AxiMaxReads          ( cfg.MaxReads  ),
    .AxiSlvPortDataWidth  ( SocDataWidth  ),
    .AxiMstPortDataWidth  ( cfg.DataWidth ),
    .AxiAddrWidth         ( SocAddrWidth  ),
    .AxiIdWidth           ( SocIdWidth    ),
    // Common AW, AR, B
    .aw_chan_t            ( axi_soc_aw_chan_t ),
    .b_chan_t             ( axi_soc_b_chan_t  ),
    .ar_chan_t            ( axi_soc_ar_chan_t ),
    // Manager W, R
    .mst_w_chan_t         ( axi_dw_w_chan_t ),
    .mst_r_chan_t         ( axi_dw_r_chan_t ),
    .axi_mst_req_t        ( axi_dw_req_t    ),
    .axi_mst_resp_t       ( axi_dw_resp_t   ),
    // Subordinate W, R
    .slv_w_chan_t         ( axi_soc_w_chan_t ),
    .slv_r_chan_t         ( axi_soc_r_chan_t ),
    .axi_slv_req_t        ( axi_soc_req_t  ),
    .axi_slv_resp_t       ( axi_soc_resp_t )
  ) i_axi_dw_converter (
    .clk_i      ( soc_clk_i    ),
    .rst_ni     ( soc_resetn_i ),
    .slv_req_i  ( soc_dresizer_req ),
    .slv_resp_o ( soc_dresizer_rsp ),
    .mst_req_o  ( dresizer_iresizer_req ),
    .mst_resp_i ( dresizer_iresizer_rsp )
  );

  //////////////////
  //  ID resizer  //
  //////////////////

  // TODO: Implement simpler solutions
  axi_iw_converter #(
    .AxiAddrWidth           ( SocAddrWidth  ),
    .AxiDataWidth           ( cfg.DataWidth ),
    .AxiUserWidth           ( SocUserWidth  ),
    .AxiSlvPortIdWidth      ( SocIdWidth    ),
    .AxiSlvPortMaxUniqIds   ( cfg.MaxUniqIds ),
    .AxiSlvPortMaxTxnsPerId ( cfg.MaxTxns    ),
    .AxiSlvPortMaxTxns      ( cfg.MaxTxns    ),
    .AxiMstPortIdWidth      ( cfg.IdWidth    ),
    .AxiMstPortMaxUniqIds   ( cfg.MaxUniqIds ),
    .AxiMstPortMaxTxnsPerId ( cfg.MaxTxns    ),
    .slv_req_t              ( axi_dw_req_t     ),
    .slv_resp_t             ( axi_dw_resp_t    ),
    .mst_req_t              ( axi_dw_iw_req_t  ),
    .mst_resp_t             ( axi_dw_iw_resp_t )
  ) i_axi_iw_converter (
    .clk_i      ( soc_clk_i    ),
    .rst_ni     ( soc_resetn_i ),
    .slv_req_i  ( dresizer_iresizer_req ),
    .slv_resp_o ( dresizer_iresizer_rsp ),
    .mst_req_o  ( iresizer_cdc_req ),
    .mst_resp_i ( iresizer_cdc_rsp )
  );

  ////////////////////////
  //  Instiantiate CDC  //
  ////////////////////////

  if (cfg.EnCdc) begin : gen_cdc
    axi_cdc #(
      .aw_chan_t  ( axi_dw_iw_aw_chan_t),
      .w_chan_t   ( axi_dw_iw_w_chan_t),
      .b_chan_t   ( axi_dw_iw_b_chan_t),
      .ar_chan_t  ( axi_dw_iw_ar_chan_t),
      .r_chan_t   ( axi_dw_iw_r_chan_t),
      .axi_req_t  ( axi_dw_iw_req_t),
      .axi_resp_t ( axi_dw_iw_resp_t),
      .LogDepth   ( cfg.CdcLogDepth )
    ) i_axi_cdc_mig (
      .src_clk_i  ( soc_clk_i    ),
      .src_rst_ni ( soc_resetn_i ),
      .src_req_i  ( iresizer_cdc_req ),
      .src_resp_o ( iresizer_cdc_rsp ),
      .dst_clk_i  ( dram_axi_clk ),
      .dst_rst_ni ( ~dram_rst_o  ),
      .dst_req_o  ( cdc_dram_req ),
      .dst_resp_i ( cdc_dram_rsp )
    );
  end else begin : gen_no_cdc
    assign cdc_dram_req     = iresizer_cdc_req;
    assign iresizer_cdc_rsp = cdc_dram_rsp;
  end

`ifdef PROBE_DDR  // build knob: make ... probes=ddr   (cheshire: deps/ara/cheshire/Makefile)
  ///////////////////////////////////////////////////////////////////////////
  //  ILA PROBES -- point H: input of i_axi_cdc_mig, soc_clk domain.       //
  //  Between L3 (LLC master port) and the PS:                             //
  //    L3 -> H        dw upsizer + iw converter (PL, soc_clk cycles)      //
  //    H AR -> R_LAST CDC + HP0 port + PS interconnect + DDRC + DRAM      //
  //  Same 5 signals and names as every round-4 AXI point, so ila_decode.py //
  //  pairs them the same way. soc_clk domain even when hp0_mhz= moves    //
  //  the DRAM side of the CDC, so the one soc_clk ILA can sample it.      //
  ///////////////////////////////////////////////////////////////////////////
  (* mark_debug = "true" *) logic dbg_h_arv, dbg_h_arr, dbg_h_rv, dbg_h_rr, dbg_h_rl;
  assign dbg_h_arv = iresizer_cdc_req.ar_valid;
  assign dbg_h_arr = iresizer_cdc_rsp.ar_ready;
  assign dbg_h_rv  = iresizer_cdc_rsp.r_valid;
  assign dbg_h_rr  = iresizer_cdc_req.r_ready;
  assign dbg_h_rl  = iresizer_cdc_rsp.r.last;
`endif // PROBE_DDR

  ////////////////////////////////
  //  Map User, Resize Address  //
  ////////////////////////////////

  assign cdc_dram_rsp.b.user = '0;
  assign cdc_dram_rsp.r.user = '0;

  logic [cfg.AddrWidth-1:0] cdc_dram_req_aw_addr;
  logic [cfg.AddrWidth-1:0] cdc_dram_req_ar_addr;

  assign cdc_dram_req_aw_addr = cdc_dram_req.aw.addr[cfg.AddrWidth-1:0];
  assign cdc_dram_req_ar_addr = cdc_dram_req.ar.addr[cfg.AddrWidth-1:0];

  /////////////////////////
  //  Instiantiate DDR4  //
  /////////////////////////

`ifdef USE_DDR4
  ddr4 i_dram (
    // Reset
    .sys_rst                    ( sys_rst_i    ),  // Active high
    .c0_sys_clk_i               ( dram_clk_i   ),
    .c0_ddr4_aresetn            ( soc_resetn_i ),
    // Clock and reset out
    .c0_ddr4_ui_clk             ( dram_axi_clk ),
    .c0_ddr4_ui_clk_sync_rst    ( dram_rst_o   ),
    // AXI
    .c0_ddr4_s_axi_awid         ( cdc_dram_req.aw.id    ),
    .c0_ddr4_s_axi_awaddr       ( cdc_dram_req_aw_addr  ),
    .c0_ddr4_s_axi_awlen        ( cdc_dram_req.aw.len   ),
    .c0_ddr4_s_axi_awsize       ( cdc_dram_req.aw.size  ),
    .c0_ddr4_s_axi_awburst      ( cdc_dram_req.aw.burst ),
    .c0_ddr4_s_axi_awlock       ( cdc_dram_req.aw.lock  ),
    .c0_ddr4_s_axi_awcache      ( cdc_dram_req.aw.cache ),
    .c0_ddr4_s_axi_awprot       ( cdc_dram_req.aw.prot  ),
    .c0_ddr4_s_axi_awqos        ( cdc_dram_req.aw.qos   ),
    .c0_ddr4_s_axi_awvalid      ( cdc_dram_req.aw_valid ),
    .c0_ddr4_s_axi_awready      ( cdc_dram_rsp.aw_ready ),
    .c0_ddr4_s_axi_wdata        ( cdc_dram_req.w.data   ),
    .c0_ddr4_s_axi_wstrb        ( cdc_dram_req.w.strb   ),
    .c0_ddr4_s_axi_wlast        ( cdc_dram_req.w.last   ),
    .c0_ddr4_s_axi_wvalid       ( cdc_dram_req.w_valid  ),
    .c0_ddr4_s_axi_wready       ( cdc_dram_rsp.w_ready  ),
    .c0_ddr4_s_axi_bready       ( cdc_dram_req.b_ready  ),
    .c0_ddr4_s_axi_bid          ( cdc_dram_rsp.b.id     ),
    .c0_ddr4_s_axi_bresp        ( cdc_dram_rsp.b.resp   ),
    .c0_ddr4_s_axi_bvalid       ( cdc_dram_rsp.b_valid  ),
    .c0_ddr4_s_axi_arid         ( cdc_dram_req.ar.id    ),
    .c0_ddr4_s_axi_araddr       ( cdc_dram_req_ar_addr  ),
    .c0_ddr4_s_axi_arlen        ( cdc_dram_req.ar.len   ),
    .c0_ddr4_s_axi_arsize       ( cdc_dram_req.ar.size  ),
    .c0_ddr4_s_axi_arburst      ( cdc_dram_req.ar.burst ),
    .c0_ddr4_s_axi_arlock       ( cdc_dram_req.ar.lock  ),
    .c0_ddr4_s_axi_arcache      ( cdc_dram_req.ar.cache ),
    .c0_ddr4_s_axi_arprot       ( cdc_dram_req.ar.prot  ),
    .c0_ddr4_s_axi_arqos        ( cdc_dram_req.ar.qos   ),
    .c0_ddr4_s_axi_arvalid      ( cdc_dram_req.ar_valid ),
    .c0_ddr4_s_axi_arready      ( cdc_dram_rsp.ar_ready ),
    .c0_ddr4_s_axi_rready       ( cdc_dram_req.r_ready  ),
    .c0_ddr4_s_axi_rid          ( cdc_dram_rsp.r.id     ),
    .c0_ddr4_s_axi_rdata        ( cdc_dram_rsp.r.data   ),
    .c0_ddr4_s_axi_rresp        ( cdc_dram_rsp.r.resp   ),
    .c0_ddr4_s_axi_rlast        ( cdc_dram_rsp.r.last   ),
    .c0_ddr4_s_axi_rvalid       ( cdc_dram_rsp.r_valid  ),
    // TODO: Shouldn't we map this to an external reg port?
    // AXI control
    .c0_ddr4_s_axi_ctrl_awvalid ( '0 ),
    .c0_ddr4_s_axi_ctrl_awready ( ),
    .c0_ddr4_s_axi_ctrl_awaddr  ( '0 ),
    .c0_ddr4_s_axi_ctrl_wvalid  ( '0 ),
    .c0_ddr4_s_axi_ctrl_wready  ( ),
    .c0_ddr4_s_axi_ctrl_wdata   ( '0 ),
    .c0_ddr4_s_axi_ctrl_bvalid  ( ),
    .c0_ddr4_s_axi_ctrl_bready  ( '0 ),
    .c0_ddr4_s_axi_ctrl_bresp   ( ),
    .c0_ddr4_s_axi_ctrl_arvalid ( '0 ),
    .c0_ddr4_s_axi_ctrl_arready ( ),
    .c0_ddr4_s_axi_ctrl_araddr  ( '0 ),
    .c0_ddr4_s_axi_ctrl_rvalid  ( ),
    .c0_ddr4_s_axi_ctrl_rready  ( '0 ),
    .c0_ddr4_s_axi_ctrl_rdata   ( ),
    .c0_ddr4_s_axi_ctrl_rresp   ( ),
    .c0_ddr4_interrupt          ( ),
    // Others
    .c0_init_calib_complete     ( ),
    .addn_ui_clkout1            ( dram_clk_o ),
    .dbg_clk                    ( ),
    .dbg_bus                    ( ),
    // PHY
    .*
  );
`endif

  /////////////////////////
  //  Instiantiate DDR3  //
  /////////////////////////

`ifdef USE_DDR3
  mig7s i_dram (
    .sys_rst              ( sys_rst_i    ), // Active high
    .sys_clk_i            ( dram_clk_i   ),
    .ui_clk               ( dram_axi_clk ),
    .ui_clk_sync_rst      ( dram_rst_o ),
    .mmcm_locked          ( ),
    .app_sr_req           ( '0 ),
    .app_ref_req          ( '0 ),
    .app_zq_req           ( '0 ),
    .app_sr_active        ( ),
    .app_ref_ack          ( ),
    .app_zq_ack           ( ),
    .aresetn              ( soc_resetn_i ),
    .s_axi_awid           ( cdc_dram_req.aw.id    ),
    .s_axi_awaddr         ( cdc_dram_req_aw_addr  ),
    .s_axi_awlen          ( cdc_dram_req.aw.len   ),
    .s_axi_awsize         ( cdc_dram_req.aw.size  ),
    .s_axi_awburst        ( cdc_dram_req.aw.burst ),
    .s_axi_awlock         ( cdc_dram_req.aw.lock  ),
    .s_axi_awcache        ( cdc_dram_req.aw.cache ),
    .s_axi_awprot         ( cdc_dram_req.aw.prot  ),
    .s_axi_awqos          ( cdc_dram_req.aw.qos   ),
    .s_axi_awvalid        ( cdc_dram_req.aw_valid ),
    .s_axi_awready        ( cdc_dram_rsp.aw_ready ),
    .s_axi_wdata          ( cdc_dram_req.w.data   ),
    .s_axi_wstrb          ( cdc_dram_req.w.strb   ),
    .s_axi_wlast          ( cdc_dram_req.w.last   ),
    .s_axi_wvalid         ( cdc_dram_req.w_valid  ),
    .s_axi_wready         ( cdc_dram_rsp.w_ready  ),
    .s_axi_bready         ( cdc_dram_req.b_ready  ),
    .s_axi_bid            ( cdc_dram_rsp.b.id     ),
    .s_axi_bresp          ( cdc_dram_rsp.b.resp   ),
    .s_axi_bvalid         ( cdc_dram_rsp.b_valid  ),
    .s_axi_arid           ( cdc_dram_req.ar.id    ),
    .s_axi_araddr         ( cdc_dram_req_ar_addr  ),
    .s_axi_arlen          ( cdc_dram_req.ar.len   ),
    .s_axi_arsize         ( cdc_dram_req.ar.size  ),
    .s_axi_arburst        ( cdc_dram_req.ar.burst ),
    .s_axi_arlock         ( cdc_dram_req.ar.lock  ),
    .s_axi_arcache        ( cdc_dram_req.ar.cache ),
    .s_axi_arprot         ( cdc_dram_req.ar.prot  ),
    .s_axi_arqos          ( cdc_dram_req.ar.qos   ),
    .s_axi_arvalid        ( cdc_dram_req.ar_valid ),
    .s_axi_arready        ( cdc_dram_rsp.ar_ready ),
    .s_axi_rready         ( cdc_dram_req.r_ready  ),
    .s_axi_rid            ( cdc_dram_rsp.r.id     ),
    .s_axi_rdata          ( cdc_dram_rsp.r.data   ),
    .s_axi_rresp          ( cdc_dram_rsp.r.resp   ),
    .s_axi_rlast          ( cdc_dram_rsp.r.last   ),
    .s_axi_rvalid         ( cdc_dram_rsp.r_valid  ),
    .init_calib_complete  ( ),
    .device_temp          ( ),
    // PHY
    .*
  );
`endif  // USE_DDR3


`ifdef USE_ZYNQMP

//inside clock on system connected
`ifdef HP0_MHZ
  // Clock knob hp0_mhz=<f>: HP0 and the DRAM side of i_axi_cdc_mig run on
  // hp0_clk (passed in as dram_clk_i, unused otherwise on ZynqMP). soc_clk and
  // hp0_clk come from the same MMCM, so Vivado times the CDC and the reset
  // below as related clocks, stricter than the async FIFO needs.
  assign dram_axi_clk = dram_clk_i;
  assign dram_rst_o   = ~soc_resetn_i;

  assign ps_hp0_aclk    = dram_clk_i;
`else
  assign dram_axi_clk = soc_clk_i;
  assign dram_rst_o   = ~soc_resetn_i;

  assign ps_hp0_aclk    = soc_clk_i;
`endif

  assign ps_hp0_awid    = cdc_dram_req.aw.id;
  assign ps_hp0_awaddr  = cdc_dram_req_aw_addr;
  assign ps_hp0_awlen   = cdc_dram_req.aw.len;
  assign ps_hp0_awsize  = cdc_dram_req.aw.size;
  assign ps_hp0_awburst = cdc_dram_req.aw.burst;
  assign ps_hp0_awlock  = cdc_dram_req.aw.lock;
  assign ps_hp0_awcache = cdc_dram_req.aw.cache;
  assign ps_hp0_awprot  = cdc_dram_req.aw.prot;
  assign ps_hp0_awqos   = cdc_dram_req.aw.qos;
  assign ps_hp0_awvalid = cdc_dram_req.aw_valid;
  assign cdc_dram_rsp.aw_ready = ps_hp0_awready;

  // ---(Write Data) ---
  assign ps_hp0_wdata   = cdc_dram_req.w.data;
  assign ps_hp0_wstrb   = cdc_dram_req.w.strb;
  assign ps_hp0_wlast   = cdc_dram_req.w.last;
  assign ps_hp0_wvalid  = cdc_dram_req.w_valid;
  assign cdc_dram_rsp.w_ready = ps_hp0_wready;

  // --- (Write Response) ---
  assign cdc_dram_rsp.b.id    = ps_hp0_bid;
  assign cdc_dram_rsp.b.resp  = ps_hp0_bresp;
  assign cdc_dram_rsp.b_valid = ps_hp0_bvalid;
  assign ps_hp0_bready        = cdc_dram_req.b_ready;

  // --- (Read Address) ---
  assign ps_hp0_arid    = cdc_dram_req.ar.id;
  assign ps_hp0_araddr  = cdc_dram_req_ar_addr;
  assign ps_hp0_arlen   = cdc_dram_req.ar.len;
  assign ps_hp0_arsize  = cdc_dram_req.ar.size;
  assign ps_hp0_arburst = cdc_dram_req.ar.burst;
  assign ps_hp0_arlock  = cdc_dram_req.ar.lock;
  assign ps_hp0_arcache = cdc_dram_req.ar.cache;
  assign ps_hp0_arprot  = cdc_dram_req.ar.prot;
  assign ps_hp0_arqos   = cdc_dram_req.ar.qos;
  assign ps_hp0_arvalid = cdc_dram_req.ar_valid;
  assign cdc_dram_rsp.ar_ready = ps_hp0_arready;

  // --- (Read Data) ---
  assign cdc_dram_rsp.r.id    = ps_hp0_rid;
  assign cdc_dram_rsp.r.data  = ps_hp0_rdata;
  assign cdc_dram_rsp.r.resp  = ps_hp0_rresp;
  assign cdc_dram_rsp.r.last  = ps_hp0_rlast;
  assign cdc_dram_rsp.r_valid = ps_hp0_rvalid;
  assign ps_hp0_rready        = cdc_dram_req.r_ready;
`endif  // USE_ZYNQMP

endmodule
