//============================================================
// File        : dma_assertions.sv
// Description : Baseline Protocol Assertions (A1..A28)
//============================================================
// INTERVIEW POINTS:
//   1. Bound to DUT via `bind` in dma_tb_top.sv.
//   2. `default clocking` + `default disable iff (RESET)` apply
//      to all asserts in the module.
//   3. Helper functions for polarity-aware DACK checks
//      (dack_sense is a runtime input).
//   4. Numbered A1..A28 for easy reference in logs.
//   5. FIX 6/7 widened timing windows on A11/A13/A15/A25
//      because driver-to-FSM latency crosses cycle boundaries.
//============================================================

`ifndef DMA_ASSERTIONS_SV
`define DMA_ASSERTIONS_SV

module dma_assertions(
    dma_if dif,
    input logic dack_sense    // from COMMAND_REG[7]
);

    //------------------------------------------------------------
    // DEFAULT CLOCK + RESET
    //------------------------------------------------------------
    default clocking cb @(posedge dif.CLK); endclocking
    default disable iff (dif.RESET);   // asserts disabled during reset

    //------------------------------------------------------------
    // HELPER FUNCTIONS
    //------------------------------------------------------------
    // DACK is polarity-selectable; helpers normalize that.
    //------------------------------------------------------------
    function automatic bit dack_is_active(logic [3:0] dack, logic sense);
        return sense ? (~&dack) : (|dack);
    endfunction

    function automatic bit dack_is_idle(logic [3:0] dack, logic sense);
        return sense ? (&dack) : (~|dack);
    endfunction

    //============================================================
    // SECTION 1: RESET ASSERTIONS (A1..A4)
    //============================================================
    // During RESET, handshake outputs must be idle.
    //------------------------------------------------------------

    // A1: HRQ low during reset
    assert property ( dif.RESET |-> (dif.HRQ == 1'b0) )
        else $error("A1 FAIL: HRQ asserted during RESET");

    // A2: AEN low during reset
    assert property ( dif.RESET |-> (dif.AEN == 1'b0) )
        else $error("A2 FAIL: AEN asserted during RESET");

    // A3: DACK idle during reset (polarity-aware)
    assert property ( dif.RESET |-> dack_is_idle(dif.DACK, dack_sense) )
        else $error("A3 FAIL: DACK not idle during RESET");

    // A4: MEMR_N HIGH or Z during reset
    assert property ( dif.RESET |-> (dif.MEMR_N inside {1'b1, 1'bz}) )
        else $error("A4 FAIL: MEMR_N not HIGH/Z during RESET");

    //============================================================
    // SECTION 2: PROGRAMMING INTERFACE (A5..A10)
    //============================================================
    // CPU register access rules.
    //------------------------------------------------------------

    // A5: IOR_N and IOW_N never both active
    assert property ( !(~dif.IOR_N && ~dif.IOW_N) )
        else $error("A5 FAIL: IOR_N and IOW_N simultaneously active");

    // A6: Programming cycle requires CS_N asserted
    assert property ( ((~dif.IOR_N || ~dif.IOW_N) |-> (~dif.CS_N)) )
        else $error("A6 FAIL: Programming cycle without CS_N");

    // A7: CPU programming only when DMA inactive (HLDA=0)
    assert property ( ((~dif.IOR_N || ~dif.IOW_N) |-> (!dif.HLDA)) )
        else $error("A7 FAIL: CPU programming while DMA owns bus");

    // A8: CS_N stays asserted during write
    assert property ( (!dif.IOW_N |-> !dif.CS_N) )
        else $error("A8 FAIL: CS_N deasserted during write");

    // A9: CS_N stays asserted during read
    assert property ( (!dif.IOR_N |-> !dif.CS_N) )
        else $error("A9 FAIL: CS_N deasserted during read");

    // A10: Register address must be valid 0x00-0x1F
    assert property (
        (!dif.CS_N && !dif.HLDA &&
         (~dif.IOR_N || ~dif.IOW_N) &&
         !$isunknown(dif.ADDR_L)) |->
            (dif.ADDR_L inside {[5'h00 : 5'h1F]})
    ) else $error("A10 FAIL: Invalid register address during programming");

    //============================================================
    // SECTION 3: DMA REQUEST / HANDSHAKE (A11..A15)
    //============================================================
    // Request-to-grant protocol checks.
    // FIX 6: 2-cycle grace window on A11 and A15.
    //------------------------------------------------------------

    // A11: HRQ asserted only when DREQ or SW request active
    //      (current or within last 2 cycles) — FIX 6
    assert property (
        (dif.HRQ && !dif.MASTER_CLEAR_CMD) |->
            ((|dif.DREQ)                                    ||
             (|dif.REQUEST_REG[3:0])                        ||
             $past((|dif.DREQ) || (|dif.REQUEST_REG[3:0]), 1) ||
             $past((|dif.DREQ) || (|dif.REQUEST_REG[3:0]), 2))
    ) else $error("A11 FAIL: HRQ without active request (DREQ or REQUEST_REG)");

    // A12: DACK active implies HRQ active
    assert property (
        $stable(dack_sense) |->
            (dack_is_active(dif.DACK, dack_sense) |-> dif.HRQ)
    ) else $error("A12 FAIL: DACK active while HRQ low");

    //------------------------------------------------------------
    // A13 (FIX 7): AEN implies HRQ was active within last 3
    //              cycles.
    //
    // AEN stays active 2–3 cycles past HRQ drop so external
    // memory can latch the DMA address (8237 protocol).
    // Window widened from 1 to 3 past cycles.
    //------------------------------------------------------------
    assert property (
        dif.AEN |->
            (dif.HRQ           ||
             $past(dif.HRQ, 1) ||
             $past(dif.HRQ, 2) ||
             $past(dif.HRQ, 3))
    ) else $error("A13 FAIL: AEN asserted >3 cycles after HRQ drop");

    // A14: DACK is one-hot OR all-deasserted (polarity-aware)
    assert property (
        $stable(dack_sense) |->
            (dack_sense ?
                ((dif.DACK == 4'b1111) || $onehot(~dif.DACK)) :
                ((dif.DACK == 4'b0000) || $onehot(dif.DACK)))
    ) else $error("A14 FAIL: DACK not one-hot or all-deasserted");

    // A15 (FIX 6): DACK active requires DREQ or REQUEST_REG
    //              (current or within last 2 cycles)
    assert property (
        $stable(dack_sense) |->
            (dack_is_active(dif.DACK, dack_sense) |->
                ((|dif.DREQ)                                    ||
                 (|dif.REQUEST_REG[3:0])                        ||
                 $past((|dif.DREQ) || (|dif.REQUEST_REG[3:0]), 1) ||
                 $past((|dif.DREQ) || (|dif.REQUEST_REG[3:0]), 2)))
    ) else $error("A15 FAIL: DACK active without DREQ/REQUEST_REG");

    //============================================================
    // SECTION 4: DMA TRANSFER (A16..A19)
    //============================================================
    // Memory/I/O control signal mutual exclusion + enable rules.
    //------------------------------------------------------------

    // A16: MEMR_N and MEMW_N never together during DMA
    assert property (
        ((dif.HLDA && dif.AEN) |->
            !((dif.MEMR_N === 1'b0) && (dif.MEMW_N === 1'b0)))
    ) else $error("A16 FAIL: MEMR_N and MEMW_N simultaneously active");

    // A17: IOR_N and IOW_N never together
    assert property ( !(~dif.IOR_N && ~dif.IOW_N) )
        else $error("A17 FAIL: IOR_N and IOW_N simultaneously active");

    // A18: Memory access requires AEN
    assert property ( ((!dif.MEMR_N || !dif.MEMW_N) |-> dif.AEN) )
        else $error("A18 FAIL: Memory access without AEN");

    // A19: DMA I/O access requires AEN
    assert property (
        ((dif.HLDA && ((dif.IOR_N == 1'b0) || (dif.IOW_N == 1'b0))) |->
            dif.AEN)
    ) else $error("A19 FAIL: DMA I/O access without AEN");

    //============================================================
    // SECTION 5: ADDRESS / CONTROL (A20..A24)
    //============================================================

    // A20: ADSTB implies AEN
    assert property ( dif.ADSTB |-> dif.AEN )
        else $error("A20 FAIL: ADSTB asserted while AEN low");

    // A21: MEMR_N during DMA requires DACK active
    assert property (
        ((dif.HLDA && dif.AEN && (dif.MEMR_N == 1'b0)) |->
            dack_is_active(dif.DACK, dack_sense))
    ) else $error("A21 FAIL: MEMR_N without active DACK");

    // A22: MEMW_N during DMA requires DACK active
    assert property (
        ((dif.HLDA && dif.AEN && (dif.MEMW_N == 1'b0)) |->
            dack_is_active(dif.DACK, dack_sense))
    ) else $error("A22 FAIL: MEMW_N without active DACK");

    // A23: IOR_N during DMA requires DACK active
    assert property (
        ((dif.HLDA && dif.AEN && (dif.IOR_N == 1'b0)) |->
            dack_is_active(dif.DACK, dack_sense))
    ) else $error("A23 FAIL: IOR_N without active DACK");

    // A24: IOW_N during DMA requires DACK active
    assert property (
        ((dif.HLDA && dif.AEN && (dif.IOW_N == 1'b0)) |->
            dack_is_active(dif.DACK, dack_sense))
    ) else $error("A24 FAIL: IOW_N without active DACK");

    //============================================================
    // SECTION 6: END-OF-TRANSFER (A25)
    //============================================================

    //------------------------------------------------------------
    // A25 (FIX 7): EOP_N implies HRQ was active within last 3
    //              cycles.
    //
    // EOP_N stays active 2–3 cycles past HRQ drop so external
    // logic can observe transfer completion.
    //------------------------------------------------------------
    assert property (
        (!dif.EOP_N |->
            (dif.HRQ           ||
             $past(dif.HRQ, 1) ||
             $past(dif.HRQ, 2) ||
             $past(dif.HRQ, 3)))
    ) else $error("A25 FAIL: EOP_N asserted >3 cycles after HRQ drop");

    //============================================================
    // SECTION 7: ILLEGAL STATE (A26..A28)
    //============================================================

    // A26: IOR_N and IOW_N mutually exclusive (duplicate of A5)
    assert property ( !((!dif.IOR_N) && (!dif.IOW_N)) )
        else $error("A26 FAIL: IOR_N and IOW_N simultaneous");

    // A27: MEMR_N and IOR_N never together during DMA
    assert property (
        ((dif.HLDA && dif.AEN) |->
            !((dif.MEMR_N === 1'b0) && (dif.IOR_N === 1'b0)))
    ) else $error("A27 FAIL: MEMR_N and IOR_N simultaneous");

    // A28: MEMW_N and IOW_N never together during DMA
    assert property (
        ((dif.HLDA && dif.AEN) |->
            !((dif.MEMW_N === 1'b0) && (dif.IOW_N === 1'b0)))
    ) else $error("A28 FAIL: MEMW_N and IOW_N simultaneous");

endmodule

`endif // DMA_ASSERTIONS_SV
