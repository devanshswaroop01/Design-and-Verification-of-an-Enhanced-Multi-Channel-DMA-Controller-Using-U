//============================================================
// File        : dma_top.sv
// Description : DMA Controller Top-Level (structural)
//               Instantiates all submodules and bridges
//               internal state to the UVM interface.
//============================================================
// INTERVIEW POINTS:
//   1. Pure structural wrapper — no RTL logic except assigns.
//   2. Uses `include for all submodule files (non-package style).
//   3. Creates ONE internal dma_control_if, shared by all
//      submodules that need it.
//   4. UVM visibility block drives internal probe signals onto
//      dif (interface) via hierarchical references.
//============================================================

`include "dma_reg_pkg.sv"
`include "dma_if.sv"
`include "dma_control_if.sv"
`include "dma_sw_commands.sv"
`include "dma_regfile.sv"
`include "dma_datapath.sv"
`include "dma_adaptive_arbiter.sv"
`include "dma_circular_buffer.sv"
`include "dma_control.sv"
`include "dma_priority.sv"

module dma_top (
    dma_if dif            // top-level virtual/physical interface
);

    //============================================================
    // SECTION 1: INTERNAL CONTROL INTERFACE
    //============================================================
    dma_control_if cif (
        .CLK   (dif.CLK),
        .RESET (dif.RESET)
    );

    //============================================================
    // SECTION 2: SUBMODULE INSTANTIATIONS
    //============================================================

    // 1. Software command decoder (combinational strobes)
    dma_sw_commands DMA_SW_COMMANDS (
        .dif (dif)
    );

    // 2. Register file (FIX 7: now gets cif for active_chnum)
    dma_regfile DMA_REG_FILE (
        .dif (dif),
        .cif (cif)
    );

    // 3. Datapath (address mux + latch + tri-state)
    dma_datapath DMA_DATAPATH (
        .dif (dif),
        .cif (cif)
    );

    // 4. Main control FSM
    dma_control DMA_CONTROL (
        .dif (dif),
        .cif (cif)
    );

    // 5. Priority / arbitration
    dma_priority DMA_PRIORITY (
        .dif (dif),
        .cif (cif)
    );

    //============================================================
    // SECTION 3: UVM VISIBILITY BRIDGES
    //============================================================
    // These assigns expose internal state (deep inside RTL
    // submodules) to the UVM-facing interface dif, so monitors,
    // scoreboards, coverage, and assertions can observe them
    // without needing hierarchical paths in the UVM code.
    //============================================================

    //---------- 3.1 Byte pointers ----------
    assign dif.byte_pointer      = DMA_REG_FILE.byte_pointer;
    assign dif.priority_byte_ptr = DMA_REG_FILE.priority_byte_ptr;

    //---------- 3.2 Active channel & control ----------
    assign dif.active_chnum = cif.active_chnum;
    assign dif.active_dack  = cif.active_dack;
    assign dif.VALID_DACK   = cif.VALID_DACK;
    assign dif.timeout      = cif.timeout;

    //---------- 3.3 Circular buffer state ----------
    // FIX M1: Previously left unconnected → floated as X.
    // Now bridged so UVM can see buffer occupancy and rollover.
    //------------------------------------------------------------
    assign dif.buffer_used_0 = DMA_CONTROL.CIRCULAR_BUFFER.buffer_used_int[0];
    assign dif.buffer_used_1 = DMA_CONTROL.CIRCULAR_BUFFER.buffer_used_int[1];
    assign dif.buffer_used_2 = DMA_CONTROL.CIRCULAR_BUFFER.buffer_used_int[2];
    assign dif.buffer_used_3 = DMA_CONTROL.CIRCULAR_BUFFER.buffer_used_int[3];

    assign dif.rollover_status   = DMA_CONTROL.CIRCULAR_BUFFER.rollover_status;
    assign dif.rollover_latched  = DMA_CONTROL.CIRCULAR_BUFFER.rollover_latched;
    assign dif.watermark_reached = DMA_CONTROL.CIRCULAR_BUFFER.watermark_reached;
    assign dif.rollover_any      = DMA_CONTROL.CIRCULAR_BUFFER.rollover_any;

endmodule : dma_top
