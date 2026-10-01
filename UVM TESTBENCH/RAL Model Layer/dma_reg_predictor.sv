//============================================================
// File        : dma_reg_predictor.sv
// Description : UVM RAL Predictor for DMA Controller
//               Observes CPU bus transactions and updates
//               the RAL mirror registers.
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_subscriber #(cpu_seq_item) — receives bus items.
//   2. Monitor → analysis_port → predictor.write() → reg.predict().
//   3. Custom because:
//        - Multi-byte regs (16/24-bit) need byte accumulation
//        - Aliased addresses (0x08/0x0C/0x0F) require direction decode
//        - Side-effect regs (0x0C/0x0D/0x0E) need special handling
//   4. FIX 1: skip while RAL busy (avoid race with reg.read/write)
//   5. FIX 2: single lookup of target_reg per transaction
//============================================================

`ifndef DMA_REG_PREDICTOR_SV
`define DMA_REG_PREDICTOR_SV

class dma_reg_predictor extends uvm_subscriber #(cpu_seq_item);

    //------------------------------------------------------------
    // RAL model handle (set via config_db in build_phase)
    //------------------------------------------------------------
    dma_reg_block reg_model;

    //------------------------------------------------------------
    // Byte accumulation state (for 16/24-bit registers)
    //------------------------------------------------------------
    bit [4:0]  acc_addr;        // addr being accumulated
    bit        acc_is_read;     // direction of accumulation
    int        acc_byte_idx;    // which byte slot
    int        acc_num_bytes;   // total expected bytes
    bit [23:0] acc_data;        // accumulated value
    bit        acc_active;      // accumulation in progress

    //------------------------------------------------------------
    // Statistics
    //------------------------------------------------------------
    int unsigned num_predictions;
    int unsigned num_skipped;

    `uvm_component_utils(dma_reg_predictor)

    function new(string name = "dma_reg_predictor",
                 uvm_component parent = null);
        super.new(name, parent);
        num_predictions = 0;
        num_skipped     = 0;
        acc_active      = 0;
    endfunction

    //============================================================
    // BUILD PHASE — retrieve RAL model handle
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(dma_reg_block)::get(
                this, "", "reg_model", reg_model)) begin
            `uvm_fatal("PRED", "No reg_model in config_db")
        end
    endfunction

    //============================================================
    // WRITE — called for every CPU bus transaction
    //============================================================
    virtual function void write(cpu_seq_item t);

        int     num_bytes;
        bit     is_multi_byte;
        uvm_reg target_reg;

        //--------------------------------------------------------
        // Step 1: determine register width from address
        //--------------------------------------------------------
        num_bytes     = get_num_bytes(t.addr);
        is_multi_byte = (num_bytes > 1);

        //--------------------------------------------------------
        // FIX 1: skip if RAL is currently busy with this reg
        // (reg.read()/write() will update the mirror itself;
        //  predicting concurrently causes races/warnings)
        //--------------------------------------------------------
        target_reg = lookup_register(t.addr, t.is_read);
        if (target_reg != null && target_reg.is_busy()) begin
            num_skipped++;
            return;
        end

        //--------------------------------------------------------
        // Special case: 0x0C (byte-pointer reset)
        //   — no register to mirror
        //--------------------------------------------------------
        if (t.addr == 5'h0C && !t.is_read) begin
            num_skipped++;
            return;
        end

        //--------------------------------------------------------
        // Special case: 0x0D (MASTER_CLEAR)
        //   — resets many RAL mirrors
        //--------------------------------------------------------
        if (t.addr == 5'h0D && !t.is_read) begin
            handle_master_clear();
            return;
        end

        //--------------------------------------------------------
        // Special case: 0x0E (CLEAR_MASK)
        //   — sets mask mirror to 0
        //--------------------------------------------------------
        if (t.addr == 5'h0E && !t.is_read) begin
            if (reg_model.mask_reg != null) begin
                void'(reg_model.mask_reg.predict(8'h00));
                num_predictions++;
            end
            return;
        end

        //========================================================
        // MULTI-BYTE REGISTER: accumulate bytes
        //========================================================
        if (is_multi_byte) begin

            //--------------------------------------------------
            // Start new accumulation if address or direction
            // changed from previous transaction
            //--------------------------------------------------
            if (!acc_active || acc_addr != t.addr || acc_is_read != t.is_read) begin
                acc_addr      = t.addr;
                acc_is_read   = t.is_read;
                acc_byte_idx  = 0;
                acc_num_bytes = num_bytes;
                acc_data      = 24'h0;
                acc_active    = 1;
            end

            //--------------------------------------------------
            // Append this byte to the accumulator
            //--------------------------------------------------
            acc_data[acc_byte_idx*8 +: 8] = t.data;
            acc_byte_idx++;

            //--------------------------------------------------
            // All bytes collected → predict the full value
            //--------------------------------------------------
            if (acc_byte_idx >= acc_num_bytes) begin
                if (target_reg != null) begin
                    case (num_bytes)
                        2: begin
                            void'(target_reg.predict(acc_data[15:0]));
                            `uvm_info("PRED",
                                $sformatf("Predicted %s = 0x%04h (from %0d bytes)",
                                          target_reg.get_name(),
                                          acc_data[15:0],
                                          acc_num_bytes),
                                UVM_HIGH)
                        end
                        3: begin
                            void'(target_reg.predict(acc_data[23:0]));
                            `uvm_info("PRED",
                                $sformatf("Predicted %s = 0x%06h (from %0d bytes)",
                                          target_reg.get_name(),
                                          acc_data[23:0],
                                          acc_num_bytes),
                                UVM_HIGH)
                        end
                        default: begin
                            void'(target_reg.predict(acc_data[7:0]));
                            `uvm_info("PRED",
                                $sformatf("Predicted %s = 0x%02h (unexpected width)",
                                          target_reg.get_name(),
                                          acc_data[7:0]),
                                UVM_HIGH)
                        end
                    endcase
                    num_predictions++;
                end
                acc_active = 0;      // reset for next multi-byte reg
            end

        end
        //========================================================
        // SINGLE-BYTE REGISTER: direct predict
        //========================================================
        else begin
            if (target_reg != null) begin
                void'(target_reg.predict(t.data));
                num_predictions++;
                `uvm_info("PRED",
                    $sformatf("Predicted %s = 0x%02X",
                              target_reg.get_name(), t.data),
                    UVM_HIGH)
            end
        end
    endfunction

    //============================================================
    // HELPER: get_num_bytes — width by address
    //============================================================
    protected function int get_num_bytes(bit [4:0] addr);
        case (addr)
            // 16-bit registers
            5'h00, 5'h01, 5'h02, 5'h03,
            5'h04, 5'h05, 5'h06, 5'h07,   // base addr / word count
            5'h14, 5'h15, 5'h16, 5'h17:   // buffer size
                return 2;
            // 24-bit register
            5'h18:                        // priority control
                return 3;
            // 8-bit (default)
            default:
                return 1;
        endcase
    endfunction

    //============================================================
    // HELPER: lookup_register — addr (+ direction) → reg handle
    //============================================================
    // Aliased addresses:
    //   0x08 → STATUS (read) / COMMAND (write)
    //   0x0F → READ_MASK (read) / WRITE_MASK (write)
    //   0x0C → no mirror (byte-pointer reset)
    //   0x0D → no mirror (master clear, handled separately)
    //   0x0E → no mirror (clear mask, handled separately)
    //------------------------------------------------------------
    protected function uvm_reg lookup_register(bit [4:0] addr, bit is_read);
        case (addr)
            // Channel registers
            5'h00: return reg_model.base_addr_ch0;
            5'h01: return reg_model.base_wc_ch0;
            5'h02: return reg_model.base_addr_ch1;
            5'h03: return reg_model.base_wc_ch1;
            5'h04: return reg_model.base_addr_ch2;
            5'h05: return reg_model.base_wc_ch2;
            5'h06: return reg_model.base_addr_ch3;
            5'h07: return reg_model.base_wc_ch3;

            // Aliased: CMD (write) / STATUS (read)
            5'h08: return is_read ? reg_model.status_reg
                                  : reg_model.command_reg;

            // Control
            5'h09: return reg_model.request_reg;
            5'h0A: return reg_model.mask_reg;
            5'h0B: return reg_model.mode_reg;

            // Byte-pointer reset — no mirror
            5'h0C: return null;

            // Master clear — no mirror (handled specially)
            5'h0D: return null;

            // Clear mask — no mirror (handled specially)
            5'h0E: return null;

            // Aliased: WRITE_MASK (write) / READ_MASK (read)
            5'h0F: return is_read ? reg_model.read_mask_reg
                                  : reg_model.write_mask_reg;

            // Enhanced
            5'h10: return reg_model.ch_ctrl_reg_0;
            5'h11: return reg_model.ch_ctrl_reg_1;
            5'h12: return reg_model.ch_ctrl_reg_2;
            5'h13: return reg_model.ch_ctrl_reg_3;
            5'h14: return reg_model.buf_size_reg_0;
            5'h15: return reg_model.buf_size_reg_1;
            5'h16: return reg_model.buf_size_reg_2;
            5'h17: return reg_model.buf_size_reg_3;
            5'h18: return reg_model.priority_ctrl_reg;
            5'h19: return reg_model.ext_status_reg;

            default: return null;
        endcase
    endfunction

    //============================================================
    // HELPER: handle_master_clear — reset affected mirrors
    //============================================================
    protected function void handle_master_clear();
        if (reg_model.command_reg       != null) void'(reg_model.command_reg.predict(8'h00));
        if (reg_model.request_reg       != null) void'(reg_model.request_reg.predict(8'h00));
        if (reg_model.mask_reg          != null) void'(reg_model.mask_reg.predict(8'h00));
        if (reg_model.mode_reg          != null) void'(reg_model.mode_reg.predict(8'h00));
        if (reg_model.ch_ctrl_reg_0     != null) void'(reg_model.ch_ctrl_reg_0.predict(8'h00));
        if (reg_model.ch_ctrl_reg_1     != null) void'(reg_model.ch_ctrl_reg_1.predict(8'h00));
        if (reg_model.ch_ctrl_reg_2     != null) void'(reg_model.ch_ctrl_reg_2.predict(8'h00));
        if (reg_model.ch_ctrl_reg_3     != null) void'(reg_model.ch_ctrl_reg_3.predict(8'h00));
        if (reg_model.buf_size_reg_0    != null) void'(reg_model.buf_size_reg_0.predict(16'h0000));
        if (reg_model.buf_size_reg_1    != null) void'(reg_model.buf_size_reg_1.predict(16'h0000));
        if (reg_model.buf_size_reg_2    != null) void'(reg_model.buf_size_reg_2.predict(16'h0000));
        if (reg_model.buf_size_reg_3    != null) void'(reg_model.buf_size_reg_3.predict(16'h0000));
        if (reg_model.priority_ctrl_reg != null) void'(reg_model.priority_ctrl_reg.predict(24'h000000));

        `uvm_info("PRED", "Master clear - RAL mirrors cleared", UVM_MEDIUM)
        num_predictions++;
    endfunction

    //============================================================
    // REPORT PHASE — print statistics
    //============================================================
    virtual function void report_phase(uvm_phase phase);
        `uvm_info("PRED",
            $sformatf("Predictor stats: %0d predictions, %0d skipped",
                      num_predictions, num_skipped),
            UVM_LOW)
    endfunction

endclass

`endif // DMA_REG_PREDICTOR_SV

  //Where the Predictor Fits

   // DUT ──► cpu_monitor ──► analysis_port ──► dma_reg_predictor.write()
   //                                                  │
   //                                                  │ reg.predict(value)
   //                                                  ▼
   //                                          dma_reg_block mirror
   //                                                  │
   //                                                  │ scoreboard compares
   //                                                  ▼
   //                                          against expected values
