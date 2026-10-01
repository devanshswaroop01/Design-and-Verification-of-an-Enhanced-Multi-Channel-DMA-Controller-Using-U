//============================================================
// File        : dma_datapath.sv
// Description : DMA Address Datapath
//               - Selects address source (CPU bus vs DMA channel)
//               - Latches lower/upper address
//               - Tri-states address outputs when not driving
//============================================================
// INTERVIEW POINTS:
//   1. During CPU access: address comes from external pins.
//   2. During DMA (HLDA=1): address comes from active channel's
//      CURR_ADDR register.
//   3. Address is registered (1-cycle latency) — outputs come
//      from addr_l_buf / addr_u_buf.
//   4. Outputs are tri-stated unless (!CS_N && HLDA) — i.e. only
//      when DMA owns the bus.
//============================================================

module dma_datapath(
    dma_if         dif,
    dma_control_if cif
);

import dma_reg_pkg::*;

    //============================================================
    // SECTION 1: INTERNAL SIGNALS
    //============================================================
    // NOTE: addr_l_buf / addr_u_buf are internal latches.
    //       The interface signals ADDR_L / ADDR_U are driven from
    //       these below. Having separate internal names avoids
    //       driving and reading the same net.
    //------------------------------------------------------------
    logic [4:0]  addr_l_buf;
    logic [3:0]  addr_u_buf;
    logic [15:0] dma_addr;   // muxed 16-bit address

    //============================================================
    // SECTION 2: ADDRESS SOURCE MUX
    //============================================================
    // Default: use external address pins (CPU program access).
    // If HLDA=1 → CPU has released the bus, DMA is master:
    //     pick CURR_ADDR of the currently active channel.
    //------------------------------------------------------------
    always_comb begin
        dma_addr = {dif.ADDR_U, dif.ADDR_L};    // default

        if (dif.HLDA) begin
            case (cif.active_chnum)
                2'b00: dma_addr = dif.CURR_ADDR_0;
                2'b01: dma_addr = dif.CURR_ADDR_1;
                2'b10: dma_addr = dif.CURR_ADDR_2;
                2'b11: dma_addr = dif.CURR_ADDR_3;
                default: dma_addr = {dif.ADDR_U, dif.ADDR_L};
            endcase
        end
    end

    //============================================================
    // SECTION 3: ADDRESS LATCH
    //============================================================
    // Two capture modes:
    //   CPU access  (!CS_N && !HLDA): latch external ADDR_L/U
    //   DMA active  (HLDA)          : latch chosen dma_addr
    // Registered → 1-cycle latency between source and output.
    //------------------------------------------------------------
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin

        if (dif.RESET) begin
            addr_l_buf <= 5'b0000;
            addr_u_buf <= 4'b0000;

        end else if (!dif.CS_N && !dif.HLDA) begin
            addr_l_buf <= dif.ADDR_L;
            addr_u_buf <= dif.ADDR_U;

        end else if (dif.HLDA) begin
            addr_l_buf <= dma_addr[4:0];
            addr_u_buf <= dma_addr[8:5];   // NOTE: only 4 bits [8:5]
        end
    end

    //============================================================
    // SECTION 4: ADDRESS OUTPUT DRIVERS (tri-state)
    //============================================================
    // Drive external address pins only when DMA owns the bus.
    // Condition (!CS_N && HLDA): CS asserted AND DMA has bus.
    //------------------------------------------------------------
    assign dif.ADDR_L = (!dif.CS_N && dif.HLDA) ? addr_l_buf : 5'bz;
    assign dif.ADDR_U = (!dif.CS_N && dif.HLDA) ? addr_u_buf : 4'bz;

endmodule : dma_datapath

//           ┌──────────────┐
//           │  dma_if      │◄──── CPU bus + internal probes
//           └──────┬───────┘
//                  │
//      ┌───────────┼──────────────────────┐
//      │           │                      │
// ┌────▼─────┐ ┌───▼────────┐    ┌────────▼────────┐
// │ dma_sw_  │ │ dma_       │    │ dma_control_if  │
// │ commands │ │ regfile    │◄──►│ (FSM ↔ datapath)│
// └──────────┘ └───┬────────┘    └────────┬────────┘
//                  │                      │
//             (reg values)          (active_chnum,
//                  │                 XFER_PULSE etc.)
//                  │                      │
//             ┌────▼──────────────────────▼────┐
//             │  dma_datapath                  │
//             │  (addr mux + latch + tristate) │
//             └────────────────────────────────┘
