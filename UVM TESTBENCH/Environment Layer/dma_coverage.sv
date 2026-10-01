//============================================================
// File        : dma_coverage.sv
// Description : UVM Subscriber Functional Coverage
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_component, uses two analysis imports
//      (`_imp_decl` macros) — one per source monitor.
//   2. Two covergroups: cpu_cg (register access), dma_cg
//      (transfer/state).
//   3. `copy()` into local handle, then `sample()` —
//      avoids races with monitor's item reuse.
//   4. FIX R5: added per-channel buffer_used and rollover
//      coverpoints + crosses so CH1-CH3 activity is visible.
//   5. report_phase prints coverage summary.
//============================================================

`ifndef DMA_COVERAGE_SV
`define DMA_COVERAGE_SV

// Two suffixed analysis imports for two input item types
`uvm_analysis_imp_decl(cov_cpu)
`uvm_analysis_imp_decl(cov_dma)

class dma_coverage extends uvm_component;

    //------------------------------------------------------------
    // Analysis import ports (write_cov_cpu / write_cov_dma)
    //------------------------------------------------------------
    uvm_analysis_imp_cpu #(cpu_seq_item, dma_coverage) cpu_export;
    uvm_analysis_imp_dma #(dma_seq_item, dma_coverage) dma_export;

    // Local copies (sampled into covergroups)
    cpu_seq_item cpu_tx;
    dma_seq_item dma_tx;

    real cpu_coverage_pct;
    real dma_coverage_pct;

    //============================================================
    // CPU COVERGROUP — register access
    //============================================================
    covergroup cpu_cg;
        option.per_instance = 1;
        option.name         = "CPU_REGISTER_COVERAGE";

        //--------------------------------------------------
        // Address coverpoint — one bin per register
        //--------------------------------------------------
        cp_addr : coverpoint cpu_tx.addr {
            bins base_addr_ch0 = {5'h00};
            bins base_wc_ch0   = {5'h01};
            bins base_addr_ch1 = {5'h02};
            bins base_wc_ch1   = {5'h03};
            bins base_addr_ch2 = {5'h04};
            bins base_wc_ch2   = {5'h05};
            bins base_addr_ch3 = {5'h06};
            bins base_wc_ch3   = {5'h07};
            bins command       = {5'h08};   // aliased with status
            bins status        = {5'h08};
            bins request       = {5'h09};
            bins mask          = {5'h0A};
            bins mode          = {5'h0B};
            bins byte_ptr_ctrl = {5'h0C};   // aliased: clear/set
            bins master_clear  = {5'h0D};
            bins clear_mask    = {5'h0E};
            bins write_mask    = {5'h0F};   // aliased: write/read
            bins read_mask     = {5'h0F};
            bins ch_ctrl_0     = {5'h10};
            bins ch_ctrl_1     = {5'h11};
            bins ch_ctrl_2     = {5'h12};
            bins ch_ctrl_3     = {5'h13};
            bins buf_size_0    = {5'h14};
            bins buf_size_1    = {5'h15};
            bins buf_size_2    = {5'h16};
            bins buf_size_3    = {5'h17};
            bins priority_ctrl = {5'h18};
            bins ext_status    = {5'h19};
        }

        //--------------------------------------------------
        // Direction coverpoint
        //--------------------------------------------------
        cp_dir : coverpoint cpu_tx.is_read {
            bins rd = {1};
            bins wr = {0};
        }

        //--------------------------------------------------
        // Data coverpoint — edge-heavy distribution
        //--------------------------------------------------
        cp_data : coverpoint cpu_tx.data {
            bins zero     = {8'h00};
            bins all_ones = {8'hFF};
            bins ones_nib = {[8'h0F : 8'hF0]};
            bins others   = default;
        }

        // Address × direction: proves both RW paths exercised
        x_addr_dir : cross cp_addr, cp_dir;
    endgroup

    //============================================================
    // DMA COVERGROUP — transfer/state
    //============================================================
    covergroup dma_cg;
        option.per_instance = 1;
        option.name         = "DMA_TRANSFER_COVERAGE";

        //--------------------------------------------------
        // Transaction type — all enum values
        //--------------------------------------------------
        cp_tx_type : coverpoint dma_tx.tx_type {
            bins reset          = {DMA_RESET_TX};
            bins req            = {DMA_REQ_TX};
            bins grant          = {DMA_GRANT_TX};
            bins transfer       = {DMA_TRANSFER_TX};
            bins complete       = {DMA_COMPLETE_TX};
            bins master_clear   = {DMA_MASTER_CLEAR_TX};
            bins rollover       = {DMA_ROLLOVER_TX};
            bins error          = {DMA_ERROR_TX};
            bins reg_write      = {DMA_REG_WRITE_TX};
            bins reg_read       = {DMA_REG_READ_TX};
            bins idle           = {DMA_IDLE_TX};
        }

        cp_cycle : coverpoint dma_tx.cycle {
            bins idle   = {IDLE};
            bins active = {ACTIVE};
        }

        //--------------------------------------------------
        // DREQ coverpoint — one per channel + combinations
        //--------------------------------------------------
        cp_dreq : coverpoint dma_tx.dreq {
            bins none    = {4'b0000};
            bins ch0     = {4'b0001};
            bins ch1     = {4'b0010};
            bins ch2     = {4'b0100};
            bins ch3     = {4'b1000};
            bins pair[]  = {4'b0011, 4'b0101, 4'b1001,
                            4'b0110, 4'b1010, 4'b1100};
            bins all     = {4'b1111};
        }

        cp_dack : coverpoint dma_tx.dack {
            bins none = {4'b0000};
            bins ch0  = {4'b0001};
            bins ch1  = {4'b0010};
            bins ch2  = {4'b0100};
            bins ch3  = {4'b1000};
        }

        cp_chnum : coverpoint dma_tx.active_chnum {
            bins ch0 = {2'd0};
            bins ch1 = {2'd1};
            bins ch2 = {2'd2};
            bins ch3 = {2'd3};
        }

        cp_xfer : coverpoint dma_tx.xfer_pulse {
            bins no  = {0};
            bins yes = {1};
        }

        cp_eop : coverpoint dma_tx.eop_n {
            bins asserted   = {0};
            bins deasserted = {1};
        }

        //--------------------------------------------------
        // FIX R5: Per-channel rollover coverpoints
        //--------------------------------------------------
        cp_rollover_ch0 : coverpoint dma_tx.rollover_latched[0] {
            bins none = {0}; bins set = {1};
        }
        cp_rollover_ch1 : coverpoint dma_tx.rollover_latched[1] {
            bins none = {0}; bins set = {1};
        }
        cp_rollover_ch2 : coverpoint dma_tx.rollover_latched[2] {
            bins none = {0}; bins set = {1};
        }
        cp_rollover_ch3 : coverpoint dma_tx.rollover_latched[3] {
            bins none = {0}; bins set = {1};
        }

        cp_watermark : coverpoint dma_tx.watermark_reached {
            bins no  = {0};
            bins yes = {1};
        }

        //--------------------------------------------------
        // FIX R5: Per-channel buffer-used coverpoints.
        // Previously only CH0 existed → CH1-CH3 was invisible.
        //--------------------------------------------------
        cp_buf_used_0 : coverpoint dma_tx.buffer_used_0 {
            bins empty  = {16'h0000};
            bins low    = {[16'h0001 : 16'h0004]};
            bins mid    = {[16'h0005 : 16'h0010]};
            bins high   = {[16'h0011 : 16'h00FF]};
            bins full   = {16'h0100};
            bins larger = {[16'h0101 : 16'hFFFF]};
        }
        cp_buf_used_1 : coverpoint dma_tx.buffer_used_1 {
            bins empty  = {16'h0000};
            bins low    = {[16'h0001 : 16'h0004]};
            bins mid    = {[16'h0005 : 16'h0010]};
            bins high   = {[16'h0011 : 16'h00FF]};
            bins full   = {16'h0100};
            bins larger = {[16'h0101 : 16'hFFFF]};
        }
        cp_buf_used_2 : coverpoint dma_tx.buffer_used_2 {
            bins empty  = {16'h0000};
            bins low    = {[16'h0001 : 16'h0004]};
            bins mid    = {[16'h0005 : 16'h0010]};
            bins high   = {[16'h0011 : 16'h00FF]};
            bins full   = {16'h0100};
            bins larger = {[16'h0101 : 16'hFFFF]};
        }
        cp_buf_used_3 : coverpoint dma_tx.buffer_used_3 {
            bins empty  = {16'h0000};
            bins low    = {[16'h0001 : 16'h0004]};
            bins mid    = {[16'h0005 : 16'h0010]};
            bins high   = {[16'h0011 : 16'h00FF]};
            bins full   = {16'h0100};
            bins larger = {[16'h0101 : 16'hFFFF]};
        }

        //--------------------------------------------------
        // EXT_STATUS register snapshot
        //--------------------------------------------------
        cp_ext_status : coverpoint dma_tx.ext_status_reg {
            bins no_flags     = {8'h00};
            bins overflow     = {8'h80};
            bins underflow    = {8'h40};
            bins watermark    = {8'h20};
            bins rollover     = {8'h10};
            bins combo_ovf_wm = {8'hA0};
            bins combo_ovf_ro = {8'h90};
            bins others       = default;
        }

        //--------------------------------------------------
        // Crosses — combinations of interest
        //--------------------------------------------------
        x_tx_cycle  : cross cp_tx_type, cp_cycle;
        x_dreq_dack : cross cp_dreq, cp_dack;
        x_chnum_tx  : cross cp_chnum, cp_tx_type;
        x_roll_wm   : cross cp_rollover_ch0, cp_watermark;
        x_xfer_eop  : cross cp_xfer, cp_eop;

        // FIX R5: channel × its own buffer_used
        // To hit 100% on these, traffic must be exercised on
        // all four channels — no hiding behind CH0.
        x_ch0_buf : cross cp_chnum, cp_buf_used_0;
        x_ch1_buf : cross cp_chnum, cp_buf_used_1;
        x_ch2_buf : cross cp_chnum, cp_buf_used_2;
        x_ch3_buf : cross cp_chnum, cp_buf_used_3;

        // FIX R5: channel × its own rollover bit
        x_ch0_roll : cross cp_chnum, cp_rollover_ch0;
        x_ch1_roll : cross cp_chnum, cp_rollover_ch1;
        x_ch2_roll : cross cp_chnum, cp_rollover_ch2;
        x_ch3_roll : cross cp_chnum, cp_rollover_ch3;
    endgroup

    `uvm_component_utils(dma_coverage)

    function new(string name = "dma_coverage", uvm_component parent = null);
        super.new(name, parent);
        cpu_cg = new();   // covergroups must be constructed
        dma_cg = new();
        cpu_coverage_pct = 0.0;
        dma_coverage_pct = 0.0;
    endfunction

    //============================================================
    // BUILD PHASE — create imports + local handles
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cpu_export = new("cpu_export", this);
        dma_export = new("dma_export", this);
        cpu_tx = cpu_seq_item::type_id::create("cpu_tx");
        dma_tx = dma_seq_item::type_id::create("dma_tx");
    endfunction

    //============================================================
    // WRITE CPU — sample on CPU transaction
    //============================================================
    virtual function void write_cpu(cpu_seq_item t);
        cpu_tx.copy(t);   // local copy to avoid handle races
        cpu_cg.sample();
    endfunction

    //============================================================
    // WRITE DMA — sample on DMA transaction
    //============================================================
    virtual function void write_dma(dma_seq_item t);
        dma_tx.copy(t);
        dma_cg.sample();
    endfunction

    //============================================================
    // REPORT PHASE — print coverage summary
    //============================================================
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        cpu_coverage_pct = cpu_cg.get_inst_coverage();
        dma_coverage_pct = dma_cg.get_inst_coverage();

        `uvm_info("COV", "==================================================", UVM_LOW)
        `uvm_info("COV", "          DMA FUNCTIONAL COVERAGE SUMMARY         ", UVM_LOW)
        `uvm_info("COV", "==================================================", UVM_LOW)
        `uvm_info("COV",
            $sformatf("  CPU Register Coverage : %6.2f%%", cpu_coverage_pct),
            UVM_LOW)
        `uvm_info("COV",
            $sformatf("  DMA Transfer Coverage : %6.2f%%", dma_coverage_pct),
            UVM_LOW)
        `uvm_info("COV",
            $sformatf("  Overall Coverage      : %6.2f%%",
                      (cpu_coverage_pct + dma_coverage_pct) / 2.0),
            UVM_LOW)
        `uvm_info("COV", "==================================================", UVM_LOW)

        if ((cpu_coverage_pct < 90.0) || (dma_coverage_pct < 90.0))
            `uvm_info("COV",
                "Coverage below 90% - review coverpoints for closure",
                UVM_MEDIUM)
    endfunction

endclass

`endif // DMA_COVERAGE_SV
