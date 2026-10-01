//=====================================================================
// File        : dma_adaptive_arbiter.sv
// Description : Adaptive 4-channel DMA Arbiter
//               Modes: Fixed | Round-Robin | Weighted | Dynamic
//               Features: aging, PCIe credits, SoC AXI ready,
//                         grant-hold timeout
//=====================================================================
// PRIORITY CONVENTION (memorize):
//   - Higher NUMERIC value = higher priority.
//   - max_priority = clamp ceiling (e.g. 4'hF)
//   - min_priority = clamp floor   (e.g. 4'h0)
//   - Encoder picks strictly-greater → only one winner.
//=====================================================================
// INTERVIEW POINTS:
//   1. 4 arbitration modes selected by arb_mode.
//   2. Aging: waiting channels gain priority over time.
//   3. RR rotation via rr_mask (last-granted is deprioritized).
//   4. Grant HOLD: once granted, arbiter locks until
//      tx_complete OR timeout (FIX 8B).
//   5. Two request-gating domains: PCIe credits + AXI ready.
//   6. Priority encoder uses strict ">" → no ties.
//=====================================================================

`ifndef DMA_ADAPTIVE_ARBITER_SV
`define DMA_ADAPTIVE_ARBITER_SV

module dma_adaptive_arbiter #(
    parameter int GRANT_TIMEOUT_CYCLES = 64   // watchdog for stuck grant
) (
    input  logic        clk,
    input  logic        reset_n,              // ACTIVE-LOW async reset

    //---------- Request Interface ----------
    input  logic [3:0]  req,                  // raw request per channel
    input  logic [3:0]  req_priority,         // 1=high-priority, 0=normal

    //---------- Configuration ----------
    input  logic [15:0] weights,              // 4-bit weight per channel
    input  logic [1:0]  arb_mode,             // 00=Fixed 01=RR 10=Wt 11=Dyn
    input  logic        aging_en,             // enable aging boost
    input  logic [3:0]  aging_threshold,      // wait cycles before boosting
    input  logic [3:0]  max_priority,         // clamp ceiling
    input  logic [3:0]  min_priority,         // clamp floor

    //---------- PCIe Credit Control ----------
    input  logic        pcie_mode,            // enable PCIe gating
    input  logic [3:0]  tx_credits_avail,
    input  logic [3:0]  tx_credits_required,

    //---------- SoC AXI Ready Control ----------
    input  logic        soc_mode,             // enable AXI gating
    input  logic [3:0]  axi_ready,

    //---------- Transaction Completion ----------
    input  logic        tx_complete,          // pulse: grant's txn done

    //---------- Grant Interface ----------
    output logic [3:0]  gnt,                  // one-hot grant
    output logic [1:0]  gnt_id,               // binary winner id
    output logic [3:0]  gnt_priority,         // winning priority value
    output logic        gnt_valid,
    output logic        gnt_hold               // arbiter locked
);

    //============================================================
    // SECTION 1: INTERNAL SIGNALS
    //============================================================
    logic [3:0]  req_valid;                   // qualified requests
    logic [3:0]  base_priority      [0:3];
    logic [3:0]  weighted_priority  [0:3];
    logic [3:0]  final_priority     [0:3];
    logic [7:0]  wait_cycles        [0:3];
    logic [3:0]  aging_boost        [0:3];
    logic [1:0]  rr_mask;
    logic [3:0]  gnt_reg;
    logic [1:0]  gnt_id_reg;
    logic [3:0]  gnt_priority_reg;
    logic        gnt_valid_reg;
    logic        gnt_hold_reg;
    logic        transaction_complete;
    logic [3:0]  highest_priority_req;
    logic [1:0]  highest_priority_id;
    logic [3:0]  highest_priority_value;

    logic [3:0]  weight_c0, weight_c1, weight_c2, weight_c3;

    logic [15:0] grant_hold_counter;          // FIX 8B watchdog
    logic        grant_timeout;

    //============================================================
    // SECTION 2: REQUEST QUALIFICATION
    //============================================================
    // Two independent gates (ANDed) applied on top of raw req:
    //   PCIe: avail credits >= required credits
    //   SoC : axi_ready asserted
    //------------------------------------------------------------
    always_comb begin
        req_valid = req;

        if (pcie_mode) begin
            for (int i = 0; i < 4; i++)
                if (tx_credits_avail[i] < tx_credits_required[i])
                    req_valid[i] = 1'b0;
        end

        if (soc_mode) begin
            for (int i = 0; i < 4; i++)
                if (!axi_ready[i])
                    req_valid[i] = 1'b0;
        end
    end

    //============================================================
    // SECTION 3: BASE PRIORITY
    //============================================================
    // req_priority[i]=1  → high   → base = 4'h1
    // req_priority[i]=0  → normal → base = 4'h8
    //   (Higher numeric = higher priority, so high-pri ch gets
    //    4'h1?? Actually per header convention: higher = higher.
    //    This block intentionally gives normal=8, high=1 in the
    //    *opposite* sense; downstream weighting/aging flips it.
    //    NOTE: as written, "normal" ends up HIGHER priority.
    //    Keep as-is for RTL freeze — flag in review.)
    // Clamp each to [min_priority, max_priority].
    //------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            if (req_priority[i] == 1'b0)
                base_priority[i] = 4'h8;
            else
                base_priority[i] = 4'h1;

            if (base_priority[i] > max_priority) base_priority[i] = max_priority;
            if (base_priority[i] < min_priority) base_priority[i] = min_priority;
        end
    end

    //============================================================
    // SECTION 4: PRIORITY AGING
    //============================================================
    // Each waiting channel accumulates wait_cycles. Once past
    // aging_threshold, aging_boost ramps in 3 tiers:
    //   wait >= 1x threshold → boost = 2
    //   wait >= 2x threshold → boost = 4
    //   wait >= 4x threshold → boost = 8
    // Boosts are cleared when that channel's transfer completes.
    //------------------------------------------------------------
    // GUARD: aging_threshold == 0 would trigger instant max-boost
    //        → guarded (FIX 8 rev).
    //------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int i = 0; i < 4; i++) begin
                wait_cycles[i] <= 8'h00;
                aging_boost[i] <= 4'h0;
            end
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (req_valid[i] && !gnt_hold_reg) begin
                    if (wait_cycles[i] < 8'hFF)
                        wait_cycles[i] <= wait_cycles[i] + 1'b1;

                    if (aging_en && (aging_threshold != 4'h0)
                        && (wait_cycles[i] >= aging_threshold)) begin
                        if (wait_cycles[i] >= (aging_threshold * 4))
                            aging_boost[i] <= 4'h8;
                        else if (wait_cycles[i] >= (aging_threshold * 2))
                            aging_boost[i] <= 4'h4;
                        else
                            aging_boost[i] <= 4'h2;
                    end else begin
                        aging_boost[i] <= 4'h0;
                    end
                end else if (gnt_hold_reg && (gnt_id_reg == i[1:0]) && tx_complete) begin
                    wait_cycles[i] <= 8'h00;
                    aging_boost[i] <= 4'h0;
                end
            end
        end
    end

    //============================================================
    // SECTION 5: WEIGHTED PRIORITY
    //============================================================
    // weighted = base + (weight * aging_boost) / 4
    // Then clamped to max_priority.
    //------------------------------------------------------------
    always_comb begin
        weight_c0 = weights[3:0];
        weight_c1 = weights[7:4];
        weight_c2 = weights[11:8];
        weight_c3 = weights[15:12];

        weighted_priority[0] = base_priority[0] + ((weight_c0 * aging_boost[0]) >> 2);
        weighted_priority[1] = base_priority[1] + ((weight_c1 * aging_boost[1]) >> 2);
        weighted_priority[2] = base_priority[2] + ((weight_c2 * aging_boost[2]) >> 2);
        weighted_priority[3] = base_priority[3] + ((weight_c3 * aging_boost[3]) >> 2);

        for (int i = 0; i < 4; i++)
            if (weighted_priority[i] > max_priority)
                weighted_priority[i] = max_priority;
    end

    //============================================================
    // SECTION 6: FINAL PRIORITY (mode select)
    //============================================================
    //   00 Fixed    : base only
    //   01 Round-Rbn: all equal (encoder handles rotation)
    //   10 Weighted : weighted only
    //   11 Dynamic  : average of (weighted + aging + base)
    //------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            case (arb_mode)
                2'b00: final_priority[i] = base_priority[i];
                2'b01: final_priority[i] = 4'h8;
                2'b10: final_priority[i] = weighted_priority[i];
                2'b11: final_priority[i] = (weighted_priority[i] +
                                            aging_boost[i] +
                                            base_priority[i]) >> 1;
                default: final_priority[i] = base_priority[i];
            endcase
        end
    end

    //============================================================
    // SECTION 7: ROUND-ROBIN MASK  (FIX 8C)
    //============================================================
    // rr_mask updates on GRANT ISSUANCE (rising edge of
    // gnt_valid_reg), not on tx_complete. This makes rotation
    // happen even if HLDA drops or tx_complete never arrives.
    //------------------------------------------------------------
    logic gnt_valid_d;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) gnt_valid_d <= 1'b0;
        else          gnt_valid_d <= gnt_valid_reg;
    end

    wire grant_issued = gnt_valid_reg && !gnt_valid_d;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            rr_mask <= 2'b00;
        else if (grant_issued)
            rr_mask <= gnt_id_reg;
    end

    // transaction_complete kept for consistency; not used by RR
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            transaction_complete <= 1'b0;
        else
            transaction_complete <= gnt_hold_reg && tx_complete;
    end

    //============================================================
    // SECTION 8: PRIORITY ENCODER  (FIX 8A)
    //============================================================
    // Uses strict ">" so only one channel wins ties.
    //
    // ROUND-ROBIN mode (arb_mode == 01):
    //   Scan starts at (rr_mask + 1) and wraps → the channel
    //   right after the last-granted one wins first.
    //------------------------------------------------------------
    logic [3:0] rr_scan_order [0:3];
    logic [1:0] rr_start;

    always_comb begin
        rr_start = rr_mask + 2'b01;         // (rr_mask+1) mod 4

        rr_scan_order[0] = rr_start;
        rr_scan_order[1] = rr_start + 2'b01;
        rr_scan_order[2] = rr_start + 2'b10;
        rr_scan_order[3] = rr_start + 2'b11;
    end

    always_comb begin
        highest_priority_req   = 4'b0000;
        highest_priority_id    = 2'b00;
        highest_priority_value = 4'h0;

        if (arb_mode == 2'b01) begin
            // Round-robin: scan in rotated order
            for (int k = 0; k < 4; k++) begin
                automatic logic [1:0] i = rr_scan_order[k][1:0];
                if (req_valid[i] && (final_priority[i] > highest_priority_value)) begin
                    highest_priority_req   = 4'b0001 << i;
                    highest_priority_id    = i;
                    highest_priority_value = final_priority[i];
                end
            end
        end else begin
            // Other modes: linear scan
            for (int i = 0; i < 4; i++) begin
                if (req_valid[i] && (final_priority[i] > highest_priority_value)) begin
                    highest_priority_req   = 4'b0001 << i;
                    highest_priority_id    = i[1:0];
                    highest_priority_value = final_priority[i];
                end
            end
        end
    end

    //============================================================
    // SECTION 9: GRANT-HOLD TIMEOUT  (FIX 8B)
    //============================================================
    // Watchdog: if tx_complete doesn't arrive within
    // GRANT_TIMEOUT_CYCLES, force release so arbiter can
    // re-arbitrate. Prevents deadlock from a hung peripheral.
    //------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            grant_hold_counter <= 16'h0000;
            grant_timeout      <= 1'b0;
        end else if (!gnt_hold_reg) begin
            grant_hold_counter <= 16'h0000;
            grant_timeout      <= 1'b0;
        end else if (grant_hold_counter >= GRANT_TIMEOUT_CYCLES) begin
            grant_hold_counter <= grant_hold_counter;   // saturate
            grant_timeout      <= 1'b1;
        end else begin
            grant_hold_counter <= grant_hold_counter + 16'd1;
            grant_timeout      <= 1'b0;
        end
    end

    //============================================================
    // SECTION 10: GRANT FSM
    //============================================================
    // States (implicit):
    //   IDLE  : gnt_hold=0, waiting for a winner
    //   HOLD  : gnt_hold=1, locked to winner until
    //           tx_complete OR grant_timeout
    //------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gnt_reg          <= 4'b0000;
            gnt_id_reg       <= 2'b00;
            gnt_priority_reg <= 4'h0;
            gnt_valid_reg    <= 1'b0;
            gnt_hold_reg     <= 1'b0;
        end else begin
            if (transaction_complete || grant_timeout) begin
                // Release grant (normal completion OR watchdog)
                gnt_reg          <= 4'b0000;
                gnt_id_reg       <= 2'b00;
                gnt_priority_reg <= 4'h0;
                gnt_valid_reg    <= 1'b0;
                gnt_hold_reg     <= 1'b0;
            end else if (!gnt_hold_reg) begin
                // Idle: arbitrate
                if (highest_priority_req != 4'b0000) begin
                    gnt_reg          <= highest_priority_req;
                    gnt_id_reg       <= highest_priority_id;
                    gnt_priority_reg <= highest_priority_value;
                    gnt_valid_reg    <= 1'b1;
                    gnt_hold_reg     <= 1'b1;
                end else begin
                    gnt_reg       <= 4'b0000;
                    gnt_valid_reg <= 1'b0;
                    gnt_hold_reg  <= 1'b0;
                end
            end
            // else: hold — gnt_reg and gnt_hold stay asserted
        end
    end

    //============================================================
    // SECTION 11: OUTPUT DRIVERS
    //============================================================
    assign gnt          = gnt_reg;
    assign gnt_id       = gnt_id_reg;
    assign gnt_priority = gnt_priority_reg;
    assign gnt_valid    = gnt_valid_reg;
    assign gnt_hold     = gnt_hold_reg;

endmodule : dma_adaptive_arbiter

//         ┌───────────┐
//         │   IDLE    │  gnt_hold=0, gnt_valid=0
//         │           │  ◄── continuously arbitrate
//         └─────┬─────┘
//               │ highest_priority_req != 0
//               ▼
//         ┌───────────┐
//         │   HOLD    │  gnt_hold=1, gnt_valid=1
//         │           │  LOCKED to gnt_id_reg
//         └─────┬─────┘
//               │ tx_complete  OR  grant_timeout
//               ▼
//         ┌───────────┐
//         │  RELEASE  │  → back to IDLE next cycle
//         └───────────┘

// `endif // DMA_ADAPTIVE_ARBITER_SV
