//============================================================
// File        : dma_priority.sv
// Description : DMA Priority & Request Arbitration Wrapper
//               - Extracts config from regfile (via dif)
//               - Qualifies requests (mask + DREQ/REQUEST)
//               - Instantiates dma_adaptive_arbiter
//               - Implements fixed/rotating encoder fallback
//               - Drives HRQ / DACK
//============================================================
// INTERVIEW POINTS:
//   1. Two arbitration PATHS:
//        adaptive_en=1 → dma_adaptive_arbiter
//        adaptive_en=0 → local fixed/rotating priority encoder
//   2. Requests qualified as: !masked && (DREQ || REQUEST_REG bit).
//   3. Rotating priority is a simple ring-update of ch_priority[].
//   4. DACK polarity is programmable (dack_sense).
//   5. HRQ is level = "any valid request pending".
//============================================================

`ifndef DMA_PRIORITY_SV
`define DMA_PRIORITY_SV

module dma_priority (
    dma_if          dif,     // external bus + probes
    dma_control_if  cif      // internal control handshake
);

import dma_reg_pkg::*;

    //============================================================
    // INTERNAL SIGNALS
    //============================================================
    logic       valid_dreq_any;         // any unmasked request pending
    logic       en_fixed_priority;      // legacy fixed mode active
    logic       en_rotating_priority;   // legacy rotating mode active
    logic [3:0] pencoder_out;           // one-hot winner (legacy path)
    logic [3:0] valid_dack_vec;         // current active grant vector

    logic [1:0] ch_priority [0:3];      // rotating priority values
    logic [3:0] ch_mask_bit;            // per-channel mask bits
    logic       priority_type;          // COMMAND_REG bit 4
    logic       dack_sense;             // COMMAND_REG bit 7

    //---------- Adaptive arbiter outputs ----------
    logic [3:0] adaptive_grant;
    logic [1:0] adaptive_gnt_id;
    logic [3:0] adaptive_gnt_priority;
    logic       adaptive_gnt_valid;
    logic       adaptive_gnt_hold;

    //---------- Adaptive arbiter config ----------
    logic [15:0] weights;
    logic [1:0]  arb_mode;
    logic        aging_en;
    logic [3:0]  aging_threshold;
    logic        adaptive_en;

    logic [3:0]  ch_req_priority [0:3]; // from CH_CTRL_REG[i][5:3]
    logic        prev_eop_n;             // for edge-detect of EOP

    //============================================================
    // 1. REGISTER FIELD EXTRACTION
    //============================================================
    // Pull all config fields out of the probe mirrors on dif.
    // NOTE: dif.CH_CTRL_REG_x[5:3] is priority_level from the
    //       ch_ctrl_reg_t packed struct.
    //------------------------------------------------------------
    always_comb begin
        ch_mask_bit   = dif.MASK_REG[3:0];
        priority_type = dif.COMMAND_REG[4];      // 0=Fixed, 1=Rotating
        dack_sense    = dif.COMMAND_REG[7];      // DACK polarity

        ch_req_priority[0] = {1'b0, dif.CH_CTRL_REG_0[5:3]};
        ch_req_priority[1] = {1'b0, dif.CH_CTRL_REG_1[5:3]};
        ch_req_priority[2] = {1'b0, dif.CH_CTRL_REG_2[5:3]};
        ch_req_priority[3] = {1'b0, dif.CH_CTRL_REG_3[5:3]};

        // Priority control register fields (24-bit)
        weights         = dif.PRIORITY_CTRL_REG[15:0];   // 4×4-bit weights
        adaptive_en     = dif.PRIORITY_CTRL_REG[16];
        arb_mode        = dif.PRIORITY_CTRL_REG[18:17];
        aging_en        = dif.PRIORITY_CTRL_REG[19];
        aging_threshold = dif.PRIORITY_CTRL_REG[23:20];

        // Mode decode: adaptive path takes precedence
        en_fixed_priority    = !adaptive_en && !priority_type;
        en_rotating_priority = !adaptive_en &&  priority_type;
    end

    //============================================================
    // 2. REQUEST QUALIFICATION
    //============================================================
    // Valid DREQ per channel = NOT masked AND (pin DREQ OR SW request)
    //   pin DREQ     = external hardware request
    //   REQUEST_REG  = software-initiated request bit
    //------------------------------------------------------------
    always_comb begin
        cif.VALID_DREQ0 = !ch_mask_bit[0] && (dif.DREQ[0] || dif.REQUEST_REG[0]);
        cif.VALID_DREQ1 = !ch_mask_bit[1] && (dif.DREQ[1] || dif.REQUEST_REG[1]);
        cif.VALID_DREQ2 = !ch_mask_bit[2] && (dif.DREQ[2] || dif.REQUEST_REG[2]);
        cif.VALID_DREQ3 = !ch_mask_bit[3] && (dif.DREQ[3] || dif.REQUEST_REG[3]);

        valid_dreq_any = cif.VALID_DREQ0 || cif.VALID_DREQ1 ||
                         cif.VALID_DREQ2 || cif.VALID_DREQ3;
    end

    //============================================================
    // 3. ADAPTIVE ARBITER INSTANCE
    //============================================================
    // PCIe / SoC credit gating disabled (tied to pass-through).
    // tx_complete = cif.timeout (TC reached).
    //------------------------------------------------------------
    dma_adaptive_arbiter ADAPTIVE_ARB (
        .clk                 (dif.CLK),
        .reset_n             (~dif.RESET),     // polarity inversion

        .req                 ({cif.VALID_DREQ3, cif.VALID_DREQ2,
                               cif.VALID_DREQ1, cif.VALID_DREQ0}),
        .req_priority        ({ch_req_priority[3][0], ch_req_priority[2][0],
                               ch_req_priority[1][0], ch_req_priority[0][0]}),

        .weights             (weights),
        .arb_mode            (arb_mode),
        .aging_en            (aging_en),
        .aging_threshold     (aging_threshold),
        .max_priority        (4'hF),
        .min_priority        (4'h0),

        // PCIe credit gating disabled
        .pcie_mode           (1'b0),
        .tx_credits_avail    (4'hF),
        .tx_credits_required (4'h1),
        // SoC AXI gating disabled
        .soc_mode            (1'b0),
        .axi_ready           (4'hF),

        .tx_complete         (cif.timeout),    // TC ends grant-hold

        .gnt                 (adaptive_grant),
        .gnt_id              (adaptive_gnt_id),
        .gnt_priority        (adaptive_gnt_priority),
        .gnt_valid           (adaptive_gnt_valid),
        .gnt_hold            (adaptive_gnt_hold)
    );

    //============================================================
    // 4. PRIORITY ENCODER (Fixed & Rotating — legacy path)
    //============================================================
    // Three cases:
    //   adaptive_en        → forward the adaptive arbiter grant
    //   rotating           → compare ch_priority[], higher wins
    //   fixed              → lowest channel index wins
    //------------------------------------------------------------
    always_comb begin
        pencoder_out = 4'b0000;

        if (adaptive_en) begin
            pencoder_out = adaptive_grant;

        end else if (en_rotating_priority && valid_dreq_any) begin
            logic [1:0] highest_pri;
            highest_pri  = 2'b00;
            pencoder_out = 4'b0000;

            // Strict ">" so ties favor lower channel index
            if (cif.VALID_DREQ0) begin
                highest_pri  = ch_priority[0];
                pencoder_out = 4'b0001;
            end
            if (cif.VALID_DREQ1 &&
                (ch_priority[1] > highest_pri || pencoder_out == 4'b0000)) begin
                highest_pri  = ch_priority[1];
                pencoder_out = 4'b0010;
            end
            if (cif.VALID_DREQ2 &&
                (ch_priority[2] > highest_pri || pencoder_out == 4'b0000)) begin
                highest_pri  = ch_priority[2];
                pencoder_out = 4'b0100;
            end
            if (cif.VALID_DREQ3 &&
                (ch_priority[3] > highest_pri || pencoder_out == 4'b0000)) begin
                highest_pri  = ch_priority[3];
                pencoder_out = 4'b1000;
            end

        end else if (en_fixed_priority && valid_dreq_any) begin
            // Fixed priority: CH0 > CH1 > CH2 > CH3
            if      (cif.VALID_DREQ0) pencoder_out = 4'b0001;
            else if (cif.VALID_DREQ1) pencoder_out = 4'b0010;
            else if (cif.VALID_DREQ2) pencoder_out = 4'b0100;
            else if (cif.VALID_DREQ3) pencoder_out = 4'b1000;
        end
    end

    //============================================================
    // 5. CONTROL INTERFACE DRIVE
    //============================================================
    // Route winner into the control interface. Two paths:
    //   adaptive: use gnt_valid||gnt_hold (grant persists)
    //   legacy  : one-hot pencoder_out
    //------------------------------------------------------------
    always_comb begin
        valid_dack_vec = pencoder_out;

        if (adaptive_en) begin
            cif.VALID_DACK   = (adaptive_gnt_valid || adaptive_gnt_hold);
            cif.active_dack  = adaptive_grant;
            cif.active_chnum = adaptive_gnt_id;
        end else begin
            cif.VALID_DACK   = |valid_dack_vec;
            cif.active_dack  = valid_dack_vec;

            // One-hot → binary channel id
            case (valid_dack_vec)
                4'b0001: cif.active_chnum = 2'b00;
                4'b0010: cif.active_chnum = 2'b01;
                4'b0100: cif.active_chnum = 2'b10;
                4'b1000: cif.active_chnum = 2'b11;
                default: cif.active_chnum = 2'b00;
            endcase
        end
    end

    //============================================================
    // 6. ROTATING PRIORITY HISTORY
    //============================================================
    // After each completed transfer (EOP edge or timeout), the
    // just-served channel is demoted to 0 and others bump up.
    // Initial order (on reset): CH0 highest, CH3 lowest.
    //------------------------------------------------------------
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) prev_eop_n <= 1'b1;
        else           prev_eop_n <= cif.eop;
    end

    // xfer_done fires on EOP falling edge OR on timeout
    wire xfer_done = (!cif.eop && prev_eop_n) || cif.timeout;

    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET || dif.MASTER_CLEAR_CMD) begin
            // Default priority: CH0=3(highest) .. CH3=0(lowest)
            ch_priority[0] <= 2'b11;
            ch_priority[1] <= 2'b10;
            ch_priority[2] <= 2'b01;
            ch_priority[3] <= 2'b00;
        end else if (en_rotating_priority && xfer_done) begin
            // Demote the channel just served → others rotate up
            case (cif.active_chnum)
                2'b00: begin
                    ch_priority[0] <= 2'b00;
                    ch_priority[1] <= 2'b11;
                    ch_priority[2] <= 2'b10;
                    ch_priority[3] <= 2'b01;
                end
                2'b01: begin
                    ch_priority[1] <= 2'b00;
                    ch_priority[2] <= 2'b11;
                    ch_priority[3] <= 2'b10;
                    ch_priority[0] <= 2'b01;
                end
                2'b10: begin
                    ch_priority[2] <= 2'b00;
                    ch_priority[3] <= 2'b11;
                    ch_priority[0] <= 2'b10;
                    ch_priority[1] <= 2'b01;
                end
                2'b11: begin
                    ch_priority[3] <= 2'b00;
                    ch_priority[0] <= 2'b11;
                    ch_priority[1] <= 2'b10;
                    ch_priority[2] <= 2'b01;
                end
                default: ;
            endcase
        end
    end

    //============================================================
    // 7. OUTPUT PIN DRIVERS
    //============================================================
    // HRQ = "any valid request" — level signal to CPU.
    // DACK[i] active only when HLDA=1 AND that channel won.
    // dack_sense selects polarity (1=active-low).
    //------------------------------------------------------------
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) begin
            dif.HRQ  <= 1'b0;
            dif.DACK <= 4'b0000;
        end else begin
            dif.HRQ <= valid_dreq_any;

            for (int i = 0; i < 4; i++) begin
                if (dif.HLDA && ((adaptive_en && adaptive_grant[i]) ||
                                 (!adaptive_en && valid_dack_vec[i]))) begin
                    dif.DACK[i] <= dack_sense ? 1'b0 : 1'b1;
                end else begin
                    dif.DACK[i] <= dack_sense ? 1'b1 : 1'b0;
                end
            end
        end
    end

endmodule : dma_priority

`endif // DMA_PRIORITY_SV
