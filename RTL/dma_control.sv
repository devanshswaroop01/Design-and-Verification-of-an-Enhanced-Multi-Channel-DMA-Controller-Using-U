//============================================================
// File        : dma_control.sv
// Description : DMA Main Control Finite State Machine
//               - Sequences address/read/write/burst/rollover
//               - Drives AEN, ADSTB, IOR_N, IOW_N, MEMR_N, MEMW_N
//               - Drives EOP_N, timeout
//               - Instantiates circular buffer
//               - Generates XFER_PULSE per completed transfer
//============================================================
// INTERVIEW POINTS:
//   1. 10-state FSM: IDLE→REQ→ADDR→READ→WRITE→COMPLETE (+BURST/
//      ROLLOVER/ERROR/WAIT).
//   2. XFER_PULSE is 1-cycle on ST_COMPLETE entry.
//   3. Write txn = MEMR + IOW; Read txn = IOR + MEMW (FIX 1).
//   4. CURR_WC muxed by active_chnum (FIX 2) — no hardwired CH0.
//   5. ST_ERROR now one-shot — no permanent park (FIX M2).
//   6. HLDA hold watchdog forces release after MAX_HOLD_CYCLES.
//============================================================

`ifndef DMA_CONTROL_SV
`define DMA_CONTROL_SV

module dma_control (
    dma_if         dif,     // external bus + status probes
    dma_control_if cif      // internal handshake
);

