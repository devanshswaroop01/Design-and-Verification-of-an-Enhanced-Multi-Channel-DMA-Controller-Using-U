//============================================================
// File        : dma_reference_model.sv
// Description : Golden Reference Model for DMA Controller
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_component (it has phases, TLM ports, hierarchy).
//   2. TWO analysis imports (cpu_export, dma_export) using the
//      `uvm_analysis_imp_decl macros — since UVM doesn't allow
//      two `write()` methods with different signatures in one
//      component, we suffix them (_cpu / _dma).
//   3. ONE analysis port (expected_port) → publishes expected
//      dma_seq_items to the scoreboard.
//   4. Maintains FULL software mirror of DUT state.
//   5. FIX M4 broke the tautological "prediction = observation"
//      bug by INDEPENDENTLY predicting active_chnum/dack.
//============================================================

`ifndef DMA_REFERENCE_MODEL_SV
`define DMA_REFERENCE_MODEL_SV

// Declare two suffixed analysis imports: write_cpu, write_dma
`uvm_analysis_imp_decl(_cpu)
`uvm_analysis_imp_decl(_dma)

class dma_reference_model extends uvm_component;

    //============================================================
    // TLM PORTS
    //============================================================
    // Two input imports (one per source), one output port.
    //------------------------------------------------------------
    uvm_analysis_imp_cpu #(cpu_seq_item, dma_reference_model) cpu_export;
    uvm_analysis_imp_dma #(dma_seq_item, dma_reference_model) dma_export;
    uvm_analysis_port    #(dma_seq_item)                       expected_port;

    //============================================================
    // REGISTER MIRROR (26 registers)
    //============================================================
    // Channel regs
    bit [15:0] base_addr [0:3];
    bit [15:0] base_wc   [0:3];
    bit [15:0] curr_addr [0:3];
    bit [15:0] curr_wc   [0:3];

    // Control
    bit [7:0]  command_reg;
    bit [7:0]  request_reg;
    bit [7:0]  mask_reg;
    bit [7:0]  mode_reg [0:3];

    // Enhanced
    bit [7:0]  ch_ctrl [0:3];
    bit [15:0] buf_size[0:3];
    bit [23:0] priority_ctrl;
    bit [7:0]  ext_status;
    bit [7:0]  status_reg;

    // Byte pointers
    bit        byte_pointer;
    bit [1:0]  priority_byte_ptr;

    //============================================================
    // ARBITRATION STATE
    //============================================================
    bit [1:0]  ch_priority [0:3];
    bit [3:0]  valid_dreq;

    //============================================================
    // BUFFER STATE
    //============================================================
    bit [15:0] buffer_used [0:3];
    bit [3:0]  rollover_latched;
    bit [3:0]  overflow_detected;
    bit [3:0]  underflow_detected;
    bit [3:0]  buffer_ever_used;

    //============================================================
    // SNAPSHOT REGISTERS (for change detection)
    //============================================================
    bit [15:0] prev_curr_addr   [0:3];
    bit [15:0] prev_curr_wc     [0:3];
    bit [15:0] prev_buffer_used [0:3];
    bit [7:0]  prev_ext_status;

    //============================================================
    // STATISTICS
    //============================================================
    int unsigned cpu_events;
    int unsigned cpu_writes;
    int unsigned cpu_reads;
    int unsigned dma_events;
    int unsigned expected_events;
    int unsigned ch_pred_count [0:3];
    int unsigned rollover_count;
    int unsigned overflow_count;
    int unsigned underflow_count;
    int unsigned watermark_count;

    // Warning deduplication (per register address)
    bit warn_seen [5'h00 : 5'h19];

    `uvm_component_utils(dma_reference_model)

    //============================================================
    // CONSTRUCTOR
    //============================================================
    function new(string name = "dma_reference_model", uvm_component parent = null);
        super.new(name, parent);
        cpu_events      = 0;
        cpu_writes      = 0;
        cpu_reads       = 0;
        dma_events      = 0;
        expected_events = 0;
        rollover_count  = 0;
        overflow_count  = 0;
        underflow_count = 0;
        watermark_count = 0;
        foreach (ch_pred_count[i]) ch_pred_count[i] = 0;
        foreach (warn_seen[i])     warn_seen[i]     = 1'b0;
    endfunction

    //============================================================
    // BUILD PHASE — create TLM ports, reset model
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cpu_export    = new("cpu_export", this);
        dma_export    = new("dma_export", this);
        expected_port = new("expected_port", this);
        reset_model();
    endfunction

    //============================================================
    // RESET MODEL — put mirror into power-on state
    //============================================================
    function void reset_model();
        foreach (base_addr[i]) base_addr[i] = 16'h0000;
        foreach (base_wc[i])   base_wc[i]   = 16'h0000;
        foreach (curr_addr[i]) curr_addr[i] = 16'h0000;
        foreach (curr_wc[i])   curr_wc[i]   = 16'h0000;
        foreach (mode_reg[i])  mode_reg[i]  = 8'h00;
        foreach (ch_ctrl[i])   ch_ctrl[i]   = 8'h00;
        foreach (buf_size[i])  buf_size[i]  = 16'h0000;

        command_reg   = 8'h00;
        request_reg   = 8'h00;
        mask_reg      = 8'h00;
        priority_ctrl = 24'h000000;
        ext_status    = 8'h00;
        status_reg    = 8'h00;

        byte_pointer      = 1'b0;
        priority_byte_ptr = 2'b00;

        // Default priority order: CH0 highest
        ch_priority[0] = 2'b11;
        ch_priority[1] = 2'b10;
        ch_priority[2] = 2'b01;
        ch_priority[3] = 2'b00;

        valid_dreq = 4'b0000;

        foreach (buffer_used[i])     buffer_used[i]     = 16'h0000;
        rollover_latched   = 4'b0000;
        overflow_detected  = 4'b0000;
        underflow_detected = 4'b0000;
        buffer_ever_used   = 4'b0000;

        foreach (prev_curr_addr[i])   prev_curr_addr[i]   = 16'h0000;
        foreach (prev_curr_wc[i])     prev_curr_wc[i]     = 16'h0000;
        foreach (prev_buffer_used[i]) prev_buffer_used[i] = 16'h0000;
        prev_ext_status = 8'h00;
    endfunction

    //============================================================
    // WRITE CPU — called by cpu_monitor.ap
    //============================================================
    // Suffixed method name because of `uvm_analysis_imp_decl(_cpu).
    //------------------------------------------------------------
    virtual function void write_cpu(cpu_seq_item item);
        cpu_events++;
        if (item.is_read) begin
            cpu_reads++;
            handle_cpu_read(item);
        end else begin
            cpu_writes++;
            handle_cpu_write(item);
        end
    endfunction

    //============================================================
    // CPU WRITE HANDLER
    //============================================================
    // Mirrors each register write into the model state.
    // Also handles byte-pointer semantics and master-clear side-effects.
    //------------------------------------------------------------
    function void handle_cpu_write(cpu_seq_item item);
        case (item.addr)

            //--------------------------------------------------
            // Channel base address regs (16-bit)
            // Writing base addr also mirrors to curr_addr (8237 rule)
            //--------------------------------------------------
            5'h00: begin
                if (!byte_pointer) begin
                    base_addr[0][7:0] = item.data;
                    curr_addr[0][7:0] = item.data;
                end else begin
                    base_addr[0][15:8] = item.data;
                    curr_addr[0][15:8] = item.data;
                end
            end
            // (same pattern for CH1/CH2/CH3 — elided for brevity)

            //--------------------------------------------------
            // Channel word count regs (16-bit)
            //--------------------------------------------------
            5'h01: begin
                if (!byte_pointer) begin
                    base_wc[0][7:0] = item.data;
                    curr_wc[0][7:0] = item.data;
                end else begin
                    base_wc[0][15:8] = item.data;
                    curr_wc[0][15:8] = item.data;
                end
            end
            // (same pattern for CH1/CH2/CH3 — elided for brevity)

            //--------------------------------------------------
            // Control registers
            //--------------------------------------------------
            5'h08: command_reg = item.data;    // COMMAND (WO)
            5'h09: request_reg = item.data;    // REQUEST
            5'h0A: mask_reg[item.data[1:0]] = item.data[2];   // single-bit mask
            5'h0B: mode_reg[item.data[1:0]] = item.data;      // MODE (per-ch)

            //--------------------------------------------------
            // MASTER_CLEAR (0x0D) — resets many regs
            //--------------------------------------------------
            5'h0D: begin
                command_reg = 8'h00;
                request_reg = 8'h00;
                mask_reg    = 8'h00;
                foreach (mode_reg[i]) mode_reg[i] = 8'h00;
                foreach (ch_ctrl[i])  ch_ctrl[i]  = 8'h00;
                foreach (buf_size[i]) buf_size[i] = 16'h0000;
                priority_ctrl     = 24'h000000;
                byte_pointer      = 1'b0;
                priority_byte_ptr = 2'b00;
            end

            5'h0E: mask_reg = 8'h00;           // CLEAR_MASK
            5'h0F: mask_reg = item.data;       // WRITE_MASK (full byte)

            //--------------------------------------------------
            // Enhanced channel control
            //--------------------------------------------------
            5'h10: ch_ctrl[0] = item.data;
            5'h11: ch_ctrl[1] = item.data;
            5'h12: ch_ctrl[2] = item.data;
            5'h13: ch_ctrl[3] = item.data;

            //--------------------------------------------------
            // Buffer size regs (16-bit)
            //--------------------------------------------------
            5'h14: begin
                if (!byte_pointer) buf_size[0][7:0]  = item.data;
                else               buf_size[0][15:8] = item.data;
            end
            // (same for CH1/CH2/CH3)

            //--------------------------------------------------
            // 24-bit priority control (3-byte access)
            //--------------------------------------------------
            5'h18: begin
                case (priority_byte_ptr)
                    2'b00: priority_ctrl[7:0]   = item.data;
                    2'b01: priority_ctrl[15:8]  = item.data;
                    2'b10: priority_ctrl[23:16] = item.data;
                    default: ;
                endcase
            end

            default: ;
        endcase

        update_byte_pointer(item.addr);    // post-write pointer advance

        `uvm_info("REF",
            $sformatf("W  %-14s <- 0x%02X  [bp=%b pbp=%0d]",
                      item.get_register_name(), item.data,
                      byte_pointer, priority_byte_ptr),
            UVM_MEDIUM)
    endfunction

    //============================================================
    // CPU READ HANDLER — mirror is not modified by reads,
    //                    but byte pointer toggles
    //============================================================
    function void handle_cpu_read(cpu_seq_item item);
        update_byte_pointer(item.addr);

        `uvm_info("REF",
            $sformatf("R  %-14s -> 0x%02X  [bp=%b pbp=%0d]",
                      item.get_register_name(), item.data,
                      byte_pointer, priority_byte_ptr),
            UVM_MEDIUM)
    endfunction

    //============================================================
    // BYTE POINTER UPDATE
    //============================================================
    // 16-bit regs (0x00–0x07, 0x14–0x17): toggle bit
    // 24-bit reg (0x18): increment 2-bit pointer (wraps at 3)
    // 0x0C: reset both pointers
    //------------------------------------------------------------
    function void update_byte_pointer(bit [4:0] addr);
        int unsigned a;
        a = addr;
        if (a <= 5'h07) begin
            byte_pointer = ~byte_pointer;
        end
        else if (a >= 5'h14 && a <= 5'h17) begin
            byte_pointer = ~byte_pointer;
        end
        else if (a == 5'h18) begin
            priority_byte_ptr = priority_byte_ptr + 1;
        end
        else if (a == 5'h0C) begin
            byte_pointer      = 0;
            priority_byte_ptr = 0;
        end
    endfunction

    //============================================================
    // WRITE DMA — called by dma_monitor.ap
    //============================================================
    // Predicts the expected state after each XFER_PULSE.
    //------------------------------------------------------------
    virtual function void write_dma(dma_seq_item obs);
        dma_seq_item exp;

        dma_events++;

        // Only predict on transfer-complete cycles
        if (!obs.xfer_pulse) return;

        exp = dma_seq_item::type_id::create("exp");
        exp.tx_type = DMA_TRANSFER_TX;
        exp.cycle   = ACTIVE;

        //--------------------------------------------------
        // Pass-through inputs
        //--------------------------------------------------
        exp.dreq = obs.dreq;
        exp.hlda = obs.hlda;
        exp.hrq  = obs.hrq;

        //--------------------------------------------------
        // FIX M4: Independently predict grant fields.
        // (Previously copied obs.active_chnum → tautology.)
        //--------------------------------------------------
        exp.active_chnum = predict_active_channel(obs.dreq);
        exp.dack         = predict_dack(exp.active_chnum);
        exp.active_dack  = exp.dack;
        exp.valid_dack   = predict_valid_dack(obs.dreq, exp.active_chnum);
        exp.xfer_pulse   = 1'b1;

        //--------------------------------------------------
        // FIX R3: predict eop_n and timeout from internal WC
        //--------------------------------------------------
        // On the FINAL transfer, DUT asserts:
        //   eop_n = 0 (active-low)
        //   timeout = 1
        // curr_wc is checked BEFORE predict_transfer() decrements.
        //--------------------------------------------------
        if (curr_wc[exp.active_chnum] == 16'h0001) begin
            exp.eop_n   = 1'b0;
            exp.timeout = 1'b1;
        end else begin
            exp.eop_n   = 1'b1;
            exp.timeout = 1'b0;
        end

        //--------------------------------------------------
        // Advance model state for this transfer
        //--------------------------------------------------
        predict_transfer(exp.active_chnum);

        //--------------------------------------------------
        // Snapshot predicted state
        //--------------------------------------------------
        exp.buffer_used_0     = buffer_used[0];
        exp.buffer_used_1     = buffer_used[1];
        exp.buffer_used_2     = buffer_used[2];
        exp.buffer_used_3     = buffer_used[3];
        exp.rollover_status   = rollover_latched;
        exp.rollover_latched  = rollover_latched;
        exp.watermark_reached = ((buffer_used[0] >= 1) && ch_ctrl[0][2]) ||
                                ((buffer_used[1] >= 1) && ch_ctrl[1][2]) ||
                                ((buffer_used[2] >= 1) && ch_ctrl[2][2]) ||
                                ((buffer_used[3] >= 1) && ch_ctrl[3][2]);
        exp.rollover_any      = |rollover_latched;
        exp.ext_status_reg    = ext_status;

        expected_events++;
        expected_port.write(exp);   // publish to scoreboard
    endfunction

    //============================================================
    // ARBITRATION PREDICTION (FIX M4)
    //============================================================
    // Predict which channel the arbiter SHOULD grant, based on
    // observed dreq + mask + priority mode + priority vectors.
    //------------------------------------------------------------
    function bit [1:0] predict_active_channel(bit [3:0] observed_dreq);

        bit [3:0] effective_req;
        bit       adaptive_en;
        bit       rotating_priority;
        int       i;
        bit [1:0] best_ch;
        bit [1:0] best_pri;
        bit       found;

        // Step 1: apply mask
        effective_req = observed_dreq & ~mask_reg[3:0];
        if (effective_req == 4'b0000)
            return 2'b00;

        // Step 2: mode select (adaptive or fixed/rotating)
        adaptive_en       = priority_ctrl[16];
        rotating_priority = adaptive_en ? 1'b1 : command_reg[4];

        // Step 3: pick highest-priority requester
        found    = 1'b0;
        best_ch  = 2'b00;
        best_pri = 2'b00;

        for (i = 0; i < 4; i++) begin
            if (effective_req[i]) begin
                if (!found || (ch_priority[i] > best_pri)) begin
                    best_ch  = i[1:0];
                    best_pri = ch_priority[i];
                    found    = 1'b1;
                end
            end
        end

        return found ? best_ch : 2'b00;
    endfunction

    //============================================================
    // DACK PREDICTION
    //============================================================
    function bit [3:0] predict_dack(bit [1:0] ch);
        return (4'b0001 << ch);
    endfunction

    function bit predict_valid_dack(bit [3:0] observed_dreq, bit [1:0] ch);
        return observed_dreq[ch] && !mask_reg[ch];
    endfunction

    //============================================================
    // PREDICT TRANSFER — advance model state for one transfer
    //============================================================
    // This is where the reference model computes:
    //   - next address (linear or circular wrap)
    //   - WC decrement (with underflow guard)
    //   - buffer_used update
    //   - rollover / overflow / watermark flags
    //   - status_reg / ext_status updates
    //------------------------------------------------------------
    function void predict_transfer(bit [1:0] ch);

        bit [15:0] next_addr;
        bit        rollover_this_cycle = 1'b0;
        bit        circ_active;
        bit        wc_decremented      = 1'b0;
        bit        buf_incremented     = 1'b0;

        // Snapshot before update (for logging)
        prev_curr_addr[ch]   = curr_addr[ch];
        prev_curr_wc[ch]     = curr_wc[ch];
        prev_buffer_used[ch] = buffer_used[ch];
        prev_ext_status      = ext_status;

        //--------------------------------------------------
        // Circular mode active?
        //--------------------------------------------------
        circ_active = ch_ctrl[ch][7] && (buf_size[ch] != 16'h0000);

        //--------------------------------------------------
        // Address advancement
        //--------------------------------------------------
        if (circ_active) begin
            if (curr_addr[ch] >= (base_addr[ch] + buf_size[ch] - 1)) begin
                next_addr           = base_addr[ch];
                rollover_this_cycle = 1'b1;
            end else begin
                next_addr = curr_addr[ch] + 16'd1;
            end
        end else begin
            // Linear: direction from mode_reg bit 5
            if (mode_reg[ch][5]) next_addr = curr_addr[ch] - 16'd1;
            else                 next_addr = curr_addr[ch] + 16'd1;
        end
        curr_addr[ch] = next_addr;

        //--------------------------------------------------
        // Word count decrement (with underflow guard — FIX 3)
        //--------------------------------------------------
        if (curr_wc[ch] != 16'h0000) begin
            curr_wc[ch]    = curr_wc[ch] - 16'd1;
            wc_decremented = 1'b1;
        end

        //--------------------------------------------------
        // Buffer usage + rollover
        //--------------------------------------------------
        if (circ_active) begin
            if (rollover_this_cycle) begin
                rollover_latched[ch] = 1'b1;
                rollover_count++;
                if (buffer_used[ch] < buf_size[ch]) begin
                    buffer_used[ch] = buffer_used[ch] + 16'd1;
                    buf_incremented = 1'b1;
                end
            end else if (buffer_used[ch] < buf_size[ch]) begin
                buffer_used[ch] = buffer_used[ch] + 16'd1;
                buf_incremented = 1'b1;
            end

            // Overflow: buffer_used >= buf_size
            if (buffer_used[ch] >= buf_size[ch]) begin
                if (!overflow_detected[ch]) overflow_count++;
                overflow_detected[ch] = 1'b1;
            end

            if (buffer_used[ch] > 0)
                buffer_ever_used[ch] = 1'b1;
        end

        //--------------------------------------------------
        // Status flags
        //--------------------------------------------------
        if (rollover_this_cycle) begin
            ext_status[4]   = 1'b1;
            ext_status[3:0] = {2'b00, ch};
        end

        ext_status[7] = |overflow_detected;
        ext_status[6] = |underflow_detected;

        // Watermark: any channel with buffer_used >= 1 and watermark_en
        if ((buffer_used[ch] >= 1) && ch_ctrl[ch][2]) begin
            if (!ext_status[5]) watermark_count++;
            ext_status[5] = 1'b1;
        end

        // Terminal count per channel
        if (curr_wc[ch] == 16'h0000)
            status_reg[ch] = 1'b1;

        //--------------------------------------------------
        // Statistics + logging
        //--------------------------------------------------
        ch_pred_count[ch]++;

        `uvm_info("REF",
            $sformatf("XFER ch=%0d addr=0x%04X->0x%04X wc=0x%04X->0x%04X buf=%0d->%0d roll=%b%s%s",
                      ch,
                      prev_curr_addr[ch],   curr_addr[ch],
                      prev_curr_wc[ch],     curr_wc[ch],
                      prev_buffer_used[ch], buffer_used[ch],
                      rollover_this_cycle,
                      wc_decremented  ? "" : " (wc-hold)",
                      buf_incremented ? "" : " (buf-hold)"),
            UVM_MEDIUM)
    endfunction

    //============================================================
    // PER-CHANNEL COMPLETION API (FIX M3)
    //============================================================
    // Allows tests/scoreboard to verify all channels actually ran.
    //------------------------------------------------------------
    function bit channel_ran(bit [1:0] ch);
        return (ch_pred_count[ch] > 0);
    endfunction

    function bit all_channels_ran();
        return (ch_pred_count[0] > 0) &&
               (ch_pred_count[1] > 0) &&
               (ch_pred_count[2] > 0) &&
               (ch_pred_count[3] > 0);
    endfunction

    function int unsigned get_ch_pred_count(bit [1:0] ch);
        return ch_pred_count[ch];
    endfunction

    function int unsigned get_total_pred_count();
        return ch_pred_count[0] + ch_pred_count[1] +
               ch_pred_count[2] + ch_pred_count[3];
    endfunction

    function void print_channel_summary();
        `uvm_info("REF", "==================================================", UVM_LOW)
        `uvm_info("REF", "       PER-CHANNEL COMPLETION SUMMARY              ", UVM_LOW)
        `uvm_info("REF", "==================================================", UVM_LOW)
        for (int i = 0; i < 4; i++) begin
            `uvm_info("REF",
                $sformatf("  CH%0d predictions : %0d", i, ch_pred_count[i]),
                UVM_LOW)
        end
        `uvm_info("REF",
            $sformatf("  Total predictions: %0d", get_total_pred_count()),
            UVM_LOW)
        `uvm_info("REF", "==================================================", UVM_LOW)
    endfunction

    //============================================================
    // REPORT PHASE
    //============================================================
    virtual function void report_phase(uvm_phase phase);
        `uvm_info("REF", "==================================================", UVM_LOW)
        `uvm_info("REF", "         REFERENCE MODEL STATISTICS                ", UVM_LOW)
        `uvm_info("REF", "==================================================", UVM_LOW)
        `uvm_info("REF", $sformatf("  CPU events observed     : %0d", cpu_events), UVM_LOW)
        `uvm_info("REF", $sformatf("    CPU writes            : %0d", cpu_writes), UVM_LOW)
        `uvm_info("REF", $sformatf("    CPU reads             : %0d", cpu_reads),  UVM_LOW)
        `uvm_info("REF", $sformatf("  DMA events observed     : %0d", dma_events), UVM_LOW)
        `uvm_info("REF", $sformatf("  Expected events sent    : %0d", expected_events), UVM_LOW)
        `uvm_info("REF", $sformatf("  Transfer predictions    : %0d", expected_events), UVM_LOW)
        foreach (ch_pred_count[i])
            `uvm_info("REF",
                $sformatf("    CH%0d predictions       : %0d", i, ch_pred_count[i]),
                UVM_LOW)
        `uvm_info("REF", $sformatf("  Rollover predictions    : %0d", rollover_count), UVM_LOW)
        `uvm_info("REF", $sformatf("  Overflow detected       : %0d", overflow_count), UVM_LOW)
        `uvm_info("REF", $sformatf("  Underflow detected      : %0d", underflow_count), UVM_LOW)
        `uvm_info("REF", $sformatf("  Watermark hits          : %0d", watermark_count), UVM_LOW)
        `uvm_info("REF", "==================================================", UVM_LOW)
    endfunction

endclass

`endif // DMA_REFERENCE_MODEL_SV 

        //  Where the Ref Model Fits

   //  cpu_monitor.ap ──► cpu_export ──┐
   //                                  │   ┌───────────────────────┐
   //                                  ├──►│ dma_reference_model   │
   //                                  │   │ (golden behavioral)   │
   //  dma_monitor.ap ──► dma_export ──┘   └-──────────┬───────────┘
   //                                                  │
   //                                      expected_port.write(exp)
   //                                                  │
   //                                                  ▼
   //                                          dma_scoreboard
          
