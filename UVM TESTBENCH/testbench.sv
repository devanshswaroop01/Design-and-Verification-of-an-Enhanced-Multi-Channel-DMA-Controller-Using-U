//============================================================
// File        : dma_tb_top.sv
// Description : UVM Top-Level Testbench for DMA Controller
//============================================================
// INTERVIEW POINTS:
//   1. Only module in the UVM environment (not a class).
//   2. Generates clock + reset.
//   3. Instantiates interface + DUT.
//   4. Binds assertion/coverage modules into DUT.
//   5. Publishes VIF to uvm_config_db.
//   6. Calls run_test() — bootstraps the entire UVM env.
//   7. Optional global watchdog prevents sim hangs.
//============================================================

`ifndef DMA_TB_TOP_SV
`define DMA_TB_TOP_SV

`timescale 1ns/1ps

//============================================================
// FILE INCLUSIONS
//============================================================
// RTL files are typically included via -f filelist at compile.
// UVM package + SVA/coverage modules must be included here.
//------------------------------------------------------------
`include "dma_uvm_pkg.sv"
`include "dma_assertions.sv"       // protocol assertions (A1-A28)
`include "dma_ext_assertions.sv"   // feature assertions (B1-B17)
`include "dma_ext_coverage_c.sv"   // coverage class + bind module

//============================================================
// PACKAGE IMPORTS
//============================================================
import dma_reg_pkg::*;
import dma_uvm_pkg::*;

//============================================================
// TOP-LEVEL TESTBENCH MODULE
//============================================================
module dma_tb_top;

    //============================================================
    // SECTION 1: PARAMETERS
    //============================================================
    parameter time CLK_PERIOD     = 20ns;    // 50 MHz clock
    parameter time GLOBAL_TIMEOUT = 10ms;    // watchdog limit

    //============================================================
    // SECTION 2: CLOCK AND RESET
    //============================================================
    logic CLK;
    logic RESET;

    //------------------------------------------------------------
    // Clock generation: 50% duty, toggles every CLK_PERIOD/2
    //------------------------------------------------------------
    initial CLK = 1'b0;
    always #(CLK_PERIOD/2) CLK = ~CLK;

    //------------------------------------------------------------
    // Reset: held high for 10 cycles, then released
    //------------------------------------------------------------
    initial begin
        RESET = 1'b1;
        repeat (10) @(posedge CLK);
        RESET = 1'b0;
        `uvm_info("TB_TOP", "Reset deasserted", UVM_LOW)
    end

    //============================================================
    // SECTION 3: DMA INTERFACE INSTANTIATION
    //============================================================
    // One shared interface — passed to DUT + all UVM agents.
    //------------------------------------------------------------
    dma_if dif(
        .CLK   (CLK),
        .RESET (RESET)
    );

    //============================================================
    // SECTION 4: DUT INSTANTIATION
    //============================================================
    // The DMA controller — receives the shared interface.
    //------------------------------------------------------------
    dma_top dut (
        .dif(dif)
    );

    //============================================================
    // SECTION 5: BIND ASSERTION + COVERAGE MODULES
    //============================================================
    // `bind` instantiates the assertion/coverage module INSIDE
    // the DUT's scope. This allows access to internal signals
    // via hierarchical paths (DMA_REG_FILE, DMA_CONTROL, etc.).
    //------------------------------------------------------------

    //------------------------------------------------------------
    // Baseline protocol assertions
    //------------------------------------------------------------
    bind dma_top dma_assertions u_dma_assertions (
        .dif        (dif),
        .dack_sense (DMA_REG_FILE.COMMAND_REG[7])   // polarity config
    );

    //------------------------------------------------------------
    // Extended feature assertions
    //------------------------------------------------------------
    // Extra ports expose internal signals the assertions need.
    //------------------------------------------------------------
    bind dma_top dma_ext_assertions u_ext_assertions (
        .dif            (dif),
        .state_ext      (DMA_CONTROL.state),         // FSM state
        .xfer_pulse_ext (DMA_CONTROL.xfer_pulse),    // transfer pulse
        .active_ch_ext  (cif.active_chnum),          // current channel
        .rr_mask_ext    (DMA_PRIORITY.ADAPTIVE_ARB.rr_mask), // RR mask
        .dack_sense     (DMA_REG_FILE.COMMAND_REG[7])
    );

    //------------------------------------------------------------
    // Extended coverage (SVA cover property + covergroups)
    //------------------------------------------------------------
    bind dma_top dma_ext_coverage_sv u_ext_coverage (
        .dif            (dif),
        .state_ext      (DMA_CONTROL.state),
        .xfer_pulse_ext (DMA_CONTROL.xfer_pulse),
        .active_ch_ext  (cif.active_chnum),
        .rr_mask_ext    (DMA_PRIORITY.ADAPTIVE_ARB.rr_mask)
    );

    //============================================================
    // SECTION 6: UVM CONFIG DATABASE SETUP
    //============================================================
    // Publish the virtual interface handle so all UVM components
    // can retrieve it with uvm_config_db #(virtual dma_if)::get.
    //------------------------------------------------------------
    initial begin
        //--------------------------------------------------------
        // Global wildcard — any component can get "vif"
        //--------------------------------------------------------
        uvm_config_db #(virtual dma_if)::set(null, "*", "vif", dif);

        //--------------------------------------------------------
        // Explicit paths — clarity / safety
        //--------------------------------------------------------
        uvm_config_db #(virtual dma_if)::set(null,
            "uvm_test_top.env.cpu_agt.*", "vif", dif);
        uvm_config_db #(virtual dma_if)::set(null,
            "uvm_test_top.env.dma_agt.*", "vif", dif);
    end

    //============================================================
    // SECTION 7: UVM TEST EXECUTION
    //============================================================
    // Test selection:
    //   +UVM_TESTNAME=<name> on command line → that test
    //   Otherwise the ACTIVE run_test() below is used
    //   Only ONE run_test() should be uncommented
    //------------------------------------------------------------
    initial begin
        //--------------------------------------------------------
        // Waveform dump
        //--------------------------------------------------------
        $dumpfile("dma_uvm.vcd");
        $dumpvars(0, dma_tb_top);

        //--------------------------------------------------------
        // Command-line override or default test
        //--------------------------------------------------------
        if ($test$plusargs("UVM_TESTNAME")) begin
            run_test();     // let +UVM_TESTNAME decide
        end else begin

            //====================================================
            // DMA REGRESSION — EXECUTION ORDER
            // (only one run_test() should be active)
            //====================================================

            //----------------------------------------------------
            // 1. SMOKE / SANITY
            //----------------------------------------------------
            //run_test("dma_base_test");            // bare env
            //run_test("dma_smoke_test");           // 3 quick checks

            //----------------------------------------------------
            // 2. RESET & CLOCKING
            //----------------------------------------------------
            //run_test("dma_reset_test");

            //----------------------------------------------------
            // 3. RAL SANITY
            //----------------------------------------------------
            //run_test("dma_reg_write_test");
            //run_test("dma_reg_read_test");
            //run_test("dma_reg_test");

            //----------------------------------------------------
            // 4. BYTE-POINTER & MASTER CLEAR
            //----------------------------------------------------
            //run_test("dma_byte_pointer_test");
            //run_test("dma_master_clear_test");

            //----------------------------------------------------
            // 5. DMA CONFIGURATION
            //----------------------------------------------------
            //run_test("dma_channel_configuration_test");
            //run_test("dma_dma_read_test");
            //run_test("dma_dma_write_test");
            //run_test("dma_back_to_back_dma_test");

            //----------------------------------------------------
            // 6. EXTENDED FEATURES
            //----------------------------------------------------
            //run_test("dma_priority_test");
            //run_test("dma_circular_test");
            //run_test("dma_error_test");

            //----------------------------------------------------
            // 7. TRANSFER EXECUTION  ← currently ACTIVE
            //----------------------------------------------------
            run_test("dma_transfer_test");

            //----------------------------------------------------
            // 8. CONSTRAINED RANDOM  ← currently ACTIVE
            //----------------------------------------------------
            run_test("dma_mixed_programming_test");
            //run_test("dma_random_register_configuration_test");
            //run_test("dma_random_test");
            //run_test("dma_random_regression_test");

            //----------------------------------------------------
            // 9. STRESS  (last)
            //----------------------------------------------------
            //run_test("dma_stress_test");

        end
    end

    //============================================================
    // SECTION 8: GLOBAL TIMEOUT WATCHDOG
    //============================================================
    // If sim hangs, fatal error after GLOBAL_TIMEOUT.
    //------------------------------------------------------------
    initial begin
        #(GLOBAL_TIMEOUT);
        `uvm_fatal("TB_TOP", "Simulation timeout reached!")
    end

endmodule : dma_tb_top

`endif // DMA_TB_TOP_SV
