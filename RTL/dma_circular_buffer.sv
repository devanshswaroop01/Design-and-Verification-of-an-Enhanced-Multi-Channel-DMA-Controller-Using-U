//============================================================
// File        : dma_circular_buffer.sv
// Description : DMA Circular Buffer Controller
//               - Computes next circular address per channel
//               - Tracks buffer_used / buffer_free per channel
//               - Detects rollover, overflow, underflow, watermark
//               - Generates interrupt on rollover
//============================================================
// INTERVIEW POINTS:
//   1. Per-channel state: buffer_used_int[i], rollover_latched[i].
//   2. Wrap-around handled via wrap_mode (4 options).
//   3. Only the SELECTED channel (channel_select) is mutated.
//   4. addr_update_en & read_en are PULSE-QUALIFIED (rising edge)
//      → guarantees exactly one counter change per transaction.
//   5. buffer_used saturates at [0, buffer_size].
//   6. Overflow = write when full; underflow = read when empty.
//============================================================

`ifndef DMA_CIRCULAR_BUFFER_SV
`define DMA_CIRCULAR_BUFFER_SV

module dma_circular_buffer (
    input  logic        clk,
    input  logic        reset_n,            // ACTIVE-LOW async reset

    //---------- Channel selection & enables ----------
    input  logic [1:0]  channel_select,     // which channel to update
    input  logic [3:0]  channel_enable,     // per-channel enable mask
    input  logic [3:0]  buffer_en,          // per-channel buffer enable

    //---------- Per-channel inputs (from regfile) ----------
    input  logic [15:0] base_addr   [0:3],
    input  logic [15:0] buffer_size [0:3],
    input  logic [15:0] curr_addr   [0:3],
    input  logic [15:0] word_count  [0:3],

    //---------- Update strobes ----------
    input  logic        increment_en,       // 1=inc, 0=dec direction
    input  logic        addr_update_en,     // pulse: address moved
    input  logic        read_en,            // pulse: data drained (FIX 4A)

    //---------- Selected-channel mirror (combinational) ----------
    input  logic [15:0] current_addr_in,
    input  logic [15:0] base_addr_in,
    input  logic [15:0] buffer_size_in,
    input  logic        circ_en,            // circular mode active

    //---------- Thresholds / control ----------
    input  logic [15:0] watermark_threshold,
    input  logic        interrupt_en,
    input  logic        reset_counters,     // async clear of counters/flags
    input  logic        force_rollover,
    input  logic [1:0]  wrap_mode,          // see Sec 4

    input  logic [3:0]  watermark_en,       // per-channel watermark mask

    //---------- Outputs ----------
    output logic [15:0] next_addr,          // registered next address
    output logic        rollover,           // 1-cycle rollover pulse
    output logic        rollover_any,       // OR of latched rollovers
    output logic [1:0]  rollover_channel,   // highest-priority rolling ch
    output logic        buffer_full,
    output logic        buffer_empty,
    output logic        watermark_reached,
    output logic        overflow_error,
    output logic        underflow_error,
    output logic        interrupt_pending,

    output logic [15:0] buffer_used  [0:3],
    output logic [15:0] buffer_free  [0:3],
    output logic [3:0]  buffer_empty_int,
    output logic [3:0]  buffer_full_int,
    output logic [3:0]  rollover_status
);

    //============================================================
    // SECTION 1: INTERNAL SIGNALS
    //============================================================
    logic [15:0] next_addr_int;
    logic        rollover_int;
    logic [15:0] buffer_end   [0:3];    // base + size - 1
    logic [15:0] buffer_start [0:3];    // == base
    logic [15:0] current_addr_sel;
    logic [15:0] base_addr_sel;
    logic [15:0] buffer_size_sel;
    logic [15:0] buffer_used_int [0:3];
    logic [15:0] buffer_free_int [0:3];

    logic [3:0]  rollover_detected;
    logic [3:0]  rollover_latched;
    logic [3:0]  overflow_detected;
    logic [3:0]  underflow_detected;
    logic [3:0]  watermark_reached_int;
    logic        interrupt_pending_int;
    logic        rollover_reg;
    logic [3:0]  buffer_ever_used;

    // FIX 4B: pulse qualifiers
    logic        addr_update_en_d;
    logic        addr_update_pulse;

    // FIX 4A: pulse qualifier
    logic        read_en_d;
    logic        read_pulse;

    //============================================================
    // SECTION 2: PULSE QUALIFIERS
    //============================================================
    // Rising-edge detect on both strobes. A level lasting N cycles
    // produces exactly ONE pulse → one counter change.
    //------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            addr_update_en_d <= 1'b0;
            read_en_d        <= 1'b0;
        end else begin
            addr_update_en_d <= addr_update_en;
            read_en_d        <= read_en;
        end
    end

    assign addr_update_pulse = addr_update_en & ~addr_update_en_d;
    assign read_pulse        = read_en        & ~read_en_d;

    //============================================================
    // SECTION 3: BUFFER BOUNDARY CALCULATION
    //============================================================
    // buffer_start = base_addr
    // buffer_end   = base_addr + size - 1
    //------------------------------------------------------------
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_buffer_bounds
            assign buffer_start[i] = base_addr[i];
            assign buffer_end[i]   = base_addr[i] + buffer_size[i] - 16'd1;
        end
    endgenerate

    // Selected-channel muxes (combinational)
    always_comb begin
        current_addr_sel = curr_addr[channel_select];
        base_addr_sel    = base_addr[channel_select];
        buffer_size_sel  = buffer_size[channel_select];
    end

    //============================================================
    // SECTION 4: CIRCULAR ADDRESS CALCULATOR
    //============================================================
    // wrap_mode:
    //   2'b00 : wrap to base_addr                (standard)
    //   2'b01 : wrap to base_addr + 1            (skip first slot)
    //   2'b10 : wrap to midpoint (base + size/2) (ping-pong)
    //   2'b11 : reserved → fallback to base_addr
    //
    // Direction controlled by increment_en:
    //   increment_en=1 → forward scan
    //   increment_en=0 → backward scan
    //------------------------------------------------------------
    always_comb begin
        next_addr_int = current_addr_sel;
        rollover_int  = 1'b0;

        if (circ_en && channel_enable[channel_select]) begin
            if (increment_en) begin
                if (current_addr_sel == buffer_end[channel_select]) begin
                    case (wrap_mode)
                        2'b00:   next_addr_int = base_addr_sel;
                        2'b01:   next_addr_int = base_addr_sel + 16'h0001;
                        2'b10:   next_addr_int = base_addr_sel + (buffer_size_sel >> 1);
                        2'b11:   next_addr_int = base_addr_sel;
                        default: next_addr_int = base_addr_sel;
                    endcase
                    rollover_int = 1'b1;
                end else begin
                    next_addr_int = current_addr_sel + 16'd1;
                    rollover_int  = 1'b0;
                end
            end else begin
                if (current_addr_sel == base_addr_sel) begin
                    case (wrap_mode)
                        2'b00:   next_addr_int = buffer_end[channel_select];
                        2'b01:   next_addr_int = buffer_end[channel_select] - 16'h0001;
                        2'b10:   next_addr_int = buffer_end[channel_select] - (buffer_size_sel >> 1);
                        2'b11:   next_addr_int = buffer_end[channel_select];
                        default: next_addr_int = buffer_end[channel_select];
                    endcase
                    rollover_int = 1'b1;
                end else begin
                    next_addr_int = current_addr_sel - 16'd1;
                    rollover_int  = 1'b0;
                end
            end
        end else begin
            // Non-circular: simple +1 / -1, no wrap
            next_addr_int = increment_en ? (current_addr_sel + 16'd1)
                                         : (current_addr_sel - 16'd1);
            rollover_int  = 1'b0;
        end
    end

    //============================================================
    // SECTION 5: ROLLOVER DETECTION
    //============================================================
    // Combinational: detect that curr_addr is at the boundary in
    // the active direction.
    // Latched: sticky per-channel rollover flag.
    //------------------------------------------------------------
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_rollover_detect
            always_comb begin
                rollover_detected[i] = 1'b0;
                if (channel_enable[i] && buffer_en[i]) begin
                    if (increment_en) begin
                        if (curr_addr[i] == buffer_end[i])
                            rollover_detected[i] = 1'b1;
                    end else begin
                        if (curr_addr[i] == base_addr[i])
                            rollover_detected[i] = 1'b1;
                    end
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rollover_latched <= 4'b0000;
            rollover_status  <= 4'b0000;
        end else if (reset_counters) begin
            rollover_latched <= 4'b0000;
            rollover_status  <= 4'b0000;
        end else begin
            for (int i = 0; i < 4; i++) begin
                if ((rollover_detected[i] ||
                     (rollover_int && (channel_select == 2'(i))))
                    && channel_enable[i]) begin
                    rollover_latched[i] <= 1'b1;
                    rollover_status[i]  <= 1'b1;
                end
            end
        end
    end

    // 1-cycle registered rollover pulse
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) rollover_reg <= 1'b0;
        else          rollover_reg <= rollover_int;
    end

    assign rollover_any = |rollover_latched;
    assign rollover     = rollover_reg;

    // Highest-numbered channel that has rolled wins
    always_comb begin
        rollover_channel = 2'b00;
        for (int i = 0; i < 4; i++)
            if (rollover_latched[i])
                rollover_channel = 2'(i);
    end

    //============================================================
    // SECTION 6: BUFFER USAGE COUNTERS (FIX 4A + 4B)
    //============================================================
    // Per selected channel:
    //   addr_update_pulse → +1 (write into buffer)
    //   read_pulse        → -1 (drain from buffer)
    // Saturates at [0, buffer_size].
    // Write has priority over read if both occur same cycle.
    //------------------------------------------------------------
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_buffer_counters
            always_ff @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    buffer_used_int[i] <= 16'h0000;
                end else if (reset_counters) begin
                    buffer_used_int[i] <= 16'h0000;
                end else if (channel_select == 2'(i) &&
                             (buffer_size[i] != 16'h0000)) begin

                    // ---- WRITE SIDE: increment ----
                    if (addr_update_pulse) begin
                        if (rollover_detected[i]) begin
                            // At wrap: if already full, stay full
                            if (buffer_used_int[i] < buffer_size[i])
                                buffer_used_int[i] <= buffer_used_int[i] + 16'd1;
                        end else if (buffer_used_int[i] < buffer_size[i]) begin
                            buffer_used_int[i] <= buffer_used_int[i] + 16'd1;
                        end
                    end

                    // ---- READ SIDE: decrement ----
                    else if (read_pulse) begin
                        if (buffer_used_int[i] > 16'h0000)
                            buffer_used_int[i] <= buffer_used_int[i] - 16'd1;
                    end
                end
            end
        end
    endgenerate

    // buffer_free = size - used, saturating at 0
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_buffer_free
            assign buffer_free_int[i] = (buffer_size[i] >= buffer_used_int[i])
                                       ? (buffer_size[i] - buffer_used_int[i])
                                       : 16'h0000;
        end
    endgenerate

    assign buffer_used = buffer_used_int;
    assign buffer_free = buffer_free_int;

    //============================================================
    // SECTION 7: WATERMARK DETECTION (gated by watermark_en)
    //============================================================
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_watermark
            always_comb begin
                watermark_reached_int[i] = 1'b0;
                if (watermark_en[i] &&
                    (buffer_used_int[i] >= watermark_threshold))
                    watermark_reached_int[i] = 1'b1;
            end
        end
    endgenerate

    assign watermark_reached = |watermark_reached_int;

    //============================================================
    // SECTION 8: BUFFER FULL / EMPTY
    //============================================================
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_buffer_status
            assign buffer_empty_int[i] = (buffer_used_int[i] == 16'h0000);
            assign buffer_full_int[i]  = (buffer_used_int[i] >= buffer_size[i]);
        end
    endgenerate

    assign buffer_empty = &buffer_empty_int;   // ALL channels empty
    assign buffer_full  = |buffer_full_int;    // ANY channel full

    //============================================================
    // SECTION 9: ERROR DETECTION
    //============================================================
    // buffer_ever_used: sticky — prevents spurious underflow on
    // cold read of an empty, never-used buffer.
    //------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            buffer_ever_used <= 4'b0000;
        end else if (reset_counters) begin
            buffer_ever_used <= 4'b0000;
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (channel_select == 2'(i) &&
                    (addr_update_pulse || read_pulse) &&
                    (buffer_used_int[i] > 16'h0000))
                    buffer_ever_used[i] <= 1'b1;
            end
        end
    end

    generate
        for (genvar i = 0; i < 4; i++) begin : gen_errors
            always_ff @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    overflow_detected[i]  <= 1'b0;
                    underflow_detected[i] <= 1'b0;
                end else if (reset_counters) begin
                    overflow_detected[i]  <= 1'b0;
                    underflow_detected[i] <= 1'b0;
                end else if (channel_select == 2'(i) &&
                             (buffer_size[i] != 16'h0000)) begin
                    // Overflow: write while full
                    if (addr_update_pulse && buffer_full_int[i])
                        overflow_detected[i] <= 1'b1;

                    // Underflow: read while empty AND buffer was used
                    if (read_pulse && buffer_empty_int[i] && buffer_ever_used[i])
                        underflow_detected[i] <= 1'b1;
                end
            end
        end
    endgenerate

    assign overflow_error  = |overflow_detected;
    assign underflow_error = |underflow_detected;

    //============================================================
    // SECTION 10: INTERRUPT GENERATION
    //============================================================
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            interrupt_pending_int <= 1'b0;
        end else begin
            if (reset_counters)
                interrupt_pending_int <= 1'b0;
            else if (interrupt_en && rollover_any)
                interrupt_pending_int <= 1'b1;
        end
    end

    assign interrupt_pending = interrupt_pending_int;

    //============================================================
    // SECTION 11: OUTPUT REGISTRATION
    //============================================================
    // next_addr is REGISTERED — updated only when addr_update_en=1.
    //------------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            next_addr <= 16'h0000;
        end else if (addr_update_en) begin
            next_addr <= next_addr_int;
        end
    end

endmodule : dma_circular_buffer

`endif // DMA_CIRCULAR_BUFFER_SV
