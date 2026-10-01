//============================================================
// File        : dma_regfile.sv
// Description : DMA Register File
//               - Holds all config/status registers
//               - Handles CPU read/write via byte pointer
//               - Auto-updates CURR_ADDR / CURR_WC on XFER_PULSE
//============================================================
// INTERVIEW POINTS:
//   1. Two-port role: CPU side (byte_pointer) + DMA side (auto).
//   2. 16-bit regs → 2 CPU accesses (low/high byte).
//   3. 24-bit PRIORITY reg → 3 CPU accesses (priority_byte_ptr).
//   4. BASE_ADDR write also mirrors into CURR_ADDR (8237 rule).
//   5. CURR_WORD_COUNT decrement is gated at 0 (FIX 3).
//   6. XFER_PULSE channel select uses cif.active_chnum (FIX 7).
//   7. DB is tri-stated unless a valid CPU read is in progress.
//============================================================

`ifndef DMA_REGFILE_SV
`define DMA_REGFILE_SV

module dma_regfile(
    dma_if         dif,
    dma_control_if cif     // provides active_chnum for XFER_PULSE mux
);

import dma_reg_pkg::*;

    //============================================================
    // SECTION 1: REGISTER DECLARATIONS
    //============================================================
    // Packed structs come from dma_reg_pkg — using them directly
    // gives us named fields (.circ_en, .mode_sel, etc.).
    //------------------------------------------------------------
    mode_reg_t          MODE_REG [0:3];
    cmd_reg_t           COMMAND_REG;
    req_reg_t           REQUEST_REG;
    mask_reg_t          MASK_REG;

    logic [15:0]        BASE_ADDR_REG [0:3];
    logic [15:0]        CURR_ADDR_REG [0:3];
    logic [15:0]        BASE_WORD_COUNT_REG [0:3];
    logic [15:0]        CURR_WORD_COUNT_REG [0:3];

    logic               byte_pointer;       // for 16-bit regs
    logic [1:0]         priority_byte_ptr;  // for 24-bit PRIORITY reg

    ch_ctrl_reg_t       CH_CTRL_REG [0:3];
    buf_size_reg_t      BUF_SIZE_REG [0:3];
    priority_ctrl_reg_t PRIORITY_CTRL_REG;

    logic [7:0]         reg_read_data;      // internal read mux output
    logic [7:0]         io_write_data;      // captured write data

    //============================================================
    // SECTION 2: LEVEL-DETECT STROBES
    //============================================================
    // Level-detect (not edge) → valid combinationally whenever the
    // CPU bus cycle is present. Used to gate register updates.
    //------------------------------------------------------------
    wire reg_wr_active = (!dif.CS_N && !dif.HLDA && !dif.IOW_N);
    wire reg_rd_active = (!dif.CS_N && !dif.HLDA && !dif.IOR_N);

    //============================================================
    // SECTION 3: BYTE-CONTROLLED REGISTER ACCESS DETECTION
    //============================================================
    // Byte-pointer toggles for:
    //   0x00–0x07 (base addr / base word count) — 16-bit regs
    //   0x14–0x17 (buffer size)                 — 16-bit regs
    //------------------------------------------------------------
    logic access_wr_byte, access_rd_byte;

    always_comb begin
        access_wr_byte = reg_wr_active &&
            ((dif.ADDR_L >= 5'h00 && dif.ADDR_L <= 5'h07) ||
             (dif.ADDR_L >= 5'h14 && dif.ADDR_L <= 5'h17));

        access_rd_byte = reg_rd_active &&
            ((dif.ADDR_L >= 5'h00 && dif.ADDR_L <= 5'h07) ||
             (dif.ADDR_L >= 5'h14 && dif.ADDR_L <= 5'h17));
    end

    //============================================================
    // SECTION 4: PRIORITY REGISTER ACCESS DETECTION (24-bit)
    //============================================================
    logic access_wr_prio, access_rd_prio;

    always_comb begin
        access_wr_prio = reg_wr_active && (dif.ADDR_L == PRIORITY_CTRL_REG_ADDR);
        access_rd_prio = reg_rd_active && (dif.ADDR_L == PRIORITY_CTRL_REG_ADDR);
    end

    //============================================================
    // SECTION 5: TWO-STAGE DELAY REGISTERS
    //============================================================
    // Purpose: detect a SINGLE completed bus access (rising edge
    // of the level strobe) → toggle the byte pointer only ONCE.
    // d1 = delayed 1 cycle, d2 = delayed 2 cycles.
    // Condition (d1 && !d2) fires a 1-cycle pulse after strobe.
    //------------------------------------------------------------
    logic access_wr_byte_d1, access_wr_byte_d2;
    logic access_rd_byte_d1, access_rd_byte_d2;
    logic access_wr_prio_d1, access_wr_prio_d2;
    logic access_rd_prio_d1, access_rd_prio_d2;

    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) begin
            access_wr_byte_d1 <= 1'b0; access_wr_byte_d2 <= 1'b0;
            access_rd_byte_d1 <= 1'b0; access_rd_byte_d2 <= 1'b0;
            access_wr_prio_d1 <= 1'b0; access_wr_prio_d2 <= 1'b0;
            access_rd_prio_d1 <= 1'b0; access_rd_prio_d2 <= 1'b0;
        end else begin
            access_wr_byte_d1 <= access_wr_byte;   access_wr_byte_d2 <= access_wr_byte_d1;
            access_rd_byte_d1 <= access_rd_byte;   access_rd_byte_d2 <= access_rd_byte_d1;
            access_wr_prio_d1 <= access_wr_prio;   access_wr_prio_d2 <= access_wr_prio_d1;
            access_rd_prio_d1 <= access_rd_prio;   access_rd_prio_d2 <= access_rd_prio_d1;
        end
    end

    //============================================================
    // SECTION 6 & 7: INTERFACE EXPORTS (probes for UVM)
    //============================================================
    // These expose internal registers on the interface so the UVM
    // scoreboard / coverage can observe them without hierarchical
    // paths. No RTL function — pure observation.
    //------------------------------------------------------------
    assign dif.MODE_REG_0 = MODE_REG[0];  assign dif.MODE_REG_1 = MODE_REG[1];
    assign dif.MODE_REG_2 = MODE_REG[2];  assign dif.MODE_REG_3 = MODE_REG[3];

    assign dif.COMMAND_REG = COMMAND_REG;
    assign dif.REQUEST_REG = REQUEST_REG;
    assign dif.MASK_REG    = MASK_REG;

    assign dif.BASE_ADDR_0 = BASE_ADDR_REG[0];
    assign dif.BASE_ADDR_1 = BASE_ADDR_REG[1];
    assign dif.BASE_ADDR_2 = BASE_ADDR_REG[2];
    assign dif.BASE_ADDR_3 = BASE_ADDR_REG[3];

    assign dif.CURR_ADDR_0 = CURR_ADDR_REG[0];
    assign dif.CURR_ADDR_1 = CURR_ADDR_REG[1];
    assign dif.CURR_ADDR_2 = CURR_ADDR_REG[2];
    assign dif.CURR_ADDR_3 = CURR_ADDR_REG[3];

    assign dif.BASE_WC_0 = BASE_WORD_COUNT_REG[0];
    assign dif.BASE_WC_1 = BASE_WORD_COUNT_REG[1];
    assign dif.BASE_WC_2 = BASE_WORD_COUNT_REG[2];
    assign dif.BASE_WC_3 = BASE_WORD_COUNT_REG[3];

    assign dif.CURR_WC_0 = CURR_WORD_COUNT_REG[0];
    assign dif.CURR_WC_1 = CURR_WORD_COUNT_REG[1];
    assign dif.CURR_WC_2 = CURR_WORD_COUNT_REG[2];
    assign dif.CURR_WC_3 = CURR_WORD_COUNT_REG[3];

    assign dif.CH_CTRL_REG_0 = CH_CTRL_REG[0];
    assign dif.CH_CTRL_REG_1 = CH_CTRL_REG[1];
    assign dif.CH_CTRL_REG_2 = CH_CTRL_REG[2];
    assign dif.CH_CTRL_REG_3 = CH_CTRL_REG[3];

    assign dif.BUF_SIZE_REG_0 = BUF_SIZE_REG[0].buffer_size;
    assign dif.BUF_SIZE_REG_1 = BUF_SIZE_REG[1].buffer_size;
    assign dif.BUF_SIZE_REG_2 = BUF_SIZE_REG[2].buffer_size;
    assign dif.BUF_SIZE_REG_3 = BUF_SIZE_REG[3].buffer_size;

    assign dif.PRIORITY_CTRL_REG = PRIORITY_CTRL_REG;

    //============================================================
    // SECTION 8: WRITE DATA CAPTURE
    //============================================================
    always_comb io_write_data = dif.DB;

    //============================================================
    // SECTION 9: ACTIVE CHANNEL FOR XFER_PULSE MUX
    //============================================================
    // FIX 7: use cif.active_chnum, NOT dif.DACK.
    // Reason: DACK polarity is programmable (dack_sense) — using
    // it as a channel selector silently breaks when active-low.
    //------------------------------------------------------------
    logic [1:0] active_ch;
    assign active_ch = cif.active_chnum;

    //============================================================
    // SECTION 10: MAIN REGISTER UPDATE BLOCK
    //============================================================
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin

        //--------------------------------------------------------
        // RESET
        //--------------------------------------------------------
        if (dif.RESET) begin
            foreach (MODE_REG[i])            MODE_REG[i]            <= '{default:'0};
            COMMAND_REG  <= '{default:'0};
            REQUEST_REG  <= '{default:'0};
            MASK_REG     <= '{default:'0};

            foreach (BASE_ADDR_REG[i])       BASE_ADDR_REG[i]       <= 16'h0000;
            foreach (CURR_ADDR_REG[i])       CURR_ADDR_REG[i]       <= 16'h0000;
            foreach (BASE_WORD_COUNT_REG[i]) BASE_WORD_COUNT_REG[i] <= 16'h0000;
            foreach (CURR_WORD_COUNT_REG[i]) CURR_WORD_COUNT_REG[i] <= 16'h0000;

            byte_pointer      <= 1'b0;
            priority_byte_ptr <= 2'b00;

            foreach (CH_CTRL_REG[i])  CH_CTRL_REG[i]  <= '{default:'0};
            foreach (BUF_SIZE_REG[i]) BUF_SIZE_REG[i] <= '{default:'0};
            PRIORITY_CTRL_REG                         <= '{default:'0};

        end else begin

            //--------------------------------------------------------
            // BASE ADDR WRITES (0x00,0x02,0x04,0x06)
            //   Low byte write  → also loads CURR_ADDR low
            //   High byte write → also loads CURR_ADDR high
            // (8237 rule: writing base addr preloads current addr.)
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == BASE_ADDR_REG_CH0_ADDR) begin
                if (!byte_pointer) begin
                    BASE_ADDR_REG[0][7:0] <= io_write_data;
                    CURR_ADDR_REG[0][7:0] <= io_write_data;
                end else begin
                    BASE_ADDR_REG[0][15:8] <= io_write_data;
                    CURR_ADDR_REG[0][15:8] <= io_write_data;
                end
            end
            // (same pattern for CH1/CH2/CH3 — omitted for brevity)

            if (reg_wr_active && dif.ADDR_L == BASE_ADDR_REG_CH1_ADDR) begin
                if (!byte_pointer) begin
                    BASE_ADDR_REG[1][7:0]  <= io_write_data;
                    CURR_ADDR_REG[1][7:0]  <= io_write_data;
                end else begin
                    BASE_ADDR_REG[1][15:8] <= io_write_data;
                    CURR_ADDR_REG[1][15:8] <= io_write_data;
                end
            end
            if (reg_wr_active && dif.ADDR_L == BASE_ADDR_REG_CH2_ADDR) begin
                if (!byte_pointer) begin
                    BASE_ADDR_REG[2][7:0]  <= io_write_data;
                    CURR_ADDR_REG[2][7:0]  <= io_write_data;
                end else begin
                    BASE_ADDR_REG[2][15:8] <= io_write_data;
                    CURR_ADDR_REG[2][15:8] <= io_write_data;
                end
            end
            if (reg_wr_active && dif.ADDR_L == BASE_ADDR_REG_CH3_ADDR) begin
                if (!byte_pointer) begin
                    BASE_ADDR_REG[3][7:0]  <= io_write_data;
                    CURR_ADDR_REG[3][7:0]  <= io_write_data;
                end else begin
                    BASE_ADDR_REG[3][15:8] <= io_write_data;
                    CURR_ADDR_REG[3][15:8] <= io_write_data;
                end
            end

            //--------------------------------------------------------
            // BASE WORD COUNT WRITES (0x01,0x03,0x05,0x07)
            //   Same mirroring rule → also updates CURR_WORD_COUNT
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == BASE_WORD_COUNT_REG_CH0_ADDR) begin
                if (!byte_pointer) begin
                    BASE_WORD_COUNT_REG[0][7:0]  <= io_write_data;
                    CURR_WORD_COUNT_REG[0][7:0]  <= io_write_data;
                end else begin
                    BASE_WORD_COUNT_REG[0][15:8] <= io_write_data;
                    CURR_WORD_COUNT_REG[0][15:8] <= io_write_data;
                end
            end
            // (same pattern for CH1/CH2/CH3)
            if (reg_wr_active && dif.ADDR_L == BASE_WORD_COUNT_REG_CH1_ADDR) begin
                if (!byte_pointer) begin
                    BASE_WORD_COUNT_REG[1][7:0]  <= io_write_data;
                    CURR_WORD_COUNT_REG[1][7:0]  <= io_write_data;
                end else begin
                    BASE_WORD_COUNT_REG[1][15:8] <= io_write_data;
                    CURR_WORD_COUNT_REG[1][15:8] <= io_write_data;
                end
            end
            if (reg_wr_active && dif.ADDR_L == BASE_WORD_COUNT_REG_CH2_ADDR) begin
                if (!byte_pointer) begin
                    BASE_WORD_COUNT_REG[2][7:0]  <= io_write_data;
                    CURR_WORD_COUNT_REG[2][7:0]  <= io_write_data;
                end else begin
                    BASE_WORD_COUNT_REG[2][15:8] <= io_write_data;
                    CURR_WORD_COUNT_REG[2][15:8] <= io_write_data;
                end
            end
            if (reg_wr_active && dif.ADDR_L == BASE_WORD_COUNT_REG_CH3_ADDR) begin
                if (!byte_pointer) begin
                    BASE_WORD_COUNT_REG[3][7:0]  <= io_write_data;
                    CURR_WORD_COUNT_REG[3][7:0]  <= io_write_data;
                end else begin
                    BASE_WORD_COUNT_REG[3][15:8] <= io_write_data;
                    CURR_WORD_COUNT_REG[3][15:8] <= io_write_data;
                end
            end

            //--------------------------------------------------------
            // DMA-SIDE AUTO-UPDATE (on each XFER_PULSE)
            //   - Increment/decrement CURR_ADDR
            //   - Circular wrap if circ_en + valid buffer_size
            //   - Decrement CURR_WORD_COUNT (gated at 0 → FIX 3)
            //--------------------------------------------------------
            if (dif.XFER_PULSE) begin
                case (active_ch)

                    //----------- CHANNEL 0 -----------
                    2'b00: begin
                        // Circular wrap takes precedence over inc/dec
                        if (CH_CTRL_REG[0].circ_en &&
                            BUF_SIZE_REG[0].buffer_size != 16'h0000) begin
                            if (CURR_ADDR_REG[0] >=
                                (BASE_ADDR_REG[0] + BUF_SIZE_REG[0].buffer_size - 16'd1))
                                CURR_ADDR_REG[0] <= BASE_ADDR_REG[0];
                            else
                                CURR_ADDR_REG[0] <= CURR_ADDR_REG[0] + 16'd1;
                        end else begin
                            CURR_ADDR_REG[0] <= MODE_REG[0].addr_inc_dec
                                ? (CURR_ADDR_REG[0] - 16'd1)
                                : (CURR_ADDR_REG[0] + 16'd1);
                        end

                        // FIX 3: never underflow below 0
                        if (CURR_WORD_COUNT_REG[0] != 16'h0000)
                            CURR_WORD_COUNT_REG[0] <= CURR_WORD_COUNT_REG[0] - 16'd1;
                    end

                    //----------- CHANNEL 1 -----------
                    2'b01: begin
                        if (CH_CTRL_REG[1].circ_en &&
                            BUF_SIZE_REG[1].buffer_size != 16'h0000) begin
                            if (CURR_ADDR_REG[1] >=
                                (BASE_ADDR_REG[1] + BUF_SIZE_REG[1].buffer_size - 16'd1))
                                CURR_ADDR_REG[1] <= BASE_ADDR_REG[1];
                            else
                                CURR_ADDR_REG[1] <= CURR_ADDR_REG[1] + 16'd1;
                        end else begin
                            CURR_ADDR_REG[1] <= MODE_REG[1].addr_inc_dec
                                ? (CURR_ADDR_REG[1] - 16'd1)
                                : (CURR_ADDR_REG[1] + 16'd1);
                        end

                        if (CURR_WORD_COUNT_REG[1] != 16'h0000)
                            CURR_WORD_COUNT_REG[1] <= CURR_WORD_COUNT_REG[1] - 16'd1;
                    end

                    //----------- CHANNEL 2 -----------
                    2'b10: begin
                        if (CH_CTRL_REG[2].circ_en &&
                            BUF_SIZE_REG[2].buffer_size != 16'h0000) begin
                            if (CURR_ADDR_REG[2] >=
                                (BASE_ADDR_REG[2] + BUF_SIZE_REG[2].buffer_size - 16'd1))
                                CURR_ADDR_REG[2] <= BASE_ADDR_REG[2];
                            else
                                CURR_ADDR_REG[2] <= CURR_ADDR_REG[2] + 16'd1;
                        end else begin
                            CURR_ADDR_REG[2] <= MODE_REG[2].addr_inc_dec
                                ? (CURR_ADDR_REG[2] - 16'd1)
                                : (CURR_ADDR_REG[2] + 16'd1);
                        end

                        if (CURR_WORD_COUNT_REG[2] != 16'h0000)
                            CURR_WORD_COUNT_REG[2] <= CURR_WORD_COUNT_REG[2] - 16'd1;
                    end

                    //----------- CHANNEL 3 -----------
                    2'b11: begin
                        if (CH_CTRL_REG[3].circ_en &&
                            BUF_SIZE_REG[3].buffer_size != 16'h0000) begin
                            if (CURR_ADDR_REG[3] >=
                                (BASE_ADDR_REG[3] + BUF_SIZE_REG[3].buffer_size - 16'd1))
                                CURR_ADDR_REG[3] <= BASE_ADDR_REG[3];
                            else
                                CURR_ADDR_REG[3] <= CURR_ADDR_REG[3] + 16'd1;
                        end else begin
                            CURR_ADDR_REG[3] <= MODE_REG[3].addr_inc_dec
                                ? (CURR_ADDR_REG[3] - 16'd1)
                                : (CURR_ADDR_REG[3] + 16'd1);
                        end

                        if (CURR_WORD_COUNT_REG[3] != 16'h0000)
                            CURR_WORD_COUNT_REG[3] <= CURR_WORD_COUNT_REG[3] - 16'd1;
                    end

                    default: ;
                endcase
            end

            //--------------------------------------------------------
            // CONTROL REGISTER WRITES
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == COMMAND_REG_ADDR)
                COMMAND_REG <= cmd_reg_t'(io_write_data);

            if (reg_wr_active && dif.ADDR_L == REQUEST_REG_ADDR)
                REQUEST_REG <= req_reg_t'(io_write_data);

            // Mask write — single-bit mode (0x0A):
            //   data[1:0] = channel, data[2] = mask bit
            if (reg_wr_active && dif.ADDR_L == MASK_REG_ADDR)
                MASK_REG.ch_mask_bit[io_write_data[1:0]] <= io_write_data[2];
            // Mask write — full-byte mode (0x0F)
            else if (reg_wr_active && dif.ADDR_L == WRITE_MASK_REG_ADDR)
                MASK_REG.ch_mask_bit <= io_write_data[3:0];

            if (reg_wr_active && dif.ADDR_L == CLEAR_MASK_REG_ADDR)
                MASK_REG.ch_mask_bit <= 4'b0000;

            // MODE reg is per-channel: ch selected by data[1:0]
            if (reg_wr_active && dif.ADDR_L == MODE_REG_ADDR)
                MODE_REG[io_write_data[1:0]] <= mode_reg_t'(io_write_data);

            //--------------------------------------------------------
            // ENHANCED CHANNEL CONTROL (0x10-0x13)
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == CH_CTRL_REG_CH0_ADDR) CH_CTRL_REG[0] <= ch_ctrl_reg_t'(io_write_data);
            if (reg_wr_active && dif.ADDR_L == CH_CTRL_REG_CH1_ADDR) CH_CTRL_REG[1] <= ch_ctrl_reg_t'(io_write_data);
            if (reg_wr_active && dif.ADDR_L == CH_CTRL_REG_CH2_ADDR) CH_CTRL_REG[2] <= ch_ctrl_reg_t'(io_write_data);
            if (reg_wr_active && dif.ADDR_L == CH_CTRL_REG_CH3_ADDR) CH_CTRL_REG[3] <= ch_ctrl_reg_t'(io_write_data);

            //--------------------------------------------------------
            // BUFFER SIZE WRITES (0x14-0x17) — byte-pointer controlled
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == BUF_SIZE_REG_CH0_ADDR) begin
                if (!byte_pointer) BUF_SIZE_REG[0].buffer_size[7:0]  <= io_write_data;
                else               BUF_SIZE_REG[0].buffer_size[15:8] <= io_write_data;
            end
            if (reg_wr_active && dif.ADDR_L == BUF_SIZE_REG_CH1_ADDR) begin
                if (!byte_pointer) BUF_SIZE_REG[1].buffer_size[7:0]  <= io_write_data;
                else               BUF_SIZE_REG[1].buffer_size[15:8] <= io_write_data;
            end
            if (reg_wr_active && dif.ADDR_L == BUF_SIZE_REG_CH2_ADDR) begin
                if (!byte_pointer) BUF_SIZE_REG[2].buffer_size[7:0]  <= io_write_data;
                else               BUF_SIZE_REG[2].buffer_size[15:8] <= io_write_data;
            end
            if (reg_wr_active && dif.ADDR_L == BUF_SIZE_REG_CH3_ADDR) begin
                if (!byte_pointer) BUF_SIZE_REG[3].buffer_size[7:0]  <= io_write_data;
                else               BUF_SIZE_REG[3].buffer_size[15:8] <= io_write_data;
            end

            //--------------------------------------------------------
            // PRIORITY CONTROL REG (0x18, 24-bit) — 3-byte access
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == PRIORITY_CTRL_REG_ADDR) begin
                case (priority_byte_ptr)
                    2'b00: PRIORITY_CTRL_REG[7:0]   <= io_write_data;
                    2'b01: PRIORITY_CTRL_REG[15:8]  <= io_write_data;
                    2'b10: PRIORITY_CTRL_REG[23:16] <= io_write_data;
                    default: PRIORITY_CTRL_REG[7:0] <= io_write_data;
                endcase
            end

            //--------------------------------------------------------
            // MASTER CLEAR (0x0D) — resets control regs + pointers
            //  NOTE: does NOT clear BASE_ADDR / WORD_COUNT (8237 rule:
            //        master clear only clears command/mode/mask/ptr).
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == MASTER_CLEAR_ADDR) begin
                COMMAND_REG  <= '{default:'0};
                REQUEST_REG  <= '{default:'0};
                MASK_REG     <= '{default:'0};
                foreach (MODE_REG[i])     MODE_REG[i]     <= '{default:'0};
                foreach (CH_CTRL_REG[i])  CH_CTRL_REG[i]  <= '{default:'0};
                foreach (BUF_SIZE_REG[i]) BUF_SIZE_REG[i] <= '{default:'0};
                PRIORITY_CTRL_REG <= '{default:'0};
                byte_pointer      <= 1'b0;
                priority_byte_ptr <= 2'b00;
            end

            //--------------------------------------------------------
            // BYTE-POINTER TOGGLE
            //   Priority order (mutually exclusive in practice):
            //     1. Clear-byte-pointer write → reset both pointers
            //     2. 16-bit reg access pulse → toggle byte_pointer
            //     3. 24-bit reg access pulse → increment priority ptr
            //        (wraps 2 → 0)
            //--------------------------------------------------------
            if (reg_wr_active && dif.ADDR_L == CLEAR_BYTE_POINTER_ADDR) begin
                byte_pointer      <= 1'b0;
                priority_byte_ptr <= 2'b00;
            end
            else if (access_wr_byte_d1 && !access_wr_byte_d2) begin
                byte_pointer <= ~byte_pointer;
            end
            else if (access_rd_byte_d1 && !access_rd_byte_d2) begin
                byte_pointer <= ~byte_pointer;
            end
            else if (access_wr_prio_d1 && !access_wr_prio_d2) begin
                if (priority_byte_ptr == 2'b10) priority_byte_ptr <= 2'b00;
                else                            priority_byte_ptr <= priority_byte_ptr + 2'b01;
            end
            else if (access_rd_prio_d1 && !access_rd_prio_d2) begin
                if (priority_byte_ptr == 2'b10) priority_byte_ptr <= 2'b00;
                else                            priority_byte_ptr <= priority_byte_ptr + 2'b01;
            end
        end
    end

    //============================================================
    // SECTION 11: READ DATA MULTIPLEXER (combinational)
    //============================================================
    // NOTE: reading 0x00–0x07 returns CURR_ADDR / CURR_WC (not
    //       the base) — 8237 behaviour.
    //------------------------------------------------------------
    always_comb begin
        reg_read_data = 8'h00;

        case (dif.ADDR_L)

            // Base addr reads → return CURRENT address (per byte ptr)
            BASE_ADDR_REG_CH0_ADDR : reg_read_data = byte_pointer ? CURR_ADDR_REG[0][15:8] : CURR_ADDR_REG[0][7:0];
            BASE_ADDR_REG_CH1_ADDR : reg_read_data = byte_pointer ? CURR_ADDR_REG[1][15:8] : CURR_ADDR_REG[1][7:0];
            BASE_ADDR_REG_CH2_ADDR : reg_read_data = byte_pointer ? CURR_ADDR_REG[2][15:8] : CURR_ADDR_REG[2][7:0];
            BASE_ADDR_REG_CH3_ADDR : reg_read_data = byte_pointer ? CURR_ADDR_REG[3][15:8] : CURR_ADDR_REG[3][7:0];

            // Word count reads → return CURRENT word count
            BASE_WORD_COUNT_REG_CH0_ADDR : reg_read_data = byte_pointer ? CURR_WORD_COUNT_REG[0][15:8] : CURR_WORD_COUNT_REG[0][7:0];
            BASE_WORD_COUNT_REG_CH1_ADDR : reg_read_data = byte_pointer ? CURR_WORD_COUNT_REG[1][15:8] : CURR_WORD_COUNT_REG[1][7:0];
            BASE_WORD_COUNT_REG_CH2_ADDR : reg_read_data = byte_pointer ? CURR_WORD_COUNT_REG[2][15:8] : CURR_WORD_COUNT_REG[2][7:0];
            BASE_WORD_COUNT_REG_CH3_ADDR : reg_read_data = byte_pointer ? CURR_WORD_COUNT_REG[3][15:8] : CURR_WORD_COUNT_REG[3][7:0];

            STATUS_REG_ADDR  : reg_read_data = dif.STATUS_REG;   // driven elsewhere
            REQUEST_REG_ADDR : reg_read_data = REQUEST_REG;
            MASK_REG_ADDR    : reg_read_data = MASK_REG;
            MODE_REG_ADDR    : reg_read_data = MODE_REG[0];

            CH_CTRL_REG_CH0_ADDR : reg_read_data = CH_CTRL_REG[0];
            CH_CTRL_REG_CH1_ADDR : reg_read_data = CH_CTRL_REG[1];
            CH_CTRL_REG_CH2_ADDR : reg_read_data = CH_CTRL_REG[2];
            CH_CTRL_REG_CH3_ADDR : reg_read_data = CH_CTRL_REG[3];

            BUF_SIZE_REG_CH0_ADDR : reg_read_data = byte_pointer ? BUF_SIZE_REG[0].buffer_size[15:8] : BUF_SIZE_REG[0].buffer_size[7:0];
            BUF_SIZE_REG_CH1_ADDR : reg_read_data = byte_pointer ? BUF_SIZE_REG[1].buffer_size[15:8] : BUF_SIZE_REG[1].buffer_size[7:0];
            BUF_SIZE_REG_CH2_ADDR : reg_read_data = byte_pointer ? BUF_SIZE_REG[2].buffer_size[15:8] : BUF_SIZE_REG[2].buffer_size[7:0];
            BUF_SIZE_REG_CH3_ADDR : reg_read_data = byte_pointer ? BUF_SIZE_REG[3].buffer_size[15:8] : BUF_SIZE_REG[3].buffer_size[7:0];

            // 24-bit priority — 3-byte access by priority_byte_ptr
            PRIORITY_CTRL_REG_ADDR :
                reg_read_data = (priority_byte_ptr == 2'b00) ? PRIORITY_CTRL_REG[7:0]   :
                                (priority_byte_ptr == 2'b01) ? PRIORITY_CTRL_REG[15:8]  :
                                (priority_byte_ptr == 2'b10) ? PRIORITY_CTRL_REG[23:16] :
                                                               PRIORITY_CTRL_REG[7:0];

            EXT_STATUS_REG_ADDR : reg_read_data = dif.EXT_STATUS_REG;

            default : reg_read_data = 8'h00;
        endcase
    end

    //============================================================
    // SECTION 12: DATA BUS DRIVER (bidirectional)
    //============================================================
    // Drive DB only when a CPU read cycle is active; otherwise
    // tri-state (8'bz) so CPU/DMA can drive.
    //------------------------------------------------------------
    assign dif.DB = (!dif.CS_N && !dif.HLDA && !dif.IOR_N) ? reg_read_data : 8'bz;

endmodule : dma_regfile

`endif // DMA_REGFILE_SV
