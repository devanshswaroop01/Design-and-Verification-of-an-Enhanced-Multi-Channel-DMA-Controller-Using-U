//============================================================
// File        : dma_sequence_library.sv
// Description : Merged UVM Sequence Library for DMA Controller
//
// Project     : Enhanced Multi-Channel DMA Controller
// UVM Version : 1.2
//
// ROLE:
//   Single compilation unit containing all baseline and extended
//   sequences. Merged from many small files to reduce compile
//   time and file count.
//
// CONTAINS (in this order):
//   Section 1 : dma_base_sequence          (base + helpers)
//   Section 2 : dma_reg_write_seq          (register writes)
//   Section 3 : dma_reg_read_seq           (register reads)
//   Section 4 : dma_base_addr_seq          (channel base + WC)
//   Section 5 : dma_channel_config_seq     (channel sweep)
//   Section 6 : dma_mixed_programming_seq  (RW mixed)
//   Section 7 : dma_dma_read_seq           (DMA read config)
//   Section 8 : dma_dma_write_seq          (DMA write config)
//   Section 9 : dma_back_to_back_seq       (multi-channel cfg)
//   Section 10: dma_random_reg_cfg_seq     (raw register random)
//   Section 11: dma_random_regression_seq  (mixed random ops)
//   Section 12: dma_random_reg_seq         (RAL-based random)
//   Section 13: dma_random_transfer_seq    (random DMA config)
//   Section 14: dma_random_priority_seq    (random arbiter cfg)
//   Section 15: dma_stress_seq             (high-volume stress)
//   Section 16: dma_transfer_seq           (actual DMA drive)
//
// INTERVIEW POINTS:
//   1. Base sequence provides send_write/send_read helpers.
//   2. 16-bit regs need: clear byte-ptr → low byte → high byte.
//   3. 24-bit regs need: clear byte-ptr → 3 bytes LSB-first.
//   4. Some sequences use raw bus writes, others use RAL.
//   5. Sequences that randomize internally must NOT be
//      re-randomized by the test (or vice versa — FIX A).
//============================================================

`ifndef DMA_SEQUENCE_LIBRARY_SV
`define DMA_SEQUENCE_LIBRARY_SV


//============================================================
// SECTION 1: BASE SEQUENCE
//============================================================
// Provides send_write / send_read helpers used by every
// derived sequence. Also acts as the typed base (cpu_seq_item).
//------------------------------------------------------------
class dma_base_sequence extends uvm_sequence #(cpu_seq_item);

    cpu_seq_item tx;

    `uvm_object_utils(dma_base_sequence)

    function new(string name = "dma_base_sequence");
        super.new(name);
    endfunction

    // Base has no scenario — derived classes override.
    virtual task body();
        `uvm_info("BASE_SEQ", "Base sequence running (no scenario)", UVM_MEDIUM)
    endtask

    //--------------------------------------------------------
    // send_write: single byte write to `addr` with `data`
    //--------------------------------------------------------
    task send_write(bit [4:0] addr, bit [7:0] data);
        tx = cpu_seq_item::type_id::create("tx");
        start_item(tx);
        tx.is_read = 1'b0;
        tx.addr    = addr;
        tx.data    = data;
        finish_item(tx);
    endtask

    //--------------------------------------------------------
    // send_read: single byte read from `addr`, returns data
    //--------------------------------------------------------
    task send_read(bit [4:0] addr, output bit [7:0] data);
        cpu_seq_item rsp;
        tx = cpu_seq_item::type_id::create("tx");
        start_item(tx);
        tx.is_read = 1'b1;
        tx.addr    = addr;
        finish_item(tx);
        rsp  = tx;          // driver modifies tx in place
        data = rsp.data;
    endtask

endclass


