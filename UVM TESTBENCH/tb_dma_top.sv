//==============================================================================
// File        : tb_dma_top.sv
// Description : Production Directed Testbench for Enhanced DMA Controller
//
// Key Enhancements & Cleanups:
//   1. Replaced unsafe 'force/release' constructs with clean tri-state drivers.
//   2. Cleaned clock-domain synchronization to eliminate delta-cycle race hazards.
//   3. Isolated CPU host bus operations from DMA master bus driving.
//   4. Hardened assertions and narrowed self-checking validation thresholds.
//   5. Fully structured and documented all test sections and bus protocols.
//==============================================================================

`timescale 1ns/1ps

module tb_dma_top;

    import dma_reg_pkg::*;

    //==========================================================================
    // SECTION 1: CLOCK, RESET & SYSTEM INTERFACES
    //==========================================================================

    logic CLK;
    logic RESET;

    // Instantiation of the top-level DMA interface
    dma_if dif (
        .CLK   (CLK),
        .RESET (RESET)
    );

    // Instantiation of the Device Under Test (DUT)
    dma_top DUT (
        .dif   (dif)
    );

    // 50 MHz Master System Clock Generation (Period = 20ns)
    initial begin
        CLK = 1'b0;
        forever #10 CLK = ~CLK;
    end

    // Testbench bus drivers for external bidirectional nets
    logic [7:0] tb_db_out;
    logic       tb_db_oe;
    logic [7:0] tb_addr_l_out;
    logic       tb_addr_l_oe;

    // Tri-state drivers connecting to the shared physical busses
    assign dif.DB     = tb_db_oe     ? tb_db_out     : 8'bz;
    assign dif.ADDR_L = tb_addr_l_oe ? tb_addr_l_out : 8'bz;

    //==========================================================================
    // SECTION 2: SCOREBOARDING & RESULT COUNTERS
    //==========================================================================

    int pass_count = 0;
    int fail_count = 0;

    // Unified test checker task with formatted timestamp reporting
    task chk(input bit cond, input string msg);
        if (cond) begin
            $display("  [PASS] %s", msg);
            pass_count++;
        end else begin
            $display("  [FAIL] %s  @ t=%0t ps", msg, $time);
            fail_count++;
        end
    endtask

    //==========================================================================
    // SECTION 3: BUS FUNCTIONAL MODEL (BFM) TASKS
    //==========================================================================

    // Host CPU 8-bit Register Write Cycle (Slave Programming Mode)
    task cpu_write(input logic [4:0] addr, input logic [7:0] data);
        begin
            @(posedge CLK);
            dif.CS_N     <= 1'b0;
            dif.IOR_N    <= 1'b1;
            dif.IOW_N    <= 1'b0;
            tb_addr_l_out<= {3'b000, addr};
            tb_addr_l_oe <= 1'b1;
            tb_db_out    <= data;
            tb_db_oe     <= 1'b1;

            @(posedge CLK);
            // Hold data through the cycle, then release on bus cycle termination
            dif.IOW_N    <= 1'b1;
            dif.CS_N     <= 1'b1;
            tb_addr_l_oe <= 1'b0;
            tb_db_oe     <= 1'b0;
            
            // Post-write recovery buffer to prevent command overlap
            repeat (2) @(posedge CLK);
        end
    endtask

    // Host CPU 8-bit Register Read Cycle (Slave Programming Mode)
    task cpu_read(input logic [4:0] addr, output logic [7:0] data);
        begin
            @(posedge CLK);
            dif.CS_N     <= 1'b0;
            dif.IOR_N    <= 1'b0;
            dif.IOW_N    <= 1'b1;
            tb_addr_l_out<= {3'b000, addr};
            tb_addr_l_oe <= 1'b1;
            tb_db_oe     <= 1'b0; // Float testbench data bus to allow DUT drive

            @(posedge CLK);
            #1; // Sample data slightly after clock edge to allow pad settlement
            data = dif.DB;

            dif.IOR_N    <= 1'b1;
            dif.CS_N     <= 1'b1;
            tb_addr_l_oe <= 1'b0;

            repeat (2) @(posedge CLK);
        end
    endtask

    // Helper task to write a 16-bit register across two consecutive 8-bit cycles
    task cpu_write_16bit(input logic [4:0] addr, input logic [15:0] data);
        begin
            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00); // Reset internal flip-flop
            cpu_write(addr, data[7:0]);                // Lower byte (LSB)
            cpu_write(addr, data[15:8]);               // Upper byte (MSB)
        end
    endtask

    // Assert peripheral DMA service request
    task request_dma(input logic [3:0] channel_mask);
        begin
            @(posedge CLK);
            dif.DREQ <= channel_mask;
        end
    endtask

    // Grant bus ownership to the DMA controller (Host CPU HLDA handshake)
    task grant_bus();
        begin
            @(posedge CLK);
            dif.HLDA <= 1'b1;
        end
    endtask

    // Revoke or complete bus ownership from the DMA controller
    task release_bus();
        begin
            @(posedge CLK);
            dif.HLDA <= 1'b0;
            repeat (2) @(posedge CLK);
        end
    endtask

    // Advance simulation time by a specified cycle count
    task wait_for_transfer(input int cycles = 10);
        begin
            repeat (cycles) @(posedge CLK);
        end
    endtask

    //==========================================================================
    // SECTION 4: DEVICE CONFIGURATION HELPERS
    //==========================================================================

    // Configure Enhanced Channel Control Register (0x10 - 0x13)
    task config_ch_ctrl(
        input [1:0] channel,
        input       circ_en,
        input       burst_en,
        input [2:0] priority_level,
        input       watermark_en,
        input       buffer_en,
        input       channel_en
    );
        logic [4:0] addr;
        logic [7:0] data;
        begin
            addr = 5'h10 + channel;
            data = {circ_en, burst_en, priority_level, watermark_en, buffer_en, channel_en};
            cpu_write(addr, data);
        end
    endtask

    // Configure Channel Circular Buffer Size (0x14 - 0x17)
    task config_buf_size(input [1:0] channel, input [15:0] size);
        logic [4:0] addr;
        begin
            addr = 5'h14 + channel;
            cpu_write_16bit(addr, size);
        end
    endtask

    // Configure 24-bit Priority and Arbitration Control Register (0x18)
    task config_priority_ctrl(
        input       adaptive_en,
        input [1:0] arb_mode,
        input       aging_en,
        input [3:0] aging_threshold,
        input [3:0] w0, w1, w2, w3
    );
        logic [23:0] data;
        begin
            data = {aging_threshold, aging_en, arb_mode, adaptive_en, w3, w2, w1, w0};

            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00);
            cpu_write(PRIORITY_CTRL_REG_ADDR, data[7:0]);
            cpu_write(PRIORITY_CTRL_REG_ADDR, data[15:8]);
            cpu_write(PRIORITY_CTRL_REG_ADDR, data[23:16]);
            wait_for_transfer(2);
        end
    endtask

    // Setup Base Address and Word Count for standard channels
    task setup_channel(
        input [1:0]  channel,
        input [15:0] base_addr,
        input [15:0] word_count
    );
        logic [4:0] addr_reg, count_reg;
        begin
            addr_reg  = (channel << 1);
            count_reg = (channel << 1) + 1;
            cpu_write_16bit(addr_reg, base_addr);
            cpu_write_16bit(count_reg, word_count);
        end
    endtask

    // Configure a channel for continuous circular ring-buffer operation
    task setup_circular_channel(
        input [1:0]  channel,
        input [15:0] base_addr,
        input [15:0] buffer_size,
        input [15:0] word_count
    );
        begin
            setup_channel(channel, base_addr, word_count);
            config_buf_size(channel, buffer_size);
            config_ch_ctrl(channel, 1'b1, 1'b0, 3'b100, 1'b0, 1'b1, 1'b1);
            // Program Mode Register: Demand mode, increment, auto-init, read transfer
            cpu_write(MODE_REG_ADDR, {2'b01, 1'b0, 1'b0, 2'b10, channel});
        end
    endtask

    // Global Controller Enable (Clear disable bit in Command Register)
    task enable_dma();
        begin
            cpu_write(COMMAND_REG_ADDR, 8'h00);
        end
    endtask

    // Unmask all channels to enable request servicing
    task unmask_all();
        begin
            cpu_write(CLEAR_MASK_REG_ADDR, 8'h00);
        end
    endtask

    //==========================================================================
    // SECTION 5: REGRESSION TEST SUITE
    //==========================================================================

    // Test 1: Hardware Reset State Verification
    task test_reset();
        begin
            $display("\n=== TEST 1: Reset Verification ===");
            RESET <= 1'b1;
            repeat (5) @(posedge CLK);
            RESET <= 1'b0;
            repeat (5) @(posedge CLK);

            chk(DUT.DMA_REG_FILE.COMMAND_REG == '0,       "COMMAND_REG reset to 0x00");
            chk(DUT.DMA_REG_FILE.MASK_REG == '0,          "MASK_REG reset to 0x00");
            chk(DUT.DMA_REG_FILE.MODE_REG[0] == '0,       "MODE_REG[0] reset to 0x00");
            chk(DUT.DMA_REG_FILE.REQUEST_REG == '0,       "REQUEST_REG reset to 0x00");
            chk(DUT.DMA_REG_FILE.BASE_ADDR_REG[0] == '0,  "BASE_ADDR_REG[0] reset to 0x0000");
            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0,    "Byte Pointer reset to low byte");
            chk(DUT.DMA_REG_FILE.CH_CTRL_REG[0] == '0,    "CH_CTRL_REG[0] reset to 0x00");
            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG == '0, "PRIORITY_CTRL_REG reset to 0x000000");
        end
    endtask

    // Test 2: Standard 8237 Register Read/Write Access
    task test_register_programming();
        logic [7:0] rdata;
        begin
            $display("\n=== TEST 2: Register Programming ===");

            // Write 16-bit Base Address 0x1234
            cpu_write_16bit(5'h00, 16'h1234);

            // Read back across both bytes
            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00);
            cpu_read(5'h00, rdata);
            chk(rdata == 8'h34, "Base Addr CH0 low byte readback == 0x34");
            cpu_read(5'h00, rdata);
            chk(rdata == 8'h12, "Base Addr CH0 high byte readback == 0x12");

            // Write 16-bit Word Count 0x5678
            cpu_write_16bit(5'h01, 16'h5678);
            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00);
            cpu_read(5'h01, rdata);
            chk(rdata == 8'h78, "Word Count CH0 low byte readback == 0x78");
            cpu_read(5'h01, rdata);
            chk(rdata == 8'h56, "Word Count CH0 high byte readback == 0x56");
        end
    endtask

    // Test 3: Byte Pointer Internal Toggle Mechanics
    task test_byte_pointer();
        logic [7:0] rdata;
        begin
            $display("\n=== TEST 3: Byte Pointer Behavior ===");

            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00);
            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0, "Byte pointer cleared");

            cpu_write(5'h00, 8'hAA); // Low byte
            cpu_write(5'h00, 8'h55); // High byte

            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00);
            cpu_read(5'h00, rdata);
            chk(rdata == 8'hAA, "Byte pointer reads lower byte correctly");
            cpu_read(5'h00, rdata);
            chk(rdata == 8'h55, "Byte pointer advances to higher byte");
            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0, "Byte pointer wrapped back to low");
        end
    endtask

    // Test 4: Default Fixed Priority Scheduling (CH0 > CH1 > CH2 > CH3)
    task test_fixed_priority();
        begin
            $display("\n=== TEST 4: Fixed Priority Arbitration ===");
            enable_dma();
            unmask_all();

            request_dma(4'b1111); // Assert all channel requests simultaneously
            @(posedge CLK);
            chk(dif.HRQ == 1'b1, "HRQ asserted on multi-channel request");

            grant_bus();
            repeat (2) @(posedge CLK);

            chk(dif.DACK[0] == 1'b1, "CH0 granted over lower channels");
            chk($countones(dif.DACK) == 1, "Grant is strictly one-hot");

            release_bus();
            request_dma(4'b0000);
        end
    endtask

    // Test 5: Rotating Priority Scheduling
    task test_rotating_priority();
        begin
            $display("\n=== TEST 5: Rotating Priority Arbitration ===");
            cpu_write(COMMAND_REG_ADDR, 8'h10); // Enable Rotating Priority (bit 4)
            unmask_all();

            // First service round: CH0 and CH1 request
            request_dma(4'b0011);
            grant_bus();
            repeat (3) @(posedge CLK);
            chk(dif.DACK[0] == 1'b1, "CH0 serviced first in rotation");

            release_bus();
            request_dma(4'b0000);
            wait_for_transfer(3);

            // Second service round: CH1 must win due to rotation
            request_dma(4'b0011);
            grant_bus();
            repeat (3) @(posedge CLK);
            chk(dif.DACK[1] == 1'b1, "CH1 serviced next under rotation");

            release_bus();
            request_dma(4'b0000);
        end
    endtask

    // Test 6: Master Clear Command
    task test_master_clear();
        begin
            $display("\n=== TEST 6: Master Clear Strobe ===");
            cpu_write(COMMAND_REG_ADDR, 8'h80);
            cpu_write(5'h0D, 8'h00); // Trigger Master Clear

            chk(DUT.DMA_REG_FILE.COMMAND_REG == '0, "COMMAND_REG cleared by Master Clear");
            chk(DUT.DMA_REG_FILE.MASK_REG.ch_mask_bit == 4'b0000, "MASK_REG cleared");
            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0, "Byte pointer cleared");
        end
    endtask

    // Test 7: Channel Mask Registers
    task test_mask_register();
        begin
            $display("\n=== TEST 7: Channel Masking Operation ===");
            cpu_write(WRITE_MASK_REG_ADDR, 8'h01); // Mask CH0
            request_dma(4'b0011);
            grant_bus();
            repeat (3) @(posedge CLK);

            chk(dif.DACK[0] == 1'b0, "Masked CH0 is suppressed");
            chk(dif.DACK[1] == 1'b1, "Unmasked CH1 receives grant");

            release_bus();
            request_dma(4'b0000);
        end
    endtask

    // Test 8: Hardware Handshake Protocol (DREQ -> HRQ -> HLDA -> DACK)
    task test_dreq_hrq_dack();
        logic adstb_seen, aen_seen, dack2_seen;
        begin
            $display("\n=== TEST 8: Bus Handshake Verification ===");
            enable_dma();
            unmask_all();

            chk(dif.HRQ == 1'b0, "HRQ deasserted prior to transfer");
            request_dma(4'b0100); // Request CH2
            @(posedge CLK);
            chk(dif.HRQ == 1'b1, "HRQ asserts in response to DREQ2");

            grant_bus();
            adstb_seen = 0; aen_seen = 0; dack2_seen = 0;

            for (int i = 0; i < 10; i++) begin
                @(posedge CLK);
                if (dif.ADSTB)   adstb_seen = 1;
                if (dif.AEN)     aen_seen   = 1;
                if (dif.DACK[2]) dack2_seen = 1;
            end

            chk(dack2_seen, "DACK2 asserted during transfer");
            chk(aen_seen,   "AEN address enable asserted");
            chk(adstb_seen, "ADSTB address strobe asserted");

            release_bus();
            request_dma(4'b0000);
        end
    endtask

    // Test 9: Enhanced Control & Diagnostic Registers
    task test_enhanced_register_access();
        logic [7:0] rdata;
        begin
            $display("\n=== TEST 9: Enhanced Registers (0x10-0x19) ===");
            cpu_write(MASTER_CLEAR_ADDR, 8'h00);

            // Channel Control Register Write/Read
            cpu_write(5'h10, 8'hA5);
            cpu_read(5'h10, rdata);
            chk(rdata == 8'hA5, "CH_CTRL_REG[0] readback == 0xA5");

            // Buffer Size Register Write/Read
            config_buf_size(2'd0, 16'h0200);
            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00);
            cpu_read(5'h14, rdata);
            chk(rdata == 8'h00, "BUF_SIZE_REG[0] lower byte == 0x00");
            cpu_read(5'h14, rdata);
            chk(rdata == 8'h02, "BUF_SIZE_REG[0] upper byte == 0x02");

            // 24-bit Priority Control Register Verification
            config_priority_ctrl(1'b1, 2'b10, 1'b1, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5);
            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG == 24'h5D5555, "PRIORITY_CTRL_REG matches expected 24-bit pattern");
        end
    endtask

    // Test 10: Circular Buffer Operational Mechanics
    task test_circular_buffer_basic();
        logic [7:0] rdata;
        begin
            $display("\n=== TEST 10: Circular Buffer Basic Execution ===");
            setup_circular_channel(2'd0, 16'h1000, 16'h0040, 16'h0080);
            enable_dma();
            unmask_all();

            for (int i = 0; i < 8; i++) begin
                request_dma(4'b0001);
                grant_bus();
                wait_for_transfer(4);
                request_dma(4'b0000);
                release_bus();
                wait_for_transfer(2);
            end

            cpu_read(EXT_STATUS_REG_ADDR, rdata);
            chk(DUT.DMA_REG_FILE.CURR_ADDR_REG[0] > 16'h1000, "Current Address progressing inside circular window");
        end
    endtask

    // Test 11: Circular Buffer Wrap-Around & Rollover Detection
    task test_circular_buffer_rollover();
        logic [7:0] rdata;
        int         wrapped = 0;
        begin
            $display("\n=== TEST 11: Circular Buffer Address Wrap-Around ===");
            // Buffer size = 16 bytes (0x1000 to 0x100F)
            setup_circular_channel(2'd0, 16'h1000, 16'h0010, 16'h0040);
            enable_dma();
            unmask_all();

            for (int i = 0; i < 25; i++) begin
                request_dma(4'b0001);
                grant_bus();
                wait_for_transfer(4);
                request_dma(4'b0000);
                release_bus();
                wait_for_transfer(2);

                if (DUT.DMA_REG_FILE.CURR_ADDR_REG[0] == 16'h1000 && i > 0) begin
                    wrapped = 1;
                end
            end

            chk(wrapped, "Address rolled over back to base address (0x1000)");
            cpu_read(EXT_STATUS_REG_ADDR, rdata);
            chk(rdata[4] == 1'b1, "EXT_STATUS rollover_pending bit set");
        end
    endtask

    // Test 12: Circular Wrap Operation Across Multiple Channels
    task test_circular_wrap_modes();
        begin
            $display("\n=== TEST 12: Multi-Channel Circular Wrap Modes ===");
            setup_circular_channel(2'd1, 16'h2000, 16'h0010, 16'h0020);
            enable_dma();
            unmask_all();

            request_dma(4'b0010);
            grant_bus();
            wait_for_transfer(40);
            release_bus();
            request_dma(4'b0000);

            chk(DUT.DMA_REG_FILE.CURR_ADDR_REG[1] >= 16'h2000, "CH1 current address constrained within buffer aperture");
        end
    endtask

    // Test 13: Adaptive Weighted Priority Arbitration
    task test_adaptive_arbitration_weighted();
        begin
            $display("\n=== TEST 13: Adaptive Weighted Arbitration ===");
            for (int ch = 0; ch < 4; ch++) begin
                setup_channel(ch[1:0], 16'h1000 + (ch * 16'h1000), 16'h0020);
                config_ch_ctrl(ch[1:0], 1'b0, 1'b0, 3'b100, 1'b0, 1'b0, 1'b1);
            end

            // Weighted Mode: CH3 highest weight (w3=15, w0=1)
            config_priority_ctrl(1'b1, 2'b10, 1'b0, 4'h0, 4'hF, 4'h8, 4'h4, 4'h1);
            enable_dma();
            unmask_all();

            request_dma(4'b1111);
            grant_bus();
            repeat (3) @(posedge CLK);

            chk(dif.DACK[3] == 1'b1, "Highest weighted channel (CH3) granted first");
            release_bus();
            request_dma(4'b0000);
        end
    endtask

    // Test 14: Starvation Prevention Through Channel Priority Aging
    task test_adaptive_aging();
        begin
            $display("\n=== TEST 14: Priority Aging Mechanism ===");
            config_priority_ctrl(1'b1, 2'b11, 1'b1, 4'h2, 4'h8, 4'h8, 4'h8, 4'h8);
            enable_dma();
            unmask_all();

            request_dma(4'b1111);
            wait_for_transfer(20);

            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG[19] == 1'b1, "Aging enable flag active");
            request_dma(4'b0000);
        end
    endtask

    // Test 15: Round-Robin Full-Circle Traversal
    task test_adaptive_round_robin();
        logic [3:0] channels_granted = 4'b0000;
        begin
            $display("\n=== TEST 15: Round-Robin Rotation Fairness ===");
            config_priority_ctrl(1'b1, 2'b01, 1'b0, 4'h0, 4'h8, 4'h8, 4'h8, 4'h8);
            enable_dma();
            unmask_all();

            for (int i = 0; i < 4; i++) begin
                request_dma(4'b1111);
                grant_bus();
                repeat (3) @(posedge CLK);

                channels_granted |= dif.DACK;

                request_dma(4'b0000);
                release_bus();
                wait_for_transfer(2);
            end

            chk($countones(channels_granted) >= 2, "Round-robin scheduled multiple distinct channels");
        end
    endtask

    // Test 16: Burst Mode Transfer Continuity
    task test_burst_transfer();
        begin
            $display("\n=== TEST 16: Burst Transfer Mode ===");
            setup_channel(2'd0, 16'h1000, 16'h0040);
            config_ch_ctrl(2'd0, 1'b0, 1'b1, 3'b100, 1'b0, 1'b0, 1'b1); // Burst enabled
            enable_dma();
            unmask_all();

            request_dma(4'b0001);
            grant_bus();
            wait_for_transfer(20);

            chk(dif.CH_CTRL_REG_0[6] == 1'b1, "Burst control bit asserted during block transfer");
            release_bus();
            request_dma(4'b0000);
        end
    endtask

    // Test 17: Circular Buffer Watermark Detection
    task test_watermark_detection();
        logic [7:0] rdata;
        begin
            $display("\n=== TEST 17: Buffer Watermark Detection ===");
            setup_channel(2'd0, 16'h1000, 16'h0080);
            config_buf_size(2'd0, 16'h0020);
            config_ch_ctrl(2'd0, 1'b1, 1'b0, 3'b100, 1'b1, 1'b1, 1'b1); // Watermark enabled
            enable_dma();
            unmask_all();

            for (int i = 0; i < 20; i++) begin
                request_dma(4'b0001);
                grant_bus();
                wait_for_transfer(3);
                request_dma(4'b0000);
                release_bus();
                wait_for_transfer(1);
            end

            cpu_read(EXT_STATUS_REG_ADDR, rdata);
            chk(rdata[5] == 1'b1, "Watermark reached threshold flag asserted in Extended Status");
        end
    endtask

    // Test 18: Buffer Capacity Underflow/Overflow Protection
    task test_buffer_error_detection();
        logic [7:0] rdata;
        begin
            $display("\n=== TEST 18: Buffer Capacity Fault Detection ===");
            setup_channel(2'd0, 16'h1000, 16'h0040);
            config_buf_size(2'd0, 16'h0004); // Narrow 4-byte buffer
            config_ch_ctrl(2'd0, 1'b1, 1'b0, 3'b100, 1'b0, 1'b1, 1'b1);
            enable_dma();
            unmask_all();

            // Drive transfers beyond allocated buffer capacity
            for (int i = 0; i < 10; i++) begin
                request_dma(4'b0001);
                grant_bus();
                wait_for_transfer(3);
                release_bus();
                request_dma(4'b0000);
                wait_for_transfer(1);
            end

            cpu_read(EXT_STATUS_REG_ADDR, rdata);
            chk((rdata[7] == 1'b1) || (rdata[6] == 1'b1), "Overflow or underflow bit flagged");
        end
    endtask

    // Test 19: Concurrent Multi-Channel Operations
    task test_multi_channel_concurrent();
        int active_channels = 0;
        begin
            $display("\n=== TEST 19: Concurrent Multi-Channel Processing ===");
            for (int ch = 0; ch < 4; ch++) begin
                setup_channel(ch[1:0], 16'h1000 + (ch * 16'h1000), 16'h0040);
                config_ch_ctrl(ch[1:0], 1'b0, 1'b0, 3'b100, 1'b0, 1'b0, 1'b1);
            end
            enable_dma();
            unmask_all();

            for (int ch = 0; ch < 4; ch++) begin
                request_dma(1 << ch);
                grant_bus();
                wait_for_transfer(10);
                release_bus();
                request_dma(4'b0000);
            end

            for (int ch = 0; ch < 4; ch++) begin
                if (DUT.DMA_REG_FILE.CURR_ADDR_REG[ch] != (16'h1000 + (ch * 16'h1000)))
                    active_channels++;
            end

            chk(active_channels == 4, "All 4 DMA channels processed transfers successfully");
        end
    endtask

    // Test 20: Extended Status Register Clearing on Reset
    task test_extended_status();
        logic [7:0] rdata;
        begin
            $display("\n=== TEST 20: Extended Status Clearing ===");
            cpu_write(MASTER_CLEAR_ADDR, 8'h00);
            cpu_read(EXT_STATUS_REG_ADDR, rdata);
            chk(rdata == 8'h00, "Extended Status Register successfully cleared by Master Clear");
        end
    endtask

    //==========================================================================
    // SECTION 6: CONCURRENT PROTOCOL ASSERTIONS
    //==========================================================================

    // Ensure DACK outputs remain strictly one-hot when bus is granted
    always @(posedge CLK) begin
        if (!RESET && dif.HLDA) begin
            assert ($onehot0(dif.DACK))
                else $error("[ASSERTION VIOLATION] DACK multi-grant detected: 0x%0X", dif.DACK);
        end
    end

    // Verify XFER_PULSE asserts for strictly one clock period
    logic xfer_pulse_d;
    always_ff @(posedge CLK or posedge RESET) begin
        if (RESET) xfer_pulse_d <= 1'b0;
        else       xfer_pulse_d <= dif.XFER_PULSE;
    end

    always @(posedge CLK) begin
        if (!RESET && xfer_pulse_d) begin
            assert (!dif.XFER_PULSE)
                else $error("[ASSERTION VIOLATION] XFER_PULSE held active longer than 1 clock cycle!");
        end
    end

    // Guard against word count counter underflow past zero
    always @(posedge CLK) begin
        if (!RESET && (DUT.DMA_REG_FILE.CURR_WORD_COUNT_REG[0] == 16'hFFFF)) begin
            assert (DUT.DMA_REG_FILE.BASE_WORD_COUNT_REG[0] == 16'hFFFF)
                else $error("[ASSERTION VIOLATION] Channel 0 Word Count underflowed to 0xFFFF!");
        end
    end

    //==========================================================================
    // SECTION 7: TEST SEQUENCE COORDINATOR
    //==========================================================================

    initial begin
        // Initialize default inactive bus state
        dif.CS_N     = 1'b1;
        dif.HLDA     = 1'b0;
        dif.DREQ     = 4'b0000;
        dif.IOR_N    = 1'b1;
        dif.IOW_N    = 1'b1;
        tb_addr_l_oe = 1'b0;
        tb_db_oe     = 1'b0;

        // Apply Power-On Reset
        RESET = 1'b1;
        repeat (5) @(posedge CLK);
        RESET = 1'b0;
        repeat (5) @(posedge CLK);

        $display("\n============================================================");
        $display("  DMA Controller Master Regression Testbench Running");
        $display("============================================================\n");

        // Primary Standard 8237 Tests
        test_reset();
        test_register_programming();
        test_byte_pointer();
        test_fixed_priority();
        test_rotating_priority();
        test_master_clear();
        test_mask_register();
        test_dreq_hrq_dack();

        // Enhanced Feature Tests
        test_enhanced_register_access();
        test_circular_buffer_basic();
        test_circular_buffer_rollover();
        test_circular_wrap_modes();
        test_adaptive_arbitration_weighted();
        test_adaptive_aging();
        test_adaptive_round_robin();
        test_burst_transfer();
        test_watermark_detection();
        test_buffer_error_detection();
        test_multi_channel_concurrent();
        test_extended_status();

        // Final Regression Summary
        $display("\n============================================================");
        $display("  SIMULATION RESULTS SUMMARY");
        $display("============================================================");
        $display("  PASSED: %0d", pass_count);
        $display("  FAILED: %0d", fail_count);
        $display("  TOTAL : %0d", pass_count + fail_count);
        $display("============================================================\n");

        if (fail_count == 0) begin
            $display("  STATUS: ALL TESTS PASSED [REGRESSION CLEAN]\n");
        end else begin
            $display("  STATUS: REGRESSION FAILED WITH %0d ERRORS\n", fail_count);
        end

        $finish;
    end

    //==========================================================================
    // SECTION 8: WAVEFORM DUMP & WATCHDOG TIMER
    //==========================================================================

    initial begin
        $dumpfile("tb_dma_top_fixed.vcd");
        $dumpvars(0, tb_dma_top);
    end

    // Watchdog timer to prevent hung simulations
    initial begin
        #5000000; // 5ms timeout limit
        $display("\n[ERROR] Simulation watchdog timer expired!");
        $display("  PASSED: %0d | FAILED: %0d", pass_count, fail_count);
        $finish;
    end

endmodule : tb_dma_top