import dma_reg_pkg::*;

    //============================================================
    // SECTION 1: LOCAL PARAMETERS
    //============================================================
    localparam int MAX_HOLD_CYCLES = 64;   // grant-hold watchdog

    //============================================================
    // SECTION 2: INTERNAL SIGNALS
    //============================================================
    logic [1:0]  current_trans_mode;   // MODE_REG[3:2]
    logic        current_inc_dec;      // ~MODE_REG[5]

    logic checkWriteExtend, checkWrite, checkRead, checkEOP;

    logic [7:0]  ch_ctrl_reg_sel;      // selected CH_CTRL_REG
    logic        circ_en, burst_en, watermark_en, buffer_en, channel_en;
    logic [2:0]  priority_level;

    // Selected-channel mirrors (muxed from the 4 channels)
    logic [15:0] current_addr_mux;
    logic [15:0] base_addr_mux;
    logic [15:0] buffer_size_mux;
    logic [15:0] current_wc_mux;       // FIX 2: replaces CURR_WC_0

    // Circular buffer outputs
    logic [15:0] circ_next_addr;
    logic        circ_rollover, circ_rollover_any;
    logic [1:0]  circ_rollover_channel;
    logic        circ_buffer_full, circ_buffer_empty;
    logic        circ_watermark_reached;
    logic        circ_overflow_error, circ_underflow_error;
    logic        circ_interrupt_pending;

    // Burst control
    logic [15:0] burst_counter;
    logic [15:0] burst_count_remaining;

    //============================================================
    // SECTION 3: STATE ENUM
    //============================================================
    typedef enum logic [3:0] {
        ST_IDLE      = 4'b0000,
        ST_REQUEST   = 4'b0001,
        ST_ADDRESS   = 4'b0010,
        ST_READ      = 4'b0011,
        ST_WRITE     = 4'b0100,
        ST_COMPLETE  = 4'b0101,
        ST_BURST     = 4'b0110,
        ST_ERROR     = 4'b0111,
        ST_ROLLOVER  = 4'b1000,
        ST_WAIT      = 4'b1001
    } state_t;

    state_t state, nextstate;

    //============================================================
    // SECTION 4: CONTROL REGISTERS
    //============================================================
    logic aen_comb, adstb_comb;
    logic ior_reg, iow_reg, memr_reg, memw_reg, eop_reg, timeout_reg;
    logic en_addr_out_reg, prev_complete, xfer_pulse;

    // Sticky flags
    logic rollover_detected, burst_active, burst_complete, error_detected;

    logic master_clear_pulse_d1;    // for 2-cycle-wide status clear

    logic [15:0] hlda_hold_counter; // FIX 8 watchdog
    logic        hold_timeout;

    //============================================================
    // SECTION 5: ACTIVE CHANNEL MUX + BURST DECODE
    //============================================================
    // FIX 2: current_wc_mux is now muxed by active channel.
    //------------------------------------------------------------
    always_comb begin
        case (cif.active_chnum)
            2'b00: begin
                ch_ctrl_reg_sel    = dif.CH_CTRL_REG_0;
                current_trans_mode = dif.MODE_REG_0[3:2];
                current_inc_dec    = ~dif.MODE_REG_0[5];
                current_addr_mux   = dif.CURR_ADDR_0;
                base_addr_mux      = dif.BASE_ADDR_0;
                buffer_size_mux    = dif.BUF_SIZE_REG_0;
                current_wc_mux     = dif.CURR_WC_0;
            end
            2'b01: begin
                ch_ctrl_reg_sel    = dif.CH_CTRL_REG_1;
                current_trans_mode = dif.MODE_REG_1[3:2];
                current_inc_dec    = ~dif.MODE_REG_1[5];
                current_addr_mux   = dif.CURR_ADDR_1;
                base_addr_mux      = dif.BASE_ADDR_1;
                buffer_size_mux    = dif.BUF_SIZE_REG_1;
                current_wc_mux     = dif.CURR_WC_1;
            end
            2'b10: begin
                ch_ctrl_reg_sel    = dif.CH_CTRL_REG_2;
                current_trans_mode = dif.MODE_REG_2[3:2];
                current_inc_dec    = ~dif.MODE_REG_2[5];
                current_addr_mux   = dif.CURR_ADDR_2;
                base_addr_mux      = dif.BASE_ADDR_2;
                buffer_size_mux    = dif.BUF_SIZE_REG_2;
                current_wc_mux     = dif.CURR_WC_2;
            end
            2'b11: begin
                ch_ctrl_reg_sel    = dif.CH_CTRL_REG_3;
                current_trans_mode = dif.MODE_REG_3[3:2];
                current_inc_dec    = ~dif.MODE_REG_3[5];
                current_addr_mux   = dif.CURR_ADDR_3;
                base_addr_mux      = dif.BASE_ADDR_3;
                buffer_size_mux    = dif.BUF_SIZE_REG_3;
                current_wc_mux     = dif.CURR_WC_3;
            end
            default: begin
                ch_ctrl_reg_sel    = 8'h00;
                current_trans_mode = 2'b00;
                current_inc_dec    = 1'b1;
                current_addr_mux   = 16'h0000;
                base_addr_mux      = 16'h0000;
                buffer_size_mux    = 16'h0000;
                current_wc_mux     = 16'h0000;
            end
        endcase

        // Extract per-channel control bits from packed struct
        circ_en        = ch_ctrl_reg_sel[7];
        burst_en       = ch_ctrl_reg_sel[6];
        priority_level = ch_ctrl_reg_sel[5:3];
        watermark_en   = ch_ctrl_reg_sel[2];
        buffer_en      = ch_ctrl_reg_sel[1];
        channel_en     = ch_ctrl_reg_sel[0];
    end

    //============================================================
    // SECTION 6: IMMEDIATE BUS STROBES
    //============================================================
    // AEN and ADSTB are purely combinational from FSM state.
    //------------------------------------------------------------
    assign aen_comb   = (state == ST_ADDRESS || state == ST_READ ||
                         state == ST_WRITE   || state == ST_BURST ||
                         state == ST_ROLLOVER || state == ST_ERROR);
    assign adstb_comb = (state == ST_ADDRESS);

    assign dif.AEN   = aen_comb;
    assign dif.ADSTB = adstb_comb;

    //============================================================
    // SECTION 7: CIRCULAR BUFFER INSTANCE
    //============================================================
    // NOTE the reversed concatenations: base_addr[0]=BASE_ADDR_0
    // must land in slot 0 of the unpacked array. Since we write
    // '{A,B,C,D} and index 0 is the LSB, the order is:
    //   '{} with elements written MSB-first → [0]=last element.
    // So BASE_ADDR_0 is placed last, giving index 0 = CH0.
    //------------------------------------------------------------
    dma_circular_buffer CIRCULAR_BUFFER (
        .clk                 (dif.CLK),
        .reset_n             (~dif.RESET),

        .channel_select      (cif.active_chnum),
        .channel_enable      ({dif.CH_CTRL_REG_3[0], dif.CH_CTRL_REG_2[0],
                               dif.CH_CTRL_REG_1[0], dif.CH_CTRL_REG_0[0]}),
        .base_addr           ('{dif.BASE_ADDR_0, dif.BASE_ADDR_1,
                                dif.BASE_ADDR_2, dif.BASE_ADDR_3}),
        .buffer_size         ('{dif.BUF_SIZE_REG_0, dif.BUF_SIZE_REG_1,
                                dif.BUF_SIZE_REG_2, dif.BUF_SIZE_REG_3}),
        .buffer_en           ({dif.CH_CTRL_REG_3[1], dif.CH_CTRL_REG_2[1],
                               dif.CH_CTRL_REG_1[1], dif.CH_CTRL_REG_0[1]}),
        .curr_addr           ('{dif.CURR_ADDR_0, dif.CURR_ADDR_1,
                                dif.CURR_ADDR_2, dif.CURR_ADDR_3}),
        .word_count          ('{dif.CURR_WC_0, dif.CURR_WC_1,
                                dif.CURR_WC_2, dif.CURR_WC_3}),

        .increment_en        (current_inc_dec),
        .addr_update_en      (xfer_pulse),

        // FIX 4A: read transfer drains the buffer
        .read_en             (xfer_pulse && (current_trans_mode == 2'b10)),

        .current_addr_in     (current_addr_mux),
        .base_addr_in        (base_addr_mux),
        .buffer_size_in      (buffer_size_mux),
        .circ_en             (circ_en),

        .watermark_threshold (16'h0001),
        .interrupt_en        (1'b1),
        .reset_counters      (dif.MASTER_CLEAR_CMD),
        .force_rollover      (1'b0),
        .wrap_mode           (2'b00),

        .watermark_en        ({dif.CH_CTRL_REG_3[2], dif.CH_CTRL_REG_2[2],
                               dif.CH_CTRL_REG_1[2], dif.CH_CTRL_REG_0[2]}),

        .next_addr           (circ_next_addr),
        .rollover            (circ_rollover),
        .rollover_any        (circ_rollover_any),
        .rollover_channel    (circ_rollover_channel),
        .buffer_full         (circ_buffer_full),
        .buffer_empty        (circ_buffer_empty),
        .watermark_reached   (circ_watermark_reached),
        .overflow_error      (circ_overflow_error),
        .underflow_error     (circ_underflow_error),
        .interrupt_pending   (circ_interrupt_pending),

        // Unconnected — driven out via hierarchical assigns in dma_top
        .buffer_used         (),
        .buffer_free         (),
        .buffer_empty_int    (),
        .buffer_full_int     (),
        .rollover_status     ()
    );

    //============================================================
    // SECTION 8: HLDA HOLD WATCHDOG (FIX 8)
    //============================================================
    // If HLDA is held high while FSM is stuck in an active bus
    // state (not IDLE, not COMPLETE) for MAX_HOLD_CYCLES, force
    // a return to IDLE. Prevents arbiter deadlock.
    //------------------------------------------------------------
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) begin
            hlda_hold_counter <= 16'h0000;
            hold_timeout      <= 1'b0;
        end else if (!dif.HLDA) begin
            hlda_hold_counter <= 16'h0000;
            hold_timeout      <= 1'b0;
        end else if (state == ST_IDLE) begin
            hlda_hold_counter <= 16'h0000;
            hold_timeout      <= 1'b0;
        end else if (state == ST_COMPLETE) begin
            // Legitimate park — don't count
            hlda_hold_counter <= 16'h0000;
            hold_timeout      <= 1'b0;
        end else if (hlda_hold_counter >= MAX_HOLD_CYCLES) begin
            hlda_hold_counter <= hlda_hold_counter;   // saturate
            hold_timeout      <= 1'b1;
        end else begin
            hlda_hold_counter <= hlda_hold_counter + 16'd1;
            hold_timeout      <= 1'b0;
        end
    end

    //============================================================
    // SECTION 9: STATE REGISTER
    //============================================================
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) begin
            state                 <= ST_IDLE;
            burst_counter         <= 16'h0000;
            burst_count_remaining <= 16'h0000;
            burst_active          <= 1'b0;
            burst_complete        <= 1'b0;
            error_detected        <= 1'b0;
            rollover_detected     <= 1'b0;
        end else if (dif.MASTER_CLEAR_CMD) begin
            state                 <= ST_IDLE;
            burst_counter         <= 16'h0000;
            burst_count_remaining <= 16'h0000;
            burst_active          <= 1'b0;
            burst_complete        <= 1'b0;
            error_detected        <= 1'b0;
            rollover_detected     <= 1'b0;
        end else begin
            state <= nextstate;

            // ---- Burst counter ----
            if (state == ST_BURST) begin
                burst_active <= 1'b1;
                if (burst_counter < burst_count_remaining)
                    burst_counter <= burst_counter + 16'd1;
                else begin
                    burst_complete <= 1'b1;
                    burst_active   <= 1'b0;
                end
            end else if (state == ST_COMPLETE) begin
                burst_counter  <= 16'h0000;
                burst_complete <= 1'b0;
                burst_active   <= 1'b0;
            end

            // ---- Level-sensitive error mirror ----
            // NOTE: circ_overflow_error is itself sticky in the
            // buffer module, so this level stays high until
            // MASTER_CLEAR. ST_ERROR no longer parks on it.
            error_detected <= circ_overflow_error || circ_underflow_error;

            // ---- Sticky rollover ----
            if (circ_rollover)
                rollover_detected <= 1'b1;
        end
    end

    //============================================================
    // SECTION 10: NEXT STATE LOGIC
    //============================================================
    always_comb begin
        nextstate = state;

        case (state)

            ST_IDLE : begin
                if (cif.VALID_DREQ0 || cif.VALID_DREQ1 ||
                    cif.VALID_DREQ2 || cif.VALID_DREQ3)
                    nextstate = ST_REQUEST;
                else
                    nextstate = ST_IDLE;
            end

            ST_REQUEST : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else if (hold_timeout)    nextstate = ST_IDLE;   // FIX 8
                // FIX 9: only advance if a VALID DREQ is pending
                else if (dif.HLDA && (cif.VALID_DREQ0 || cif.VALID_DREQ1 ||
                                      cif.VALID_DREQ2 || cif.VALID_DREQ3))
                    nextstate = ST_ADDRESS;
                else if (dif.HRQ)         nextstate = ST_REQUEST;
                else                      nextstate = ST_IDLE;
            end

            ST_ADDRESS : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else if (hold_timeout)    nextstate = ST_IDLE;   // FIX 8
                // FIX 2: use current_wc_mux (per active channel)
                else if (burst_en && (current_wc_mux > 16'd1))
                    nextstate = ST_BURST;
                else
                    nextstate = ST_READ;
            end

            ST_READ : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else if (hold_timeout)    nextstate = ST_IDLE;   // FIX 8
                else                      nextstate = ST_WRITE;
            end

            ST_WRITE : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else if (hold_timeout)    nextstate = ST_IDLE;   // FIX 8
                else                      nextstate = ST_COMPLETE;
            end

            ST_BURST : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else if (hold_timeout)    nextstate = ST_IDLE;   // FIX 8
                else if (burst_complete)  nextstate = ST_COMPLETE;
                else                      nextstate = ST_BURST;
            end

            ST_COMPLETE : begin
                if (dif.MASTER_CLEAR_CMD)      nextstate = ST_IDLE;
                else if (!dif.HLDA)            nextstate = ST_IDLE;
                else if (circ_rollover)        nextstate = ST_ROLLOVER;
                else if (error_detected)       nextstate = ST_ERROR;
                else if (dif.DREQ != 4'b0000)  nextstate = ST_REQUEST;
                else                           nextstate = ST_IDLE;
            end

            ST_ROLLOVER : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else                      nextstate = ST_IDLE;
            end

            //------------------------------------------------------------
            // FIX M2: ST_ERROR is a ONE-SHOT reporting state.
            // Root cause of the CH1–CH3 stall:
            //   overflow_detected[] in the circular buffer is sticky
            //   (only clears on MASTER_CLEAR). error_detected mirrors
            //   it level-wise. So the old exit condition
            //   "!error_detected" was never true after first overflow,
            //   parking the FSM in ST_ERROR forever. AEN/EOP_N held
            //   high, HRQ dropped, XFER_PULSE fired only rarely, and
            //   the shared error_detected blocked other channels.
            // Fix: exit ST_ERROR unconditionally on next cycle.
            //   Error remains latched in EXT_STATUS[7] for software.
            //------------------------------------------------------------
            ST_ERROR : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else                      nextstate = ST_IDLE;
            end

            ST_WAIT : begin
                if (dif.MASTER_CLEAR_CMD) nextstate = ST_IDLE;
                else                      nextstate = ST_ADDRESS;
            end

            default : nextstate = ST_IDLE;

        endcase
    end

    //============================================================
    // SECTION 11: XFER_PULSE GENERATION
    //============================================================
    // 1-cycle pulse on ST_COMPLETE entry.
    //------------------------------------------------------------
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) prev_complete <= 1'b0;
        else           prev_complete <= (state == ST_COMPLETE);
    end

    assign xfer_pulse = (state == ST_COMPLETE) && !prev_complete;

    //============================================================
    // SECTION 12: MASTER CLEAR DELAYED PULSE
    //============================================================
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET)
            master_clear_pulse_d1 <= 1'b0;
        else
            master_clear_pulse_d1 <= dif.MASTER_CLEAR_CMD;
    end

    //============================================================
    // SECTION 13: STATUS OUTPUT REGISTERS
    //============================================================
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) begin
            dif.EXT_STATUS_REG <= 8'h00;
            dif.STATUS_REG     <= 8'h00;
        end else if (dif.MASTER_CLEAR_CMD || master_clear_pulse_d1) begin
            dif.EXT_STATUS_REG <= 8'h00;
            dif.STATUS_REG     <= 8'h00;
        end else begin
            // Overflow / underflow — level-sensitive
            dif.EXT_STATUS_REG[7] <= circ_overflow_error;
            dif.EXT_STATUS_REG[6] <= circ_underflow_error;

            // Watermark — gated by per-channel watermark_en
            if (circ_watermark_reached && watermark_en)
                dif.EXT_STATUS_REG[5] <= 1'b1;

            // Rollover — set on event, latches channel
            // FIX BLOCKER 6: use circ_rollover_channel (actual
            // channel that rolled) instead of cif.active_chnum,
            // which may have advanced by the time this commits.
            if (circ_rollover) begin
                dif.EXT_STATUS_REG[4]   <= 1'b1;
                dif.EXT_STATUS_REG[3:0] <= {2'b00, circ_rollover_channel};
            end

            // Terminal Count per channel
            if (xfer_pulse) begin
                case (cif.active_chnum)
                    2'b00: if (dif.CURR_WC_0 == 16'h0000) dif.STATUS_REG[0] <= 1'b1;
                    2'b01: if (dif.CURR_WC_1 == 16'h0000) dif.STATUS_REG[1] <= 1'b1;
                    2'b10: if (dif.CURR_WC_2 == 16'h0000) dif.STATUS_REG[2] <= 1'b1;
                    2'b11: if (dif.CURR_WC_3 == 16'h0000) dif.STATUS_REG[3] <= 1'b1;
                endcase
            end
        end
    end

    //============================================================
    // SECTION 14: BUS CONTROL DECODE (FIX 1)
    //============================================================
    // Direction mapping (8237 style):
    //   Write transfer (mode=01, memory → I/O):
    //       MEMR_N asserted (read from memory)
    //       IOW_N  asserted (write to I/O)
    //   Read transfer (mode=10, I/O → memory):
    //       IOR_N  asserted (read from I/O)
    //       MEMW_N asserted (write to memory)
    //------------------------------------------------------------
    always_comb begin
        ior_reg         = 1'b1;
        iow_reg         = 1'b1;
        memr_reg        = 1'b1;
        memw_reg        = 1'b1;
        eop_reg         = 1'b1;
        timeout_reg     = 1'b0;
        en_addr_out_reg = 1'b0;

        checkRead        = 1'b0;
        checkWrite       = 1'b0;
        checkWriteExtend = 1'b0;
        checkEOP         = 1'b0;

        case (state)
            ST_IDLE : ;
            ST_REQUEST : ;

            ST_ADDRESS : begin
                en_addr_out_reg = 1'b1;
            end

            ST_READ : begin
                checkRead        = 1'b1;
                checkWriteExtend = 1'b1;
            end

            ST_WRITE : begin
                checkWrite = 1'b1;
            end

            ST_BURST : begin
                if (burst_counter[0] == 1'b0) begin
                    checkRead        = 1'b1;
                    checkWriteExtend = 1'b1;
                end else begin
                    checkWrite = 1'b1;
                end
            end

            ST_COMPLETE : begin
                checkEOP    = xfer_pulse;
                timeout_reg = xfer_pulse;
            end

            ST_ROLLOVER : begin
                eop_reg     = 1'b0;
                timeout_reg = 1'b1;
            end

            ST_ERROR : begin
                eop_reg     = 1'b0;
                timeout_reg = 1'b1;
            end

            ST_WAIT : ;
            default : ;
        endcase

        // FIX 1: Write transfer = MEMR + IOW
        if ((checkWriteExtend || checkWrite) &&
            (current_trans_mode == 2'b01)) begin
            memr_reg = 1'b0;
            iow_reg  = 1'b0;
        end
        // FIX 1: Read transfer = IOR + MEMW
        else if (checkRead && (current_trans_mode == 2'b10)) begin
            ior_reg  = 1'b0;
            memw_reg = 1'b0;
        end

        // EOP assertion
        if (checkEOP || (state == ST_ROLLOVER) || (state == ST_ERROR))
            eop_reg = 1'b0;
    end

    //============================================================
    // SECTION 15: CONTROL SIGNAL REGISTERING
    //============================================================
    always_ff @(posedge dif.CLK or posedge dif.RESET) begin
        if (dif.RESET) begin
            dif.EOP_N       <= 1'b1;
            cif.eop         <= 1'b1;
            cif.timeout     <= 1'b0;
            cif.en_addr_out <= 1'b0;
        end else begin
            dif.EOP_N       <= eop_reg;
            cif.eop         <= eop_reg;
            cif.timeout     <= timeout_reg;
            cif.en_addr_out <= en_addr_out_reg;
        end
    end

    //============================================================
    // SECTION 16: TRI-STATE BUS DRIVERS
    //============================================================
    // Drive IOR_N / IOW_N / MEMR_N / MEMW_N only when HLDA=1
    // (DMA owns bus). Otherwise tri-state.
    //------------------------------------------------------------
    assign dif.IOR_N  = dif.HLDA ? ior_reg  : 1'bz;
    assign dif.IOW_N  = dif.HLDA ? iow_reg  : 1'bz;
    assign dif.MEMR_N = dif.HLDA ? memr_reg : 1'bz;
    assign dif.MEMW_N = dif.HLDA ? memw_reg : 1'bz;

    //============================================================
    // SECTION 17: XFER_PULSE EXPORT
    //============================================================
    assign dif.XFER_PULSE = xfer_pulse;

endmodule : dma_control


//                   ┌──────────┐
//       ┌──────────►│  IDLE    │◄──── reset / master_clear
//       │           └────┬─────┘
//       │      any valid DREQ
//       │                ▼
//       │           ┌──────────┐
//       │  no HLDA  │ REQUEST  │◄──┐
//       │  ◄────────┤          │   │ HRQ asserted
//       │           └────┬─────┘   │
//       │      HLDA && valid DREQ  │
//       │                ▼         │
//       │           ┌──────────┐   │
//       │           │ ADDRESS  │   │  AEN=1, ADSTB=1
//       │           └────┬─────┘   │
//       │     burst_en && wc>1     │ else
//       │       ┌───────┴───────┐  │
//       │       ▼               ▼  │
//       │  ┌────────┐      ┌────────┐
//       │  │ BURST  │      │  READ  │  AEN=1, IOR/MEMR
//       │  └───┬────┘      └───┬────┘
//       │      │ burst_done    ▼
//       │      │           ┌────────┐
//       │      │           │ WRITE  │  AEN=1, IOW/MEMW
//       │      │           └───┬────┘
//       │      └───────┬───────┘
//       │              ▼
//       │        ┌───────────┐
//       │        │ COMPLETE  │  XFER_PULSE=1
//       │        └─────┬─────┘
//       │  no HLDA /   │
//       │  no DREQ     │
//       │  ┌───────────┼───────────┐
//       │  ▼           ▼           ▼
//       │ IDLE    ROLLOVER       ERROR       ── both return to IDLE next cycle
//       │           (1 cycle)    (1 cycle)
//       └────────────────────────────────────────


//   7     6     5         4        3    2    1    0
// ┌────┬─────┬─────────┬────────┬────┬────┬────┬────┐
// │OVF │UNF  │WATERMARK│ROLLOVER│    ROLLOVER CH    │
// │ERR │ERR  │REACHED  │PENDING │    (2'b00 + ch)   │
// └────┴─────┴─────────┴────────┴────┴────┴────┴────┘

// // `endif // DMA_CONTROL_SV
