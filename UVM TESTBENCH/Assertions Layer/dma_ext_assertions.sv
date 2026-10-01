//============================================================
// File        : dma_ext_assertions.sv
// Description : Extended Feature Assertions (B1..B17)
//============================================================
// INTERVIEW POINTS:
//   1. Feature-level (not baseline protocol) checks.
//   2. Receives internal signals via extra ports (state,
//      xfer_pulse, active_ch, rr_mask, dack_sense).
//   3. B11 is DISABLED (FIX 7) — semantic error in original.
//   4. B12 uses long window [1:40] because rollover→status
//      latency crosses multiple clock cycles.
//   5. B13..B16 verify WC underflow protection.
//============================================================

`ifndef DMA_EXT_ASSERTIONS_SV
`define DMA_EXT_ASSERTIONS_SV

module dma_ext_assertions(
    dma_if dif,
    input logic [3:0] state_ext,       // DMA_CONTROL.state
    input logic       xfer_pulse_ext,  // DMA_CONTROL.xfer_pulse
    input logic [1:0] active_ch_ext,   // cif.active_chnum
    input logic [1:0] rr_mask_ext,     // ADAPTIVE_ARB.rr_mask
    input logic       dack_sense
);

    default clocking cb @(posedge dif.CLK); endclocking
    default disable iff (dif.RESET);

    //------------------------------------------------------------
    // HELPER FUNCTIONS
    //------------------------------------------------------------
    function automatic bit dack_is_active(logic [3:0] dack, logic sense);
        return sense ? (~&dack) : (|dack);
    endfunction

    function automatic bit dack_matches_channel(logic [3:0] dack,
                                                 logic [1:0] ch,
                                                 logic sense);
        logic [3:0] onehot_vec;
        onehot_vec = 4'b0001 << ch;
        return sense ? (dack == ~onehot_vec) : (dack == onehot_vec);
    endfunction

    //============================================================
    // SECTION 1: ONE-HOT DACK (B1..B2)
    //============================================================

    // B1: DACK is one-hot OR all-deasserted
    assert property (
        $stable(dack_sense) |->
            (dack_sense ?
                ((dif.DACK == 4'b1111) || $onehot(~dif.DACK)) :
                ((dif.DACK == 4'b0000) || $onehot(dif.DACK)))
    ) else $error("B1 FAIL: DACK not one-hot or all-deasserted");

    //------------------------------------------------------------
    // B2 (FIX 6): DACK must match active channel when active,
    //             allowing 1-cycle lag between DACK and
    //             active_chnum update.
    //------------------------------------------------------------
    assert property (
        $stable(dack_sense) |->
            (dack_is_active(dif.DACK, dack_sense) |->
                (dack_matches_channel(dif.DACK, active_ch_ext, dack_sense) ||
                 dack_matches_channel(dif.DACK, $past(active_ch_ext, 1), dack_sense)))
    ) else $error("B2 FAIL: DACK=0x%X does not match active_chnum=%0d",
                  dif.DACK, active_ch_ext);

    //============================================================
    // SECTION 2: HRQ -> HLDA PROTOCOL (B3..B4)
    //============================================================

    // B3: HLDA rises only after HRQ
    assert property ( $rose(dif.HLDA) |-> dif.HRQ )
        else $error("B3 FAIL: HLDA rose while HRQ low");

    // B4: HRQ deasserts within 20 cycles after DREQ drops
    assert property ( $fell(|dif.DREQ) |-> ##[1:20] !dif.HRQ )
        else $error("B4 FAIL: HRQ did not deassert within 20 cycles");

    //============================================================
    // SECTION 3: XFER_PULSE WIDTH (B5..B6)
    //============================================================

    // B5: XFER_PULSE is 1 cycle wide
    assert property ( $rose(xfer_pulse_ext) |=> !xfer_pulse_ext )
        else $error("B5 FAIL: XFER_PULSE wider than 1 cycle");

    // B6: XFER_PULSE only asserts in ST_COMPLETE (4'b0101)
    assert property ( xfer_pulse_ext |-> (state_ext == 4'b0101) )
        else $error("B6 FAIL: XFER_PULSE asserted outside ST_COMPLETE (state=%b)",
                    state_ext);

    //============================================================
    // SECTION 4: BUFFER_USED <= BUFFER_SIZE (B7..B10)
    //============================================================
    // Per-channel sanity: occupancy cannot exceed capacity.
    //------------------------------------------------------------

    assert property (
        !$isunknown(dif.buffer_used_0) && !$isunknown(dif.BUF_SIZE_REG_0) |->
            (dif.buffer_used_0 <= dif.BUF_SIZE_REG_0)
    ) else $error("B7 FAIL: CH0 buffer_used=%0d > buffer_size=%0d",
                  dif.buffer_used_0, dif.BUF_SIZE_REG_0);

    assert property (
        !$isunknown(dif.buffer_used_1) && !$isunknown(dif.BUF_SIZE_REG_1) |->
            (dif.buffer_used_1 <= dif.BUF_SIZE_REG_1)
    ) else $error("B8 FAIL: CH1 buffer_used=%0d > buffer_size=%0d",
                  dif.buffer_used_1, dif.BUF_SIZE_REG_1);

    assert property (
        !$isunknown(dif.buffer_used_2) && !$isunknown(dif.BUF_SIZE_REG_2) |->
            (dif.buffer_used_2 <= dif.BUF_SIZE_REG_2)
    ) else $error("B9 FAIL: CH2 buffer_used=%0d > buffer_size=%0d",
                  dif.buffer_used_2, dif.BUF_SIZE_REG_2);

    assert property (
        !$isunknown(dif.buffer_used_3) && !$isunknown(dif.BUF_SIZE_REG_3) |->
            (dif.buffer_used_3 <= dif.BUF_SIZE_REG_3)
    ) else $error("B10 FAIL: CH3 buffer_used=%0d > buffer_size=%0d",
                  dif.buffer_used_3, dif.BUF_SIZE_REG_3);

    //============================================================
    // SECTION 5: RR MASK ROTATION — DISABLED (FIX 7)
    //============================================================
    // B11: rr_mask semantics — DISABLED.
    //
    // Original assertion compared rr_mask to active_chnum within
    // [1:4] cycles of a DACK. This is semantically wrong: rr_mask
    // points at the NEXT round-robin winner, not the CURRENT
    // active channel.
    //
    // The mask advances when the current winner completes and
    // the arbiter picks a new grant — not on every DACK.
    //
    // To re-enable: uncomment and compare rr_mask against the
    // expected next channel (e.g. (active_ch_ext + 1) % 4) after
    // confirming the arbiter's documented rotation policy.
    //============================================================

    //============================================================
    // SECTION 6: ROLLOVER PENDING LATCH (B12)
    //============================================================

    // B12: rollover_any rising sets EXT_STATUS[4] within 40 cycles
    assert property (
        $rose(dif.rollover_any) |-> ##[1:40] dif.EXT_STATUS_REG[4]
    ) else $error("B12 FAIL: EXT_STATUS[4] did not set after rollover_any");

    //============================================================
    // SECTION 7: WORD COUNT UNDERFLOW PROTECTION (B13..B16)
    //============================================================
    // WC should never wrap to 0xFFFF unless the base was
    // legitimately 0xFFFF (rare but legal config).
    //------------------------------------------------------------

    assert property (
        (dif.CURR_WC_0 == 16'hFFFF) |-> (dif.BASE_WC_0 == 16'hFFFF)
    ) else $error("B13 FAIL: CH0 CURR_WC underflowed to 0xFFFF");

    assert property (
        (dif.CURR_WC_1 == 16'hFFFF) |-> (dif.BASE_WC_1 == 16'hFFFF)
    ) else $error("B14 FAIL: CH1 CURR_WC underflowed to 0xFFFF");

    assert property (
        (dif.CURR_WC_2 == 16'hFFFF) |-> (dif.BASE_WC_2 == 16'hFFFF)
    ) else $error("B15 FAIL: CH2 CURR_WC underflowed to 0xFFFF");

    assert property (
        (dif.CURR_WC_3 == 16'hFFFF) |-> (dif.BASE_WC_3 == 16'hFFFF)
    ) else $error("B16 FAIL: CH3 CURR_WC underflowed to 0xFFFF");

    //============================================================
    // SECTION 8: BYTE POINTER TOGGLE (B17) — disabled/commented
    //============================================================

endmodule

`endif // DMA_EXT_ASSERTIONS_SV
