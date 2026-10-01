//============================================================
// File        : dma_ext_coverage_sv.sv
// Description : Extended Feature Coverage (bound to DUT)
//============================================================
// INTERVIEW POINTS:
//   1. Two covergroups:
//        cg_dma_protocol (physical pins)
//        cg_dma_extended (internal state via extra ports)
//   2. Also uses SVA `cover property` for sequence coverage.
//   3. A non-UVM helper class (dma_ext_coverage_c) owns the
//      covergroups — sampled on `negedge CLK` to avoid races
//      with the DUT.
//   4. FIX R5: per-channel buffer-full and rollover covers.
//============================================================

`ifndef DMA_EXT_COVERAGE_SV
`define DMA_EXT_COVERAGE_SV

//============================================================
// COVERAGE CLASS — owns both covergroups
//============================================================
class dma_ext_coverage_c;

    virtual dma_if vif;

    // Internal state snapshots (updated from bind module)
    logic [3:0]  state_q;
    logic        xfer_q;
    logic [1:0]  active_q;
    logic [1:0]  rr_q;

    //============================================================
    // PROTOCOL COVERGROUP — physical pins
    //============================================================
    covergroup cg_dma_protocol @(posedge vif.CLK);
        option.per_instance = 1;
        option.name         = "cg_dma_protocol";

        cp_dreq : coverpoint vif.DREQ {
            bins none       = {4'b0000};
            bins ch0        = {4'b0001};
            bins ch1        = {4'b0010};
            bins ch2        = {4'b0100};
            bins ch3        = {4'b1000};
            bins pair_01    = {4'b0011};
            bins pair_02    = {4'b0101};
            bins pair_03    = {4'b1001};
            bins pair_12    = {4'b0110};
            bins pair_13    = {4'b1010};
            bins pair_23    = {4'b1100};
            bins triple_012 = {4'b0111};
            bins triple_013 = {4'b1011};
            bins triple_023 = {4'b1101};
            bins triple_123 = {4'b1110};
            bins all_4      = {4'b1111};
        }

        cp_dack : coverpoint vif.DACK {
            bins none = {4'b0000};
            bins ch0  = {4'b0001};
            bins ch1  = {4'b0010};
            bins ch2  = {4'b0100};
            bins ch3  = {4'b1000};
        }

        cp_hrq  : coverpoint vif.HRQ  { bins low = {1'b0}; bins high = {1'b1}; }
        cp_hlda : coverpoint vif.HLDA { bins low = {1'b0}; bins high = {1'b1}; }
        cp_aen  : coverpoint vif.AEN  { bins low = {1'b0}; bins high = {1'b1}; }
        cp_eop_n: coverpoint vif.EOP_N{ bins active = {1'b0}; bins inactive = {1'b1}; }

        x_dreq_dack    : cross cp_dreq, cp_dack;
        x_hrq_hlda_aen : cross cp_hrq, cp_hlda, cp_aen;
    endgroup

    //============================================================
    // EXTENDED COVERGROUP — internal state + status
    //============================================================
    covergroup cg_dma_extended @(posedge vif.CLK);
        option.per_instance = 1;
        option.name         = "cg_dma_extended";

        cp_xfer_pulse : coverpoint xfer_q {
            bins no = {1'b0}; bins yes = {1'b1};
        }

        cp_active_ch : coverpoint active_q {
            bins ch0 = {2'd0}; bins ch1 = {2'd1};
            bins ch2 = {2'd2}; bins ch3 = {2'd3};
        }

        // FSM state encoding coverage
        cp_state : coverpoint state_q {
            bins idle     = {4'b0000};
            bins request  = {4'b0001};
            bins address  = {4'b0010};
            bins read     = {4'b0011};
            bins write    = {4'b0100};
            bins complete = {4'b0101};
            bins burst    = {4'b0110};
            bins error    = {4'b0111};
            bins rollover = {4'b1000};
            bins waite    = {4'b1001};   // NOTE: typo — "wait"
        }

        cp_rollover : coverpoint vif.rollover_status {
            bins none  = {4'b0000};
            bins ch0   = {4'b0001};
            bins ch1   = {4'b0010};
            bins ch2   = {4'b0100};
            bins ch3   = {4'b1000};
            bins multi = {[4'b0011 : 4'b1110]};
        }

        cp_watermark : coverpoint vif.watermark_reached {
            bins no = {1'b0}; bins yes = {1'b1};
        }

        //--------------------------------------------------
        // FIX R5: Per-channel buffer-full coverpoints
        //--------------------------------------------------
        cp_buf_full_ch0 : coverpoint
            (vif.buffer_used_0 == vif.BUF_SIZE_REG_0 && vif.BUF_SIZE_REG_0 != 0) {
            bins not_full = {1'b0}; bins full = {1'b1};
        }
        cp_buf_full_ch1 : coverpoint
            (vif.buffer_used_1 == vif.BUF_SIZE_REG_1 && vif.BUF_SIZE_REG_1 != 0) {
            bins not_full = {1'b0}; bins full = {1'b1};
        }
        cp_buf_full_ch2 : coverpoint
            (vif.buffer_used_2 == vif.BUF_SIZE_REG_2 && vif.BUF_SIZE_REG_2 != 0) {
            bins not_full = {1'b0}; bins full = {1'b1};
        }
        cp_buf_full_ch3 : coverpoint
            (vif.buffer_used_3 == vif.BUF_SIZE_REG_3 && vif.BUF_SIZE_REG_3 != 0) {
            bins not_full = {1'b0}; bins full = {1'b1};
        }

        //--------------------------------------------------
        // FIX R5: Per-channel watermark activity
        //--------------------------------------------------
        cp_wm_ch0 : coverpoint (vif.buffer_used_0 >= 1) {
            bins no = {1'b0}; bins yes = {1'b1};
        }
        cp_wm_ch1 : coverpoint (vif.buffer_used_1 >= 1) {
            bins no = {1'b0}; bins yes = {1'b1};
        }
        cp_wm_ch2 : coverpoint (vif.buffer_used_2 >= 1) {
            bins no = {1'b0}; bins yes = {1'b1};
        }
        cp_wm_ch3 : coverpoint (vif.buffer_used_3 >= 1) {
            bins no = {1'b0}; bins yes = {1'b1};
        }

        cp_byte_ptr : coverpoint vif.byte_pointer {
            bins low = {1'b0}; bins high = {1'b1};
        }

        cp_prio_byte_ptr : coverpoint vif.priority_byte_ptr {
            bins byte0    = {2'b00};
            bins byte1    = {2'b01};
            bins byte2    = {2'b10};
            bins reserved = {2'b11};
        }

        cp_ext_status : coverpoint vif.EXT_STATUS_REG {
            bins clean               = {8'h00};
            bins overflow            = {8'h80};
            bins underflow           = {8'h40};
            bins watermark           = {8'h20};
            bins rollover            = {8'h10};
            bins combo_ovf_watermark = {8'hA0};
            bins combo_ovf_rollover  = {8'h90};
            bins others              = default;
        }

        cp_rr_mask : coverpoint rr_q {
            bins ch0 = {2'd0}; bins ch1 = {2'd1};
            bins ch2 = {2'd2}; bins ch3 = {2'd3};
        }

        x_rollover_watermark : cross cp_rollover, cp_watermark;
        x_ch_xfer            : cross cp_active_ch, cp_xfer_pulse;

        // FIX R5: channel × its own watermark
        x_ch0_wm : cross cp_active_ch, cp_wm_ch0;
        x_ch1_wm : cross cp_active_ch, cp_wm_ch1;
        x_ch2_wm : cross cp_active_ch, cp_wm_ch2;
        x_ch3_wm : cross cp_active_ch, cp_wm_ch3;
    endgroup

    //============================================================
    // CONSTRUCTOR
    //============================================================
    function new(virtual dma_if v);
        vif = v;
        cg_dma_protocol = new();
        cg_dma_extended = new();
    endfunction

    //------------------------------------------------------------
    // Snapshot internal signals (called on negedge from bind)
    //------------------------------------------------------------
    function void update_signals(logic [3:0] st,
                                 logic       xp,
                                 logic [1:0] ac,
                                 logic [1:0] rr);
        state_q  = st;
        xfer_q   = xp;
        active_q = ac;
        rr_q     = rr;
    endfunction

    //------------------------------------------------------------
    // Print coverage summary at end
    //------------------------------------------------------------
    function void print_coverage();
        real proto_cov = cg_dma_protocol.get_inst_coverage();
        real ext_cov   = cg_dma_extended.get_inst_coverage();
        $display("==================================================");
        $display("      DMA EXTENDED COVERAGE SUMMARY                ");
        $display("==================================================");
        $display("  cg_dma_protocol : %6.2f%%", proto_cov);
        $display("  cg_dma_extended : %6.2f%%", ext_cov);
        $display("  Overall         : %6.2f%%", (proto_cov + ext_cov) / 2.0);
        $display("==================================================");
    endfunction

endclass

//============================================================
// BIND TARGET MODULE
//============================================================
// Bound into the DUT via `bind` in dma_tb_top.sv. Provides
// access to internal state via extra ports, and hosts the
// coverage class + SVA cover properties.
//------------------------------------------------------------
module dma_ext_coverage_sv(
    dma_if dif,
    input logic [3:0] state_ext,        // DMA_CONTROL.state
    input logic       xfer_pulse_ext,   // DMA_CONTROL.xfer_pulse
    input logic [1:0] active_ch_ext,    // cif.active_chnum
    input logic [1:0] rr_mask_ext       // ADAPTIVE_ARB.rr_mask
);

    default clocking cb @(posedge dif.CLK); endclocking
    default disable iff (dif.RESET);

    //============================================================
    // SVA COVER PROPERTIES
    //============================================================
    // Cover properties prove that specific temporal patterns
    // are exercised (not "must hold" like assertions).
    //------------------------------------------------------------

    cover property ( $fell(dif.RESET) );

    // Programming cycle patterns
    cover property ( !dif.CS_N && !dif.IOW_N && dif.IOR_N );
    cover property ( !dif.CS_N && !dif.IOR_N && dif.IOW_N );

    // Handshake progression
    cover property ( dif.DREQ != 4'b0000 );
    cover property ( $rose(dif.HRQ) );
    cover property ( $rose(dif.HLDA) );
    cover property ( $rose(dif.AEN) );
    cover property ( $rose(dif.ADSTB) );

    // Write-transfer direction (MEMR + IOW)
    cover property ( !dif.MEMR_N && !dif.IOW_N );
    // Read-transfer direction (IOR + MEMW)
    cover property ( !dif.IOR_N && !dif.MEMW_N );
    cover property ( $fell(dif.EOP_N) );

    // Full handshake sequence: DREQ → HRQ → HLDA → AEN
    cover property (
        (dif.DREQ != 0)
        ##[1:20] dif.HRQ
        ##[1:20] dif.HLDA
        ##[1:10] dif.AEN
    );

    // Full write transfer: DREQ → HRQ → HLDA → MEMR+IOW → EOP
    cover property (
        (dif.DREQ != 0)
        ##[1:20] dif.HRQ
        ##[1:20] dif.HLDA
        ##[1:10] (!dif.MEMR_N && !dif.IOW_N)
        ##[1:20] !dif.EOP_N
    );

    // Full read transfer: DREQ → HRQ → HLDA → IOR+MEMW → EOP
    cover property (
        (dif.DREQ != 0)
        ##[1:20] dif.HRQ
        ##[1:20] dif.HLDA
        ##[1:10] (!dif.IOR_N && !dif.MEMW_N)
        ##[1:20] !dif.EOP_N
    );

    cover property ( xfer_pulse_ext );
    cover property ( $rose(dif.rollover_any) );
    cover property ( dif.watermark_reached );
    cover property ( dif.EXT_STATUS_REG[7] );   // overflow
    cover property ( dif.EXT_STATUS_REG[6] );   // underflow
    cover property ( dif.MASTER_CLEAR_CMD );

    //------------------------------------------------------------
    // FIX R5: Per-channel buffer-full covers
    //------------------------------------------------------------
    cover property ( dif.buffer_used_0 == dif.BUF_SIZE_REG_0 && dif.BUF_SIZE_REG_0 != 0 );
    cover property ( dif.buffer_used_1 == dif.BUF_SIZE_REG_1 && dif.BUF_SIZE_REG_1 != 0 );
    cover property ( dif.buffer_used_2 == dif.BUF_SIZE_REG_2 && dif.BUF_SIZE_REG_2 != 0 );
    cover property ( dif.buffer_used_3 == dif.BUF_SIZE_REG_3 && dif.BUF_SIZE_REG_3 != 0 );

    //------------------------------------------------------------
    // FIX R5: Per-channel rollover covers
    //------------------------------------------------------------
    cover property ( $rose(dif.rollover_status[0]) );
    cover property ( $rose(dif.rollover_status[1]) );
    cover property ( $rose(dif.rollover_status[2]) );
    cover property ( $rose(dif.rollover_status[3]) );

    //------------------------------------------------------------
    // FIX R5: Per-channel watermark-hit covers
    //------------------------------------------------------------
    cover property ( dif.buffer_used_0 >= 1 );
    cover property ( dif.buffer_used_1 >= 1 );
    cover property ( dif.buffer_used_2 >= 1 );
    cover property ( dif.buffer_used_3 >= 1 );

    // Byte pointer state
    cover property ( dif.byte_pointer == 1'b0 );
    cover property ( dif.byte_pointer == 1'b1 );

    //============================================================
    // COVERAGE CLASS INSTANTIATION
    //============================================================
    dma_ext_coverage_c cov_inst;

    initial cov_inst = new(dif);

    // Sample internal signals on negedge (avoids race with DUT)
    always @(negedge dif.CLK) begin
        if (cov_inst != null)
            cov_inst.update_signals(state_ext, xfer_pulse_ext,
                                    active_ch_ext, rr_mask_ext);
    end

    // Print summary at simulation end
    final begin
        if (cov_inst != null)
            cov_inst.print_coverage();
    end

endmodule

`endif // DMA_EXT_COVERAGE_SV