//============================================================
// SECTION 2: REGISTER WRITE SEQUENCE
//============================================================
// Writes all 5 register groups (channel regs, control regs,
// CH_CTRL, BUF_SIZE, PRIORITY). Useful as a bring-up test.
//------------------------------------------------------------
class dma_reg_write_seq extends dma_base_sequence;

    `uvm_object_utils(dma_reg_write_seq)

    function new(string name = "dma_reg_write_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info("REG_WRITE_SEQ", "Starting register write sequence", UVM_LOW)

        // Group 1: Channel base + word count (16-bit)
        write_16bit(5'h00, 16'h1000);   // BASE_ADDR_CH0
        write_16bit(5'h01, 16'h0080);   // BASE_WC_CH0
        write_16bit(5'h02, 16'h2000);   // BASE_ADDR_CH1
        write_16bit(5'h03, 16'h0100);   // BASE_WC_CH1
        write_16bit(5'h04, 16'h3000);   // BASE_ADDR_CH2
        write_16bit(5'h05, 16'h0040);   // BASE_WC_CH2
        write_16bit(5'h06, 16'h4000);   // BASE_ADDR_CH3
        write_16bit(5'h07, 16'h0020);   // BASE_WC_CH3

        // Group 2: Control registers (8-bit)
        send_write(5'h08, 8'h01);       // COMMAND (dma_en=1)
        send_write(5'h09, 8'h0F);       // REQUEST (all ch)
        send_write(5'h0A, 8'h04);       // MASK (single-bit form)
        send_write(5'h0B, 8'h85);       // MODE
        send_write(5'h0E, 8'h00);       // CLEAR_MASK
        send_write(5'h0F, 8'h0F);       // WRITE_MASK (full byte)

        // Group 3: Channel control
        send_write(5'h10, 8'h87);       // CH_CTRL_CH0
        send_write(5'h11, 8'h47);       // CH_CTRL_CH1
        send_write(5'h12, 8'h83);       // CH_CTRL_CH2
        send_write(5'h13, 8'h01);       // CH_CTRL_CH3

        // Group 4: Buffer sizes (16-bit)
        write_16bit(5'h14, 16'h0100);   // BUF_SIZE_CH0
        write_16bit(5'h15, 16'h0080);   // BUF_SIZE_CH1
        write_16bit(5'h16, 16'h0040);   // BUF_SIZE_CH2
        write_16bit(5'h17, 16'h0020);   // BUF_SIZE_CH3

        // Group 5: Priority control (24-bit)
        write_24bit(5'h18, 24'h015555); // adaptive + weighted + aging

        `uvm_info("REG_WRITE_SEQ", "Register write sequence complete", UVM_LOW)
    endtask

    // Clear byte ptr, then low byte, then high byte
    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask

    // Clear byte ptr, then 3 bytes LSB-first
    task write_24bit(bit [4:0] addr, bit [23:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
        send_write(addr, data[23:16]);
    endtask

endclass


//============================================================
// SECTION 3: REGISTER READ SEQUENCE
//============================================================
// Reads back all readable registers for a smoke check of
// read-path and byte-pointer behavior.
//------------------------------------------------------------
class dma_reg_read_seq extends dma_base_sequence;

    `uvm_object_utils(dma_reg_read_seq)

    function new(string name = "dma_reg_read_seq");
        super.new(name);
    endfunction

    virtual task body();
        bit [15:0] val16;
        bit [23:0] val24;
        bit [7:0]  val8;

        `uvm_info("REG_READ_SEQ", "Starting register read sequence", UVM_LOW)

        // Group 1: Channel current addresses (16-bit)
        read_16bit(5'h00, val16);
        read_16bit(5'h02, val16);
        read_16bit(5'h04, val16);
        read_16bit(5'h06, val16);

        // Group 2: Channel current word counts
        read_16bit(5'h01, val16);
        read_16bit(5'h03, val16);
        read_16bit(5'h05, val16);
        read_16bit(5'h07, val16);

        // Group 3: Control registers (8-bit)
        send_read(5'h08, val8);     // STATUS
        send_read(5'h0B, val8);     // MODE
        send_read(5'h0F, val8);     // READ_MASK

        // Group 4: Extended status
        send_read(5'h19, val8);     // EXT_STATUS

        // Group 5: Priority control (24-bit)
        read_24bit(5'h18, val24);

        `uvm_info("REG_READ_SEQ", "Register read sequence complete", UVM_LOW)
    endtask

    // Clear byte ptr → read lo → read hi → assemble {hi, lo}
    task read_16bit(bit [4:0] addr, output bit [15:0] data);
        bit [7:0] lo, hi;
        send_write(5'h0C, 8'h00);
        send_read(addr, lo);
        send_read(addr, hi);
        data = {hi, lo};
        `uvm_info("REG_READ_SEQ",
            $sformatf("  READ 0x%02X = 0x%04X", addr, data), UVM_HIGH)
    endtask

    // Clear byte ptr → read 3 bytes → assemble {b2, b1, b0}
    task read_24bit(bit [4:0] addr, output bit [23:0] data);
        bit [7:0] b0, b1, b2;
        send_write(5'h0C, 8'h00);
        send_read(addr, b0);
        send_read(addr, b1);
        send_read(addr, b2);
        data = {b2, b1, b0};
        `uvm_info("REG_READ_SEQ",
            $sformatf("  READ 0x%02X = 0x%06X", addr, data), UVM_HIGH)
    endtask

endclass


//============================================================
// SECTION 4: BASE ADDRESS + WORD COUNT PROGRAMMING
//============================================================
// Programs all 4 channels with base addr, WC, and MODE.
//------------------------------------------------------------
class dma_base_addr_seq extends dma_base_sequence;

    `uvm_object_utils(dma_base_addr_seq)

    function new(string name = "dma_base_addr_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info("BASE_ADDR_SEQ",
            "Programming base address and word count for all channels",
            UVM_LOW)

        program_channel(2'd0, 16'h1000, 16'h0080, 8'h00);
        program_channel(2'd1, 16'h2000, 16'h0100, 8'h01);
        program_channel(2'd2, 16'h3000, 16'h0040, 8'h02);
        program_channel(2'd3, 16'h4000, 16'h0020, 8'h03);

        `uvm_info("BASE_ADDR_SEQ",
            "Base address programming complete", UVM_LOW)
    endtask

    // Program base, WC, and MODE for one channel
    task program_channel(bit [1:0] channel,
                         bit [15:0] base_addr,
                         bit [15:0] word_count,
                         bit [7:0]  channel_sel);
        bit [4:0] addr_reg = {channel, 1'b0};   // 0x00,0x02,0x04,0x06
        bit [4:0] wc_reg   = {channel, 1'b1};   // 0x01,0x03,0x05,0x07
        bit [7:0] mode_val;

        write_16bit(addr_reg, base_addr);
        write_16bit(wc_reg,   word_count);

        // MODE: single, increment, no auto-init, Write, ch_sel
        mode_val = {2'b01, 1'b0, 1'b0, 2'b01, channel_sel[1:0]};
        send_write(5'h0B, mode_val);

        `uvm_info("BASE_ADDR_SEQ",
            $sformatf("CH%0d programmed: base=0x%04X wc=0x%04X mode=0x%02X",
                      channel, base_addr, word_count, mode_val),
            UVM_MEDIUM)
    endtask

    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask

endclass


//============================================================
// SECTION 5: CHANNEL CONFIGURATION SWEEP
//============================================================
// Configures each channel with a different mode (circular,
// buffer, basic) and reads back for verification.
//------------------------------------------------------------
class dma_channel_config_seq extends dma_base_sequence;

    `uvm_object_utils(dma_channel_config_seq)

    function new(string name = "dma_channel_config_seq");
        super.new(name);
    endfunction

    virtual task body();
        bit [15:0] rb16;
        bit [7:0]  rb8;

        `uvm_info("CH_CFG_SEQ", "Starting 4-channel configuration sweep", UVM_LOW)

        // CH0: circular + watermark + buffer enable
        program_channel(2'd0, 16'h1000, 16'h0010);
        send_write(5'h10, 8'h87);
        write_16bit(5'h14, 16'h0100);
        readback_channel(2'd0, rb16, rb8);

        // CH1: buffer enable only
        program_channel(2'd1, 16'h2000, 16'h0020);
        send_write(5'h11, 8'h47);

        // CH2: circular + buffer enable
        program_channel(2'd2, 16'h3000, 16'h0030);
        send_write(5'h12, 8'h83);
        write_16bit(5'h16, 16'h0040);

        // CH3: channel enable only
        program_channel(2'd3, 16'h4000, 16'h0040);
        send_write(5'h13, 8'h01);

        send_write(5'h0E, 8'h00);   // CLEAR_MASK (unmask all)
        send_write(5'h08, 8'h01);   // COMMAND (enable DMA)

        `uvm_info("CH_CFG_SEQ", "Channel configuration sweep complete", UVM_LOW)
    endtask

    task program_channel(bit [1:0] channel,
                         bit [15:0] base_addr,
                         bit [15:0] word_count);
        bit [4:0] addr_reg = {channel, 1'b0};
        bit [4:0] wc_reg   = {channel, 1'b1};
        bit [7:0] mode_val;

        write_16bit(addr_reg, base_addr);
        write_16bit(wc_reg,   word_count);
        mode_val = {2'b01, 1'b0, 1'b0, 2'b10, channel};   // Read transfer
        send_write(5'h0B, mode_val);
    endtask

    task readback_channel(bit [1:0] channel,
                          output bit [15:0] base_addr_rb,
                          output bit [7:0]  ch_ctrl_rb);
        bit [4:0] addr_reg = {channel, 1'b0};
        read_16bit(addr_reg, base_addr_rb);
        case (channel)
            2'd0: send_read(5'h10, ch_ctrl_rb);
            2'd1: send_read(5'h11, ch_ctrl_rb);
            2'd2: send_read(5'h12, ch_ctrl_rb);
            2'd3: send_read(5'h13, ch_ctrl_rb);
        endcase
        `uvm_info("CH_CFG_SEQ",
            $sformatf("CH%0d readback: base=0x%04X ch_ctrl=0x%02X",
                      channel, base_addr_rb, ch_ctrl_rb),
            UVM_MEDIUM)
    endtask

    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask

    task read_16bit(bit [4:0] addr, output bit [15:0] data);
        bit [7:0] lo, hi;
        send_write(5'h0C, 8'h00);
        send_read(addr, lo);
        send_read(addr, hi);
        data = {hi, lo};
    endtask

endclass


//============================================================
// SECTION 6: MIXED PROGRAMMING (write + read + verify)
//============================================================
// Realistic mixed sequence: writes then readback-check.
//------------------------------------------------------------
class dma_mixed_programming_seq extends dma_base_sequence;

    `uvm_object_utils(dma_mixed_programming_seq)

    function new(string name = "dma_mixed_programming_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info("MIXED_SEQ", "Starting realistic mixed programming", UVM_LOW)

        write_read_check_16bit(5'h00, 16'h1234, "BASE_ADDR_CH0");
        write_read_check_16bit(5'h01, 16'h0080, "BASE_WC_CH0");

        send_write(5'h08, 8'h01);                 // COMMAND (write-only)
        `uvm_info("MIXED_SEQ", "  WROTE COMMAND = 0x01", UVM_MEDIUM)

        write_read_check_8bit(5'h0B, 8'h44, "MODE");
        write_read_check_8bit(5'h10, 8'h87, "CH_CTRL_0");
        write_read_check_16bit(5'h14, 16'h0100, "BUF_SIZE_0");
        write_read_check_24bit(5'h18, 24'h015555, "PRIORITY_CTRL");

        // Second MODE readback to verify stickiness
        begin
            bit [7:0] mode_rb;
            send_read(5'h0B, mode_rb);
            if (mode_rb == 8'h44)
                `uvm_info("MIXED_SEQ", "  READ MODE = 0x44 (as expected)", UVM_MEDIUM)
            else
                `uvm_error("MIXED_SEQ",
                    $sformatf("MODE readback mismatch: exp=0x44 obs=0x%02X", mode_rb))
        end

        send_write(5'h0D, 8'h00);                 // MASTER_CLEAR
        `uvm_info("MIXED_SEQ", "  MASTER_CLEAR issued", UVM_MEDIUM)
        `uvm_info("MIXED_SEQ", "Mixed programming sequence complete", UVM_LOW)
    endtask

    task write_read_check_8bit(bit [4:0] addr, bit [7:0] expected, string name);
        bit [7:0] readback;
        send_write(addr, expected);
        send_read(addr, readback);
        if (readback == expected)
            `uvm_info("MIXED_SEQ",
                $sformatf("  %s = 0x%02X (RW OK)", name, expected), UVM_MEDIUM)
        else
            `uvm_error("MIXED_SEQ",
                $sformatf("%s RW mismatch: exp=0x%02X obs=0x%02X",
                          name, expected, readback))
    endtask

    task write_read_check_16bit(bit [4:0] addr, bit [15:0] expected, string name);
        bit [15:0] readback;
        write_16bit(addr, expected);
        read_16bit(addr, readback);
        if (readback == expected)
            `uvm_info("MIXED_SEQ",
                $sformatf("  %s = 0x%04X (RW OK)", name, expected), UVM_MEDIUM)
        else
            `uvm_error("MIXED_SEQ",
                $sformatf("%s RW mismatch: exp=0x%04X obs=0x%04X",
                          name, expected, readback))
    endtask

    task write_read_check_24bit(bit [4:0] addr, bit [23:0] expected, string name);
        bit [23:0] readback;
        write_24bit(addr, expected);
        read_24bit(addr, readback);
        if (readback == expected)
            `uvm_info("MIXED_SEQ",
                $sformatf("  %s = 0x%06X (RW OK)", name, expected), UVM_MEDIUM)
        else
            `uvm_error("MIXED_SEQ",
                $sformatf("%s RW mismatch: exp=0x%06X obs=0x%06X",
                          name, expected, readback))
    endtask

    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask
    task read_16bit(bit [4:0] addr, output bit [15:0] data);
        bit [7:0] lo, hi;
        send_write(5'h0C, 8'h00);
        send_read(addr, lo);
        send_read(addr, hi);
        data = {hi, lo};
    endtask
    task write_24bit(bit [4:0] addr, bit [23:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
        send_write(addr, data[23:16]);
    endtask
    task read_24bit(bit [4:0] addr, output bit [23:0] data);
        bit [7:0] b0, b1, b2;
        send_write(5'h0C, 8'h00);
        send_read(addr, b0);
        send_read(addr, b1);
        send_read(addr, b2);
        data = {b2, b1, b0};
    endtask

endclass


//============================================================
// SECTION 7: DMA READ CONFIGURATION SEQUENCE
//============================================================
// Configures a channel for DMA read (I/O → memory).
// Parameters constrained by the test BEFORE start().
//------------------------------------------------------------
class dma_dma_read_seq extends dma_base_sequence;

    // Configurable, test-constrained
    rand bit [1:0]  channel;
    rand bit [15:0] base_addr;
    rand bit [15:0] word_count;

    constraint c_channel { channel inside {[0:3]}; }
    constraint c_base    { base_addr inside {[16'h1000 : 16'hE000]};
                           base_addr[3:0] == 4'h0; }    // 16-byte align
    constraint c_wc      { word_count inside {[16'h0001 : 16'h0100]}; }

    `uvm_object_utils(dma_dma_read_seq)

    function new(string name = "dma_dma_read_seq");
        super.new(name);
        channel    = 2'd0;
        base_addr  = 16'h1000;
        word_count = 16'h0010;
    endfunction

    virtual task body();
        bit [4:0] addr_reg;
        bit [4:0] wc_reg;
        bit [7:0] mode_val;

        // NOTE: no internal randomize() — test constrains before start

        `uvm_info("DMA_READ_SEQ",
            $sformatf("Configuring CH%0d for DMA read: base=0x%04X wc=0x%04X",
                      channel, base_addr, word_count),
            UVM_LOW)

        addr_reg = {channel, 1'b0};
        wc_reg   = {channel, 1'b1};

        write_16bit(addr_reg, base_addr);
        write_16bit(wc_reg,   word_count);

        // MODE: single, increment, no auto-init, Read, ch
        mode_val = {2'b01, 1'b0, 1'b0, 2'b10, channel};
        send_write(5'h0B, mode_val);

        // Enable channel
        case (channel)
            2'd0: send_write(5'h10, 8'h01);
            2'd1: send_write(5'h11, 8'h01);
            2'd2: send_write(5'h12, 8'h01);
            2'd3: send_write(5'h13, 8'h01);
        endcase

        send_write(5'h0E, 8'h00);      // CLEAR_MASK
        send_write(5'h08, 8'h01);      // COMMAND (dma_en)

        `uvm_info("DMA_READ_SEQ",
            $sformatf("CH%0d configured for DMA read transfer", channel),
            UVM_LOW)
    endtask

    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask

endclass


//============================================================
// SECTION 8: DMA WRITE CONFIGURATION SEQUENCE
//============================================================
// Configures a channel for DMA write (memory → I/O).
//------------------------------------------------------------
class dma_dma_write_seq extends dma_base_sequence;

    rand bit [1:0]  channel;
    rand bit [15:0] base_addr;
    rand bit [15:0] word_count;

    constraint c_channel { channel inside {[0:3]}; }
    constraint c_base    { base_addr inside {[16'h1000 : 16'hE000]};
                           base_addr[3:0] == 4'h0; }
    constraint c_wc      { word_count inside {[16'h0001 : 16'h0100]}; }

    `uvm_object_utils(dma_dma_write_seq)

    function new(string name = "dma_dma_write_seq");
        super.new(name);
        channel    = 2'd0;
        base_addr  = 16'h1000;
        word_count = 16'h0010;
    endfunction

    virtual task body();
        bit [4:0] addr_reg;
        bit [4:0] wc_reg;
        bit [7:0] mode_val;

        `uvm_info("DMA_WRITE_SEQ",
            $sformatf("Configuring CH%0d for DMA write: base=0x%04X wc=0x%04X",
                      channel, base_addr, word_count),
            UVM_LOW)

        addr_reg = {channel, 1'b0};
        wc_reg   = {channel, 1'b1};

        write_16bit(addr_reg, base_addr);
        write_16bit(wc_reg,   word_count);

        // MODE: single, increment, no auto-init, Write, ch
        mode_val = {2'b01, 1'b0, 1'b0, 2'b01, channel};
        send_write(5'h0B, mode_val);

        case (channel)
            2'd0: send_write(5'h10, 8'h01);
            2'd1: send_write(5'h11, 8'h01);
            2'd2: send_write(5'h12, 8'h01);
            2'd3: send_write(5'h13, 8'h01);
        endcase

        send_write(5'h0E, 8'h00);
        send_write(5'h08, 8'h01);

        `uvm_info("DMA_WRITE_SEQ",
            $sformatf("CH%0d configured for DMA write transfer", channel),
            UVM_LOW)
    endtask

    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask

endclass


//============================================================
// SECTION 9: BACK-TO-BACK MULTI-CHANNEL CONFIGURATION
//============================================================
// Configures CH0/CH1 as Read, CH2/CH3 as Write; verifies base
// addresses; enables DMA. Exercises rapid register sequences.
//------------------------------------------------------------
class dma_back_to_back_seq extends dma_base_sequence;

    `uvm_object_utils(dma_back_to_back_seq)

    function new(string name = "dma_back_to_back_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info("B2B_SEQ", "Starting back-to-back config sequence", UVM_LOW)

        configure_channel(2'd0, 16'h1000, 16'h0010, 2'b10);  // Read
        configure_channel(2'd1, 16'h2000, 16'h0020, 2'b01);  // Write
        configure_channel(2'd2, 16'h3000, 16'h0030, 2'b10);  // Read
        configure_channel(2'd3, 16'h4000, 16'h0040, 2'b01);  // Write

        verify_channel(2'd0, 16'h1000, "CH0");
        verify_channel(2'd1, 16'h2000, "CH1");
        verify_channel(2'd2, 16'h3000, "CH2");
        verify_channel(2'd3, 16'h4000, "CH3");

        send_write(5'h0E, 8'h00);    // CLEAR_MASK
        send_write(5'h08, 8'h01);    // COMMAND

        `uvm_info("B2B_SEQ", "Back-to-back configuration complete", UVM_LOW)
    endtask

    task configure_channel(bit [1:0]  channel,
                           bit [15:0] base_addr,
                           bit [15:0] word_count,
                           bit [1:0]  trans_type);
        bit [4:0] addr_reg = {channel, 1'b0};
        bit [4:0] wc_reg   = {channel, 1'b1};
        bit [7:0] mode_val;

        write_16bit(addr_reg, base_addr);
        write_16bit(wc_reg,   word_count);
        mode_val = {2'b01, 1'b0, 1'b0, trans_type, channel};
        send_write(5'h0B, mode_val);

        case (channel)
            2'd0: send_write(5'h10, 8'h01);
            2'd1: send_write(5'h11, 8'h01);
            2'd2: send_write(5'h12, 8'h01);
            2'd3: send_write(5'h13, 8'h01);
        endcase

        `uvm_info("B2B_SEQ",
            $sformatf("  CH%0d: base=0x%04X wc=0x%04X trans=%s",
                      channel, base_addr, word_count,
                      (trans_type == 2'b10) ? "READ" : "WRITE"),
            UVM_HIGH)
    endtask

    task verify_channel(bit [1:0]  channel,
                        bit [15:0] expected_base,
                        string     name);
        bit [15:0] actual_base;
        bit [4:0]  addr_reg = {channel, 1'b0};
        read_16bit(addr_reg, actual_base);
        if (actual_base == expected_base)
            `uvm_info("B2B_SEQ",
                $sformatf("  %s base verify OK: 0x%04X", name, actual_base),
                UVM_MEDIUM)
        else
            `uvm_error("B2B_SEQ",
                $sformatf("%s base mismatch: exp=0x%04X obs=0x%04X",
                          name, expected_base, actual_base))
    endtask

    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask
    task read_16bit(bit [4:0] addr, output bit [15:0] data);
        bit [7:0] lo, hi;
        send_write(5'h0C, 8'h00);
        send_read(addr, lo);
        send_read(addr, hi);
        data = {hi, lo};
    endtask

endclass


//============================================================
// SECTION 10: RANDOM RAW-REGISTER CONFIGURATION
//============================================================
// Random byte writes/reads across the register map (raw bus,
// no RAL). Used for low-level randomization and DUT robustness.
//------------------------------------------------------------
class dma_random_reg_cfg_seq extends dma_base_sequence;

    rand int unsigned num_ops;
    constraint c_num_ops { num_ops inside {[10:200]}; }

    `uvm_object_utils(dma_random_reg_cfg_seq)

    function new(string name = "dma_random_reg_cfg_seq");
        super.new(name);
        num_ops = 50;
    endfunction

    virtual task body();
        bit [4:0] addr;
        bit [7:0] data;
        bit [7:0] rd;

        `uvm_info("RAND_REG_CFG_SEQ",
            $sformatf("Starting random register config: %0d ops", num_ops),
            UVM_LOW)

        send_write(5'h0D, 8'h00);   // start with MASTER_CLEAR

        repeat (num_ops) begin
            addr = $urandom_range(0, 25);        // 0x00..0x19
            data = random_data();

            if ($urandom_range(0, 4) == 0) begin // 20% reads
                send_read(addr, rd);
                `uvm_info("RAND_REG_CFG_SEQ",
                    $sformatf("  R addr=0x%02X data=0x%02X", addr, rd),
                    UVM_HIGH)
            end else begin                        // 80% writes
                send_write(addr, data);
                `uvm_info("RAND_REG_CFG_SEQ",
                    $sformatf("  W addr=0x%02X data=0x%02X", addr, data),
                    UVM_HIGH)
            end
        end

        `uvm_info("RAND_REG_CFG_SEQ", "Random register config complete", UVM_LOW)
    endtask

    // Edge-weighted data distribution
    function bit [7:0] random_data();
        int choice = $urandom_range(0, 9);
        case (choice)
            0: return 8'h00;                    // 10% zero
            1: return 8'hFF;                    // 10% all ones
            2: return 8'hAA;                    // 10% alt
            3: return 8'h55;                    // 10% alt
            4: return {4'hF, 4'b0};             // 10% hi-nibble
            5: return {4'b0, 4'hF};             // 10% lo-nibble
            default: return $urandom & 8'hFF;   // 40% full random
        endcase
    endfunction

endclass


//============================================================
// SECTION 11: RANDOM REGRESSION (mixed ops, raw bus)
//============================================================
// Mixed operation random regression: writes, reads, channel
// config, priority config, and periodic MASTER_CLEAR.
//------------------------------------------------------------
class dma_random_regression_seq extends dma_base_sequence;

    rand int unsigned num_iterations;
    rand int unsigned mc_interval;

    constraint c_iters { num_iterations inside {[50:1000]}; }
    constraint c_mc    { mc_interval    inside {[10:100]};  }

    `uvm_object_utils(dma_random_regression_seq)

    function new(string name = "dma_random_regression_seq");
        super.new(name);
        num_iterations = 100;
        mc_interval    = 25;
    endfunction

    virtual task body();
        int mc_counter = 0;

        `uvm_info("RAND_REGRESSION_SEQ",
            $sformatf("Starting random regression: %0d iters, MC every %0d",
                      num_iterations, mc_interval),
            UVM_LOW)

        send_write(5'h0D, 8'h00);   // initial clear

        repeat (num_iterations) begin
            int op = $urandom_range(0, 7);

            case (op)
                // 3/8: random register write
                0, 1, 2: begin
                    bit [4:0] addr = $urandom_range(0, 25);
                    bit [7:0] data = $urandom & 8'hFF;
                    send_write(addr, data);
                end
                // 1/8: random read
                3: begin
                    bit [4:0] addr = $urandom_range(0, 25);
                    bit [7:0] rd;
                    send_read(addr, rd);
                end
                // 2/8: random channel configure
                4, 5: begin
                    int ch = $urandom_range(0, 3);
                    bit [15:0] base = $urandom_range(16'h1000, 16'hE000);
                    bit [15:0] wc   = $urandom_range(1, 128);
                    bit [4:0]  addr_reg = {ch[1:0], 1'b0};
                    bit [4:0]  wc_reg   = {ch[1:0], 1'b1};
                    base[3:0] = 4'h0;
                    write_16bit(addr_reg, base);
                    write_16bit(wc_reg,   wc);
                end
                // 1/8: random priority
                6: begin
                    bit [23:0] pri = $urandom & 24'hFFFFFF;
                    write_24bit(5'h18, pri);
                end
                // 1/8: periodic master clear
                7: begin
                    mc_counter++;
                    if (mc_counter >= mc_interval) begin
                        mc_counter = 0;
                        send_write(5'h0D, 8'h00);
                    end
                end
            endcase
        end

        send_write(5'h0D, 8'h00);   // final clear
        `uvm_info("RAND_REGRESSION_SEQ", "Random regression complete", UVM_LOW)
    endtask

    task write_16bit(bit [4:0] addr, bit [15:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
    endtask
    task write_24bit(bit [4:0] addr, bit [23:0] data);
        send_write(5'h0C, 8'h00);
        send_write(addr, data[7:0]);
        send_write(addr, data[15:8]);
        send_write(addr, data[23:16]);
    endtask

endclass


//============================================================
// SECTION 12: RAL-BASED RANDOM REGISTER ACCESS
//============================================================
// Uses the RAL model to randomly read/write registers. RAL
// handles byte-pointer sequencing automatically.
//------------------------------------------------------------
class dma_random_reg_seq extends uvm_sequence #(cpu_seq_item);

    rand int unsigned num_ops;
    constraint c_num_ops { num_ops inside {[10:200]}; }

    dma_reg_block reg_model;

    `uvm_object_utils(dma_random_reg_seq)

    function new(string name = "dma_random_reg_seq");
        super.new(name);
        num_ops = 50;
    endfunction

    virtual task body();
        uvm_status_e   status;
        uvm_reg_data_t value;

        // Fetch RAL handle
        if (!uvm_config_db #(dma_reg_block)::get(null,
                get_full_name(), "reg_model", reg_model)) begin
            `uvm_fatal("RAND_REG_SEQ",
                "No reg_model in config_db — RAL access unavailable")
        end

        `uvm_info("RAND_REG_SEQ",
            $sformatf("Starting RAL-based random register access: %0d ops", num_ops),
            UVM_LOW)

        repeat (num_ops) begin
            int reg_choice = $urandom_range(0, 20);
            bit do_read    = ($urandom_range(0, 9) < 3);   // 30% reads

            case (reg_choice)
                0:  do_access(reg_model.base_addr_ch0, do_read, random_16());
                1:  do_access(reg_model.base_wc_ch0,   do_read, random_16());
                2:  do_access(reg_model.base_addr_ch1, do_read, random_16());
                3:  do_access(reg_model.base_wc_ch1,   do_read, random_16());
                4:  do_access(reg_model.base_addr_ch2, do_read, random_16());
                5:  do_access(reg_model.base_wc_ch2,   do_read, random_16());
                6:  do_access(reg_model.base_addr_ch3, do_read, random_16());
                7:  do_access(reg_model.base_wc_ch3,   do_read, random_16());
                8:  do_access(reg_model.command_reg, 1'b0, random_8());  // WO
                9:  do_access(reg_model.request_reg, do_read, random_8());
                10: do_access(reg_model.mask_reg,    do_read, random_8());
                11: do_access(reg_model.mode_reg,    do_read, random_8());
                12: do_access(reg_model.ch_ctrl_reg_0, do_read, random_8());
                13: do_access(reg_model.ch_ctrl_reg_1, do_read, random_8());
                14: do_access(reg_model.ch_ctrl_reg_2, do_read, random_8());
                15: do_access(reg_model.ch_ctrl_reg_3, do_read, random_8());
                16: do_access(reg_model.buf_size_reg_0, do_read, random_16());
                17: do_access(reg_model.buf_size_reg_1, do_read, random_16());
                18: do_access(reg_model.buf_size_reg_2, do_read, random_16());
                19: do_access(reg_model.buf_size_reg_3, do_read, random_16());
                20: do_access(reg_model.priority_ctrl_reg, do_read, random_24());
                default: ;
            endcase
        end

        `uvm_info("RAND_REG_SEQ", "RAL random register access complete", UVM_LOW)
    endtask

    // Dispatch a RAL read or write
    task do_access(uvm_reg reg_h, bit do_read, bit [63:0] value);
        uvm_status_e   status;
        uvm_reg_data_t rd_value;
        string         reg_name = reg_h.get_name();

        if (do_read) begin
            reg_h.read(status, rd_value);
            if (status != UVM_IS_OK)
                `uvm_warning("RAND_REG_SEQ",
                    $sformatf("Read failed on %s", reg_name))
            `uvm_info("RAND_REG_SEQ",
                $sformatf("  R %s = 0x%0h", reg_name, rd_value), UVM_HIGH)
        end else begin
            reg_h.write(status, value);
            if (status != UVM_IS_OK)
                `uvm_warning("RAND_REG_SEQ",
                    $sformatf("Write failed on %s", reg_name))
            `uvm_info("RAND_REG_SEQ",
                $sformatf("  W %s = 0x%0h", reg_name, value), UVM_HIGH)
        end
    endtask

    function bit [63:0] random_8();
        int c = $urandom_range(0, 5);
        case (c)
            0: return 8'h00;
            1: return 8'hFF;
            2: return 8'hAA;
            3: return 8'h55;
            default: return $urandom & 8'hFF;
        endcase
    endfunction
    function bit [63:0] random_16();
        int c = $urandom_range(0, 5);
        case (c)
            0: return 16'h0000;
            1: return 16'hFFFF;
            2: return 16'hAAAA;
            3: return 16'h5555;
            default: return $urandom & 16'hFFFF;
        endcase
    endfunction
    function bit [63:0] random_24();
        int c = $urandom_range(0, 5);
        case (c)
            0: return 24'h000000;
            1: return 24'hFFFFFF;
            2: return 24'hAAAAAA;
            3: return 24'h555555;
            default: return $urandom & 24'hFFFFFF;
        endcase
    endfunction

endclass


//============================================================
// SECTION 13: RANDOM TRANSFER CONFIGURATION (RAL)
//============================================================
// Randomizes channel config (base, WC, buf size, mode, ctrl)
// across all channels via RAL. Exercises full config sweep.
//------------------------------------------------------------
class dma_random_transfer_seq extends uvm_sequence #(cpu_seq_item);

    rand int unsigned num_configs;
    constraint c_num_configs { num_configs inside {[5:50]}; }

    dma_reg_block reg_model;

    `uvm_object_utils(dma_random_transfer_seq)

    function new(string name = "dma_random_transfer_seq");
        super.new(name);
        num_configs = 20;
    endfunction

    virtual task body();
        uvm_status_e status;

        if (!uvm_config_db #(dma_reg_block)::get(null,
                get_full_name(), "reg_model", reg_model)) begin
            `uvm_fatal("RAND_XFER_SEQ",
                "No reg_model in config_db — RAL access unavailable")
        end

        `uvm_info("RAND_XFER_SEQ",
            $sformatf("Starting random transfer config: %0d configs", num_configs),
            UVM_LOW)

        repeat (num_configs) begin
            int unsigned ch       = $urandom_range(0, 3);
            bit [15:0]   base     = $urandom_range(16'h1000, 16'hE000);
            bit [15:0]   wc       = $urandom_range(1, 128);
            bit [15:0]   buf_size = $urandom_range(8, 256);
            bit [1:0]    ttype    = ($urandom_range(0, 1)) ? 2'b01 : 2'b10;
            bit          inc_dec  = $urandom_range(0, 1);
            bit          circ_en  = $urandom_range(0, 1);
            bit          wm_en    = $urandom_range(0, 1);
            bit          buf_en   = $urandom_range(0, 1);
            bit [2:0]    prio_lvl = $urandom_range(0, 7);
            bit [7:0]    mode_val;
            bit [7:0]    ctrl_val;

            base[3:0] = 4'h0;

            mode_val = {2'b01, inc_dec, 1'b0, ttype, ch[1:0]};
            ctrl_val = {circ_en, 1'b0, prio_lvl, wm_en, buf_en, 1'b1};

            case (ch)
                0: begin
                    reg_model.base_addr_ch0.write(status, base);
                    reg_model.base_wc_ch0.write(status, wc);
                    reg_model.buf_size_reg_0.write(status, buf_size);
                    reg_model.ch_ctrl_reg_0.write(status, ctrl_val);
                end
                1: begin
                    reg_model.base_addr_ch1.write(status, base);
                    reg_model.base_wc_ch1.write(status, wc);
                    reg_model.buf_size_reg_1.write(status, buf_size);
                    reg_model.ch_ctrl_reg_1.write(status, ctrl_val);
                end
                2: begin
                    reg_model.base_addr_ch2.write(status, base);
                    reg_model.base_wc_ch2.write(status, wc);
                    reg_model.buf_size_reg_2.write(status, buf_size);
                    reg_model.ch_ctrl_reg_2.write(status, ctrl_val);
                end
                3: begin
                    reg_model.base_addr_ch3.write(status, base);
                    reg_model.base_wc_ch3.write(status, wc);
                    reg_model.buf_size_reg_3.write(status, buf_size);
                    reg_model.ch_ctrl_reg_3.write(status, ctrl_val);
                end
            endcase

            reg_model.mode_reg.write(status, mode_val);
            reg_model.clear_mask.write(status, 8'h00);
            reg_model.command_reg.write(status, 8'h01);

            `uvm_info("RAND_XFER_SEQ",
                $sformatf("  CH%0d: base=0x%04X wc=0x%04X buf=0x%04X mode=0x%02X ctrl=0x%02X",
                          ch, base, wc, buf_size, mode_val, ctrl_val),
                UVM_HIGH)
        end

        `uvm_info("RAND_XFER_SEQ", "Random transfer config complete", UVM_LOW)
    endtask

endclass


//============================================================
// SECTION 14: RANDOM PRIORITY CONFIGURATION (RAL)
//============================================================
// Randomizes the 24-bit PRIORITY_CTRL register and COMMAND.
// Verifies priority_ctrl readback after each write.
//------------------------------------------------------------
class dma_random_priority_seq extends uvm_sequence #(cpu_seq_item);

    rand int unsigned num_configs;
    constraint c_num_configs { num_configs inside {[5:50]}; }

    dma_reg_block reg_model;

    `uvm_object_utils(dma_random_priority_seq)

    function new(string name = "dma_random_priority_seq");
        super.new(name);
        num_configs = 15;
    endfunction

    virtual task body();
        uvm_status_e   status;
        uvm_reg_data_t rd;

        if (!uvm_config_db #(dma_reg_block)::get(null,
                get_full_name(), "reg_model", reg_model)) begin
            `uvm_fatal("RAND_PRIO_SEQ",
                "No reg_model in config_db — RAL access unavailable")
        end

        `uvm_info("RAND_PRIO_SEQ",
            $sformatf("Starting random priority config: %0d configs", num_configs),
            UVM_LOW)

        repeat (num_configs) begin
            bit        adaptive_en   = $urandom_range(0, 1);
            bit [1:0]  arb_mode      = $urandom_range(0, 3);
            bit        aging_en      = $urandom_range(0, 1);
            bit [3:0]  aging_thr     = $urandom_range(0, 15);
            bit [3:0]  w0            = $urandom_range(0, 15);
            bit [3:0]  w1            = $urandom_range(0, 15);
            bit [3:0]  w2            = $urandom_range(0, 15);
            bit [3:0]  w3            = $urandom_range(0, 15);
            bit        priority_type = $urandom_range(0, 1);
            bit [23:0] priority_val;
            bit [7:0]  cmd_val;

            priority_val = {aging_thr, aging_en, arb_mode, adaptive_en,
                            w3, w2, w1, w0};
            cmd_val      = 8'h01 | (priority_type << 4);

            reg_model.priority_ctrl_reg.write(status, priority_val);
            if (status != UVM_IS_OK)
                `uvm_error("RAND_PRIO_SEQ",
                    $sformatf("priority_ctrl write failed (val=0x%06X)", priority_val))

            reg_model.command_reg.write(status, cmd_val);
            if (status != UVM_IS_OK)
                `uvm_error("RAND_PRIO_SEQ",
                    $sformatf("command write failed (val=0x%02X)", cmd_val))

            // Readback + check (independent of scoreboard)
            reg_model.priority_ctrl_reg.read(status, rd);
            if (status == UVM_IS_OK && rd[23:0] !== priority_val)
                `uvm_error("RAND_PRIO_SEQ",
                    $sformatf("priority_ctrl readback mismatch: exp=0x%06X obs=0x%06X",
                              priority_val, rd[23:0]))

            `uvm_info("RAND_PRIO_SEQ",
                $sformatf("  adaptive=%0d arb=%02b aging=%0d thr=%0d w={%0d,%0d,%0d,%0d}",
                          adaptive_en, arb_mode, aging_en, aging_thr, w0, w1, w2, w3),
                UVM_HIGH)
        end

        `uvm_info("RAND_PRIO_SEQ", "Random priority config complete", UVM_LOW)
    endtask

endclass


//============================================================
// SECTION 15: STRESS SEQUENCE (RAL, high volume)
//============================================================
// High-volume stress: random channel/priority configs, status
// reads, buffer-size updates, random register access, and
// periodic MASTER_CLEAR with post-clear verification.
//------------------------------------------------------------
class dma_stress_seq extends uvm_sequence #(cpu_seq_item);

    rand int unsigned num_iterations;
    rand int unsigned mc_interval;
    constraint c_iters { num_iterations inside {[50:1000]}; }
    constraint c_mc    { mc_interval    inside {[20:100]}; }

    dma_reg_block reg_model;

    `uvm_object_utils(dma_stress_seq)

    function new(string name = "dma_stress_seq");
        super.new(name);
        num_iterations = 200;
        mc_interval    = 50;
    endfunction

    virtual task body();
        uvm_status_e   status;
        uvm_reg_data_t rd;
        int            mc_counter = 0;
        int            errors     = 0;

        if (!uvm_config_db #(dma_reg_block)::get(null,
                get_full_name(), "reg_model", reg_model)) begin
            `uvm_fatal("STRESS_SEQ",
                "No reg_model in config_db — RAL access unavailable")
        end

        `uvm_info("STRESS_SEQ",
            $sformatf("Starting stress: %0d iters, MC every ~%0d",
                      num_iterations, mc_interval),
            UVM_LOW)

        repeat (num_iterations) begin
            int op = $urandom_range(0, 9);

            case (op)
                // 3/10: random channel config
                0, 1, 2: configure_channel($urandom_range(0, 3));

                // 2/10: random priority config
                3, 4: randomize_priority();

                // 1/10: status register reads
                5: begin
                    reg_model.status_reg.read(status, rd);
                    reg_model.ext_status_reg.read(status, rd);
                end

                // 1/10: buffer size update
                6: begin
                    int ch = $urandom_range(0, 3);
                    bit [15:0] bs = $urandom_range(8, 256);
                    case (ch)
                        0: reg_model.buf_size_reg_0.write(status, bs);
                        1: reg_model.buf_size_reg_1.write(status, bs);
                        2: reg_model.buf_size_reg_2.write(status, bs);
                        3: reg_model.buf_size_reg_3.write(status, bs);
                    endcase
                end

                // 1/10: random register access
                7: random_register_access($urandom_range(0, 25));

                // 1/10: priority read
                8: reg_model.priority_ctrl_reg.read(status, rd);

                // 1/10: periodic master clear + verify
                9: begin
                    mc_counter++;
                    if (mc_counter >= mc_interval) begin
                        mc_counter = 0;
                        `uvm_info("STRESS_SEQ", "Periodic MASTER_CLEAR", UVM_HIGH)
                        reg_model.master_clear.write(status, 8'h00);
                        #100;

                        reg_model.ext_status_reg.read(status, rd);
                        if (rd[7:0] !== 8'h00) begin
                          `uvm_error("STRESS_SEQ",$sformatf("ext_status not clean after MC: 0x%02X", rd[7:0]))
                            errors++;
                        end
                    end
                end
            endcase
        end

        // Final clean + report
        reg_model.master_clear.write(status, 8'h00);
        #100;

        if (errors == 0)
          `uvm_info("STRESS_SEQ", $sformatf("Stress complete: %0d iters, 0 errors", num_iterations), UVM_LOW)
        else
          `uvm_error("STRESS_SEQ", $sformatf("Stress complete: %0d errors detected", errors))
    endtask

    //--------------------------------------------------------
    // Configure a channel with random parameters via RAL
    //--------------------------------------------------------
    protected task configure_channel(int ch);
        uvm_status_e status;
        bit [15:0] base_addr = $urandom_range(16'h1000, 16'hE000);
        bit [15:0] wc        = $urandom_range(1, 128);
        bit [15:0] buf_size  = $urandom_range(8, 256);
        bit [7:0]  ch_ctrl   = {$urandom_range(0,1),
                                $urandom_range(0,1),
                                $urandom_range(0,7),
                                $urandom_range(0,1),
                                $urandom_range(0,1),
                                1'b1};
        bit [7:0]  mode      = {2'b01, $urandom_range(0,1), 1'b0, 2'b10, ch[1:0]};

        base_addr[3:0] = 4'h0;

        case (ch)
            0: begin
                reg_model.base_addr_ch0.write(status, base_addr);
                reg_model.base_wc_ch0.write(status, wc);
                reg_model.buf_size_reg_0.write(status, buf_size);
                reg_model.ch_ctrl_reg_0.write(status, ch_ctrl);
            end
            1: begin
                reg_model.base_addr_ch1.write(status, base_addr);
                reg_model.base_wc_ch1.write(status, wc);
                reg_model.buf_size_reg_1.write(status, buf_size);
                reg_model.ch_ctrl_reg_1.write(status, ch_ctrl);
            end
            2: begin
                reg_model.base_addr_ch2.write(status, base_addr);
                reg_model.base_wc_ch2.write(status, wc);
                reg_model.buf_size_reg_2.write(status, buf_size);
                reg_model.ch_ctrl_reg_2.write(status, ch_ctrl);
            end
            3: begin
                reg_model.base_addr_ch3.write(status, base_addr);
                reg_model.base_wc_ch3.write(status, wc);
                reg_model.buf_size_reg_3.write(status, buf_size);
                reg_model.ch_ctrl_reg_3.write(status, ch_ctrl);
            end
        endcase

        reg_model.mode_reg.write(status, mode);
        reg_model.command_reg.write(status, 8'h01);
    endtask

    //--------------------------------------------------------
    // Random 24-bit priority value
    //--------------------------------------------------------
    protected task randomize_priority();
        uvm_status_e status;
        bit [23:0] val;
        val = {$urandom_range(0,15), $urandom_range(0,1),
               $urandom_range(0,3),  $urandom_range(0,1),
               $urandom_range(0,15), $urandom_range(0,15),
               $urandom_range(0,15), $urandom_range(0,15)};
        reg_model.priority_ctrl_reg.write(status, val);
    endtask

    //--------------------------------------------------------
    // Random access to any mapped register
    //--------------------------------------------------------
    protected task random_register_access(bit [4:0] addr);
        uvm_status_e   status;
        uvm_reg_data_t value = $urandom;

        case (addr)
            5'h00: reg_model.base_addr_ch0.write(status, value[15:0]);
            5'h01: reg_model.base_wc_ch0.write(status, value[15:0]);
            5'h02: reg_model.base_addr_ch1.write(status, value[15:0]);
            5'h03: reg_model.base_wc_ch1.write(status, value[15:0]);
            5'h04: reg_model.base_addr_ch2.write(status, value[15:0]);
            5'h05: reg_model.base_wc_ch2.write(status, value[15:0]);
            5'h06: reg_model.base_addr_ch3.write(status, value[15:0]);
            5'h07: reg_model.base_wc_ch3.write(status, value[15:0]);
            5'h08: reg_model.command_reg.write(status, value[7:0]);
            5'h09: reg_model.request_reg.write(status, value[7:0]);
            5'h0A: reg_model.mask_reg.write(status, value[7:0]);
            5'h0B: reg_model.mode_reg.write(status, value[7:0]);
            5'h10: reg_model.ch_ctrl_reg_0.write(status, value[7:0]);
            5'h11: reg_model.ch_ctrl_reg_1.write(status, value[7:0]);
            5'h12: reg_model.ch_ctrl_reg_2.write(status, value[7:0]);
            5'h13: reg_model.ch_ctrl_reg_3.write(status, value[7:0]);
            5'h14: reg_model.buf_size_reg_0.write(status, value[15:0]);
            5'h15: reg_model.buf_size_reg_1.write(status, value[15:0]);
            5'h16: reg_model.buf_size_reg_2.write(status, value[15:0]);
            5'h17: reg_model.buf_size_reg_3.write(status, value[15:0]);
            5'h18: reg_model.priority_ctrl_reg.write(status, value[23:0]);
            default: ;
        endcase
    endtask

endclass


//============================================================
// SECTION 16: DMA TRANSFER SEQUENCE
//============================================================
// Drives actual DMA transfers by sending stimulus items to
// the DMA driver (DREQ + HLDA). Runs on the DMA sequencer.
// Assumes channel is already configured.
//------------------------------------------------------------
class dma_transfer_seq extends uvm_sequence #(dma_seq_item);

    `uvm_object_utils(dma_transfer_seq)

    rand bit [1:0]    channel;
    rand int unsigned num_transfers;
    rand bit          circular_en;

    constraint c_channel { channel inside {[0:3]}; }
    constraint c_xfers   { num_transfers inside {[1:20]}; }

    function new(string name = "dma_transfer_seq");
        super.new(name);
        channel       = 2'd0;
        num_transfers = 5;
        circular_en   = 1'b0;
    endfunction

    virtual task body();
        dma_seq_item tx;

      `uvm_info("DMA_XFER_SEQ", $sformatf("Starting %0d transfers on CH%0d (circ=%b)",num_transfers, channel, circular_en),UVM_LOW)

        repeat (num_transfers) begin
            tx = dma_seq_item::type_id::create("tx");
            start_item(tx);
            tx.drive_dma  = 1'b1;
            tx.dreq_drive = (4'b0001 << channel);
            tx.hlda_drive = 1'b1;
            finish_item(tx);
        end

      `uvm_info("DMA_XFER_SEQ", $sformatf("%0d transfers complete on CH%0d", num_transfers, channel), UVM_LOW)
    endtask

endclass

`endif // DMA_SEQUENCE_LIBRARY_SV
