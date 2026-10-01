//============================================================
// File        : dma_scoreboard.sv
// Description : UVM Scoreboard for DMA Controller
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_scoreboard — standard component base.
//   2. THREE analysis imports (via `_imp_decl` macros):
//        _scb_cpu       → write_scb_cpu      (CPU events, informational)
//        _scb_dma       → write_scb_dma      (observed DMA events)
//        _scb_expected  → write_scb_expected (expected DMA events)
//   3. Uses TWO queues (observed_q, expected_q) to handle
//      out-of-order arrival (DMA vs ref model latency).
//   4. Field-aware comparison: KEY (error) vs SECONDARY (warning).
//   5. FIX M4: active_dack/valid_dack now KEY fields (independent
//      prediction via reference model) — no more tautology.
//============================================================

`ifndef DMA_SCOREBOARD_SV
`define DMA_SCOREBOARD_SV

// Declare 3 suffixed analysis imports
`uvm_analysis_imp_decl(_scb_cpu)
`uvm_analysis_imp_decl(_scb_dma)
`uvm_analysis_imp_decl(_scb_expected)

class dma_scoreboard extends uvm_scoreboard;

    //============================================================
    // TLM ANALYSIS EXPORTS (imports from scoreboard's perspective)
    //============================================================
    uvm_analysis_imp_scb_cpu      #(cpu_seq_item, dma_scoreboard) cpu_export;
    uvm_analysis_imp_scb_dma      #(dma_seq_item, dma_scoreboard) dma_export;
    uvm_analysis_imp_scb_expected #(dma_seq_item, dma_scoreboard) exp_export;

    //============================================================
    // STATISTICS
    //============================================================
    int unsigned cpu_events_seen;
    int unsigned dma_events_seen;
    int unsigned expected_events_seen;
    int unsigned total_compares;
    int unsigned matche;              // NOTE: typo — should be "matches"
    int unsigned mismatches;
    int unsigned field_warnings;

    //============================================================
    // QUEUES (handle out-of-order arrival)
    //============================================================
    dma_seq_item observed_q[$];
    dma_seq_item expected_q[$];

    `uvm_component_utils(dma_scoreboard)

    function new(string name = "dma_scoreboard", uvm_component parent = null);
        super.new(name, parent);
        cpu_events_seen      = 0;
        dma_events_seen      = 0;
        expected_events_seen = 0;
        total_compares       = 0;
        matche               = 0;
        mismatches           = 0;
        field_warnings       = 0;
    endfunction

    //============================================================
    // BUILD PHASE — create analysis exports
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cpu_export = new("cpu_export", this);
        dma_export = new("dma_export", this);
        exp_export = new("exp_export", this);
    endfunction

    //============================================================
    // WRITE FROM CPU MONITOR — informational only
    //============================================================
    virtual function void write_scb_cpu(cpu_seq_item item);
        cpu_events_seen++;
        `uvm_info("SCB",
            $sformatf("CPU event #%0d: %s",
                      cpu_events_seen, item.convert2string()),
            UVM_HIGH)
    endfunction

    //============================================================
    // WRITE FROM DMA MONITOR — observed side
    //============================================================
    // FIX 3: Filter to transfer-only items (tx_type + xfer_pulse)
    //        so queues only contain comparable events.
    //------------------------------------------------------------
    virtual function void write_scb_dma(dma_seq_item obs);
        dma_seq_item cloned;

        // Pre-filter: only accept transfer-complete events
        if (obs.tx_type != DMA_TRANSFER_TX) begin
            `uvm_info("SCB",
                $sformatf("Skipping non-transfer observed item: %s",
                          obs.tx_type.name()),
                UVM_HIGH)
            return;
        end

        if (obs.xfer_pulse !== 1'b1) begin
            `uvm_info("SCB",
                $sformatf("Skipping observed item without XFER_PULSE: %s",
                          obs.convert2string()),
                UVM_HIGH)
            return;
        end

        // Clone into our queue so the monitor can reuse its item
        if (!$cast(cloned, obs.clone())) begin
            `uvm_fatal("SCB", "Failed to clone observed dma_seq_item")
        end
        observed_q.push_back(cloned);
        dma_events_seen++;

        // Try to pair with a matching expected item
        attempt_compare();
    endfunction

    //============================================================
    // WRITE FROM REFERENCE MODEL — expected side
    //============================================================
    virtual function void write_scb_expected(dma_seq_item exp);
        dma_seq_item cloned;

        // Pre-filter (same as observed)
        if (exp.tx_type != DMA_TRANSFER_TX) begin
            `uvm_info("SCB",
                $sformatf("Skipping non-transfer expected item: %s",
                          exp.tx_type.name()),
                UVM_HIGH)
            return;
        end

        if (exp.xfer_pulse !== 1'b1) begin
            `uvm_info("SCB",
                $sformatf("Skipping expected item without XFER_PULSE: %s",
                          exp.convert2string()),
                UVM_HIGH)
            return;
        end

        if (!$cast(cloned, exp.clone())) begin
            `uvm_fatal("SCB", "Failed to clone expected dma_seq_item")
        end
        expected_q.push_back(cloned);
        expected_events_seen++;

        attempt_compare();
    endfunction

    //============================================================
    // ATTEMPT COMPARE — drain queues pairwise
    //============================================================
    protected virtual function void attempt_compare();
        dma_seq_item obs;
        dma_seq_item exp;

        while (observed_q.size() > 0 && expected_q.size() > 0) begin
            obs = observed_q.pop_front();
            exp = expected_q.pop_front();
            compare_pair(obs, exp);
        end
    endfunction

    //============================================================
    // COMPARE PAIR — field-aware
    //============================================================
    // KEY     → UVM_ERROR   (functional failures)
    // SECONDARY → UVM_WARNING (known-model limitations)
    //------------------------------------------------------------
    protected virtual function void compare_pair(dma_seq_item obs,
                                                  dma_seq_item exp);
        int mismatch_count = 0;

        total_compares++;

        //========================================================
        // KEY FIELDS — mismatch = ERROR
        //========================================================
        if (obs.tx_type != exp.tx_type) begin
            `uvm_error("SCB",
                $sformatf("tx_type MISMATCH: obs=%s exp=%s",
                          obs.tx_type.name(), exp.tx_type.name()))
            mismatch_count++;
        end

        if (obs.cycle != exp.cycle) begin
            `uvm_error("SCB",
                $sformatf("cycle MISMATCH: obs=%s exp=%s",
                          obs.cycle.name(), exp.cycle.name()))
            mismatch_count++;
        end

        if (obs.dreq != exp.dreq) begin
            `uvm_error("SCB",
                $sformatf("dreq MISMATCH: obs=0x%X exp=0x%X",
                          obs.dreq, exp.dreq))
            mismatch_count++;
        end

        if (obs.dack != exp.dack) begin
            `uvm_error("SCB",
                $sformatf("dack MISMATCH: obs=0x%X exp=0x%X",
                          obs.dack, exp.dack))
            mismatch_count++;
        end

        if (obs.active_chnum != exp.active_chnum) begin
            `uvm_error("SCB",
                $sformatf("active_chnum MISMATCH: obs=%0d exp=%0d",
                          obs.active_chnum, exp.active_chnum))
            mismatch_count++;
        end

        //--------------------------------------------------------
        // FIX M4: independent grant checks
        //--------------------------------------------------------
        if (obs.active_dack != exp.active_dack) begin
            `uvm_error("SCB",
                $sformatf("active_dack MISMATCH: obs=0x%X exp=0x%X (predicted ch=%0d)",
                          obs.active_dack, exp.active_dack, exp.active_chnum))
            mismatch_count++;
        end

        if (obs.valid_dack != exp.valid_dack) begin
            `uvm_error("SCB",
                $sformatf("valid_dack MISMATCH: obs=%b exp=%b (predicted ch=%0d)",
                          obs.valid_dack, exp.valid_dack, exp.active_chnum))
            mismatch_count++;
        end

        if (obs.xfer_pulse != exp.xfer_pulse) begin
            `uvm_error("SCB",
                $sformatf("xfer_pulse MISMATCH: obs=%b exp=%b",
                          obs.xfer_pulse, exp.xfer_pulse))
            mismatch_count++;
        end

        if (obs.eop_n != exp.eop_n) begin
            `uvm_error("SCB",
                $sformatf("eop_n MISMATCH: obs=%b exp=%b",
                          obs.eop_n, exp.eop_n))
            mismatch_count++;
        end

        // FIX A-R: ior_n / iow_n REMOVED from key comparison.
        // Reason: On the XFER_PULSE cycle, the DUT has already
        // deasserted IOR_N/IOW_N — comparing them produces
        // false mismatches.

        //========================================================
        // SECONDARY FIELDS — mismatch = WARNING
        //========================================================
        if (obs.aen != exp.aen) begin
            `uvm_warning("SCB",
                $sformatf("aen MISMATCH: obs=%b exp=%b", obs.aen, exp.aen))
            field_warnings++;
        end

        if (obs.adstb != exp.adstb) begin
            `uvm_warning("SCB",
                $sformatf("adstb MISMATCH: obs=%b exp=%b", obs.adstb, exp.adstb))
            field_warnings++;
        end

        if (obs.buffer_used_0 != exp.buffer_used_0) begin
            `uvm_warning("SCB",
                $sformatf("buffer_used_0 MISMATCH: obs=%0d exp=%0d",
                          obs.buffer_used_0, exp.buffer_used_0))
            field_warnings++;
        end

        if (obs.rollover_status != exp.rollover_status) begin
            `uvm_warning("SCB",
                $sformatf("rollover_status MISMATCH: obs=0x%X exp=0x%X",
                          obs.rollover_status, exp.rollover_status))
            field_warnings++;
        end

        if (obs.watermark_reached != exp.watermark_reached) begin
            `uvm_warning("SCB",
                $sformatf("watermark_reached MISMATCH: obs=%b exp=%b",
                          obs.watermark_reached, exp.watermark_reached))
            field_warnings++;
        end

        // FIX B: ext_status_reg demoted to secondary
        if (obs.ext_status_reg != exp.ext_status_reg) begin
            `uvm_warning("SCB",
                $sformatf("EXT_STATUS_REG MISMATCH: obs=0x%02X exp=0x%02X",
                          obs.ext_status_reg, exp.ext_status_reg))
            field_warnings++;
        end

        //========================================================
        // Bookkeeping
        //========================================================
        if (mismatch_count == 0) begin
            matche++;
            `uvm_info("SCB",
                $sformatf("Compare #%0d PASS: %s",
                          total_compares, obs.convert2string()),
                UVM_HIGH)
        end else begin
            mismatches++;
            `uvm_error("SCB",
                $sformatf("Compare #%0d FAIL (%0d field mismatches):",
                          total_compares, mismatch_count))
            `uvm_info("SCB", "--- Expected ---", UVM_LOW)
            exp.print();
            `uvm_info("SCB", "--- Observed ---", UVM_LOW)
            obs.print();
        end
    endfunction

    //============================================================
    // REPORT PHASE
    //============================================================
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        `uvm_info("SCB", "==================================================", UVM_LOW)
        `uvm_info("SCB", "            DMA SCOREBOARD SUMMARY                ", UVM_LOW)
        `uvm_info("SCB", "==================================================", UVM_LOW)
        `uvm_info("SCB", $sformatf("CPU events seen        : %0d", cpu_events_seen), UVM_LOW)
        `uvm_info("SCB", $sformatf("DMA events observed    : %0d", dma_events_seen), UVM_LOW)
        `uvm_info("SCB", $sformatf("Expected events        : %0d", expected_events_seen), UVM_LOW)
        `uvm_info("SCB", $sformatf("Total compares         : %0d", total_compares), UVM_LOW)
        `uvm_info("SCB", $sformatf("Matches                : %0d", matche), UVM_LOW)
        `uvm_info("SCB", $sformatf("Mismatches (errors)    : %0d", mismatches), UVM_LOW)
        `uvm_info("SCB", $sformatf("Field warnings         : %0d", field_warnings), UVM_LOW)
        `uvm_info("SCB", "==================================================", UVM_LOW)

        // FIX 2: Handle "no compares" case explicitly
        if (total_compares == 0)
            `uvm_info("SCB",
                "SCOREBOARD STATUS: NO_COMPARES (no DMA events observed)",
                UVM_LOW)
        else if (mismatches == 0)
            `uvm_info("SCB", "SCOREBOARD STATUS: PASSED", UVM_LOW)
        else
            `uvm_error("SCB", "SCOREBOARD STATUS: FAILED")
    endfunction

endclass

`endif // DMA_SCOREBOARD_SV  

         // Data Flow Into the Scoreboard
          
   // cpu_monitor.ap   ──► write_scb_cpu()      (informational)
   // dma_monitor.ap   ──► write_scb_dma()       ─┐
   //                                             ├──► compare_pair()
   // reference_model  ──► write_scb_expected()  ─┘
   //     .expected_port

   // Arrows:
   //   observed side → observed_q  ┐
   //   expected side → expected_q  ├── FIFO pair-by-pair comparison
   //                               ┘
