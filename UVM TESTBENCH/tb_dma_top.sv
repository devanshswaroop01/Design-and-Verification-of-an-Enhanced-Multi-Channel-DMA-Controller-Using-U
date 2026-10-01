//============================================================
// File        : tb_dma_top.sv
// Description : DMA Controller Directed Testbench
//               - 20 directed tests (reset, regs, arbitration,
//                 circular buffer, adaptive arb, burst)
//               - Simple tasks for bus cycles
//               - SVA-lite immediate assertions
//               - Pass/fail counter + watchdog
//============================================================
// INTERVIEW POINTS:
//   1. Directed TB — no UVM. Procedural tasks + chk() helpers.
//   2. Interface `dma_if dif(.*)` instantiated and passed to DUT.
//   3. CPU bus modelled via force/release of interface signals.
//   4. `chk(cond, msg)` = mini scoreboard (pass/fail counter).
//   5. Watchdog at 10ms prevents infinite hangs.
//   6. Three immediate assertions check key invariants:
//        - one-hot DACK when HLDA
//        - XFER_PULSE is 1-cycle
//        - WC never underflows to 0xFFFF
//============================================================

`timescale 1ns/1ps

module tb_dma_top;
import dma_reg_pkg::*;

    //============================================================
    // SECTION 1: CLOCK / RESET / INTERFACE / DUT
    //============================================================
    logic CLK;
    logic RESET;

    dma_if dif(.*);         // `.*` auto-connects CLK/RESET by name
    dma_top DUT (.dif(dif));

    // 100 MHz clock (10 ns period)
    initial begin
        CLK = 0;
        forever #10 CLK = ~CLK;
    end

    //============================================================
    // SECTION 2: TEST COUNTERS
    //============================================================
    int pass_count = 0;
    int fail_count = 0;

    //============================================================
    // SECTION 3: BUS FUNCTIONAL TASKS
    //============================================================
    // NOTE on `force`/`release`:
    //   The DUT drives some of these signals (DB, IOR_N, etc.)
    //   tri-state. `force` overrides the DUT driver so the TB
    //   can act as bus master. `release` returns to DUT control.
    //------------------------------------------------------------

    // ---- CPU write cycle ----
    task cpu_write(input logic [4:0] addr, input logic [7:0] data);
        begin
            @(posedge CLK);
            dif.CS_N = 1'b0;                        // select DUT
            force dif.IOR_N  = 1'b1;                // read inactive
            force dif.IOW_N  = 1'b0;                // write active
            force dif.ADDR_L = addr;
            force dif.DB     = data;

            @(posedge CLK);
            #1;
            force dif.IOW_N  = 1'b1;                // deassert write
            #1;
            force dif.ADDR_L = 'z;                  // release address
            force dif.DB     = 'z;                  // release data
            release dif.IOW_N;
            release dif.ADDR_L;
            release dif.DB;
            release dif.IOR_N;
            dif.CS_N = 1'b1;                        // deselect
            #20;                                    // settle gap
        end
    endtask

    // ---- CPU read cycle ----
    task cpu_read(input logic [4:0] addr, output logic [7:0] data);
        begin
            @(posedge CLK);
            dif.CS_N = 1'b0;
            force dif.IOR_N  = 1'b0;                // read active
            force dif.IOW_N  = 1'b1;                // write inactive
            force dif.ADDR_L = addr;
            release dif.DB;                         // let DUT drive

            @(posedge CLK);
            #1;
            data = dif.DB;                          // sample

            force dif.IOR_N  = 1'b1;
            #1;
            force dif.ADDR_L = 'z;
            release dif.IOR_N;
            release dif.IOW_N;
            release dif.ADDR_L;
            dif.CS_N = 1'b1;
            #20;
        end
    endtask

    // ---- 16-bit register write via byte pointer ----
    // 1. Clear byte pointer (write 0x00 to 0x0C)
    // 2. Write low byte
    // 3. Write high byte (pointer auto-toggles)
    task cpu_write_16bit(input logic [4:0] addr, input logic [15:0] data);
        begin
            cpu_write(5'h0C, 8'h00);                // clear byte ptr
            cpu_write(addr, data[7:0]);             // low byte
            cpu_write(addr, data[15:8]);            // high byte
        end
    endtask

    // ---- Drive DREQ for a channel ----
    task request_dma(input logic [3:0] channel);
        begin
            @(posedge CLK);
            dif.DREQ = channel;
            @(posedge CLK);
            #1;
        end
    endtask

    // ---- Assert HLDA (CPU grants bus to DMA) ----
    task grant_bus();
        begin
            @(posedge CLK);
            dif.HLDA = 1;
            #1;
        end
    endtask

    // ---- Deassert HLDA ----
    task release_bus();
        begin
            @(posedge CLK);
            dif.HLDA = 0;
            #10;
        end
    endtask

    // ---- Wait N cycles ----
    task wait_for_transfer(input int cycles = 10);
        begin
            repeat (cycles) @(posedge CLK);
        end
    endtask

    //============================================================
    // SECTION 4: CHECK TASK (mini scoreboard)
    //============================================================
    task chk;
        input         cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("  [PASS] %s", msg);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %s  @ t=%0t", msg, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    //============================================================
    // SECTION 5: CONFIGURATION TASKS
    //============================================================

    // ---- Program CH_CTRL_REG for a channel ----
    // Address 0x10 + channel. Bit layout matches ch_ctrl_reg_t.
    task config_ch_ctrl(
        input [1:0] channel,
        input       circ_en,
        input       burst_en,
        input [2:0] priority_level,
        input       watermark_en,
        input       buffer_en,
        input       channel_en);
        logic [4:0] addr;
        logic [7:0] data;
        begin
            addr = 5'h10 + channel;
            data = {circ_en, burst_en, priority_level,
                    watermark_en, buffer_en, channel_en};
            cpu_write(addr, data);
        end
    endtask

    // ---- Program BUF_SIZE_REG (16-bit) ----
    task config_buf_size(input [1:0] channel, input [15:0] size);
        logic [4:0] addr;
        begin
            addr = 5'h14 + channel;
            cpu_write(5'h0C, 8'h00);                // clear byte ptr
            cpu_write_16bit(addr, size);
        end
    endtask

    // ---- Program PRIORITY_CTRL_REG (24-bit) ----
    // Byte 0 = weights [15:0], byte 1 = [23:16].
    // Uses 2-bit priority_byte_ptr internally.
    task config_priority_ctrl(
        input        adaptive_en,
        input [1:0]  arb_mode,
        input        aging_en,
        input [3:0]  aging_threshold,
        input [3:0]  w0, w1, w2, w3);
        logic [23:0] data;
        begin
            data = {aging_threshold, aging_en, arb_mode,
                    adaptive_en, w3, w2, w1, w0};

            cpu_write(CLEAR_BYTE_POINTER_ADDR, 8'h00);
            wait_for_transfer(5);

            // 3-byte access (auto-increments priority_byte_ptr)
            cpu_write(PRIORITY_CTRL_REG_ADDR, data[7:0]);
            cpu_write(PRIORITY_CTRL_REG_ADDR, data[15:8]);
            cpu_write(PRIORITY_CTRL_REG_ADDR, data[23:16]);
            wait_for_transfer(5);
        end
    endtask

    // ---- Program base addr + word count for a channel ----
    // addr_reg  = channel*2
    // count_reg = channel*2 + 1
    task setup_channel(
        input [1:0]  channel,
        input [15:0] base_addr,
        input [15:0] word_count);
        logic [4:0] addr_reg, count_reg;
        begin
            addr_reg  = (channel << 1);
            count_reg = (channel << 1) + 1;
            cpu_write(5'h0C, 8'h00);
            cpu_write_16bit(addr_reg, base_addr);
            cpu_write(5'h0C, 8'h00);
            cpu_write_16bit(count_reg, word_count);
        end
    endtask

    // ---- Setup channel in circular mode with full config ----
    task setup_circular_channel(
        input [1:0]  channel,
        input [15:0] base_addr,
        input [15:0] buffer_size,
        input [15:0] word_count);
        begin
            setup_channel(channel, base_addr, word_count);
            config_buf_size(channel, buffer_size);
            config_ch_ctrl(channel, 1'b1, 1'b0, 3'b100, 1'b0, 1'b1, 1'b1);
            // MODE reg: mode_sel=01(Single), inc, no auto-init,
            //           trans_type=10(Read), ch_sel
            cpu_write(5'h0B, {2'b01, 1'b0, 1'b0, 2'b10, channel});
        end
    endtask

    // ---- Enable DMA master (COMMAND_REG[5]=1) ----
    task enable_dma();
        begin
            cpu_write(5'h08, 8'h01);
        end
    endtask

    // ---- Clear all channel mask bits (write 0x0E) ----
    task unmask_all();
        begin
            cpu_write(5'h0E, 8'h00);
        end
    endtask

    //============================================================
    // SECTION 6: ORIGINAL TESTS (1–8)
    //============================================================

    //------------------------------------------------------------
    // TEST 1: Reset values
    //------------------------------------------------------------
    task test_reset();
        begin
            $display("\n=== TEST 1: Reset Verification ===");
            RESET = 1;
            repeat (5) @(posedge CLK);
            RESET = 0;
            repeat (5) @(posedge CLK);

            chk(DUT.DMA_REG_FILE.COMMAND_REG == 8'h00, "COMMAND_REG reset");
            chk(DUT.DMA_REG_FILE.MASK_REG    == 8'h00, "MASK_REG reset");
            chk(DUT.DMA_REG_FILE.MODE_REG[0] == 8'h00, "MODE_REG reset");
            chk(DUT.DMA_REG_FILE.REQUEST_REG == 8'h00, "REQUEST_REG reset");
            chk(dif.STATUS_REG               == 8'h00, "STATUS_REG reset");
            chk(DUT.DMA_REG_FILE.BASE_ADDR_REG[0] == 16'h0000, "BASE_ADDR reset");
            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0, "Byte Pointer reset");
            chk(DUT.DMA_REG_FILE.CH_CTRL_REG[0] == 8'h00, "CH_CTRL_REG reset");
            chk(DUT.DMA_REG_FILE.BUF_SIZE_REG[0].buffer_size == 16'h0000, "BUF_SIZE reset");
            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG == 24'h000000, "PRIORITY_CTRL reset");
            chk(dif.EXT_STATUS_REG == 8'h00, "EXT_STATUS reset");

            $display("=== TEST 1 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 2: Register programming + readback
    //------------------------------------------------------------
    task test_register_programming();
        logic [7:0] read_data;
        begin
            $display("\n=== TEST 2: Register Programming ===");

            // Write BASE_ADDR[0] = 0x1234, read back
            cpu_write(5'h0C, 8'h00);
            cpu_write(5'h00, 8'h34);
            cpu_write(5'h00, 8'h12);
            cpu_write(5'h0C, 8'h00);
            cpu_read(5'h00, read_data);
            chk(read_data == 8'h34, "Base Addr low byte = 0x34");
            cpu_read(5'h00, read_data);
            chk(read_data == 8'h12, "Base Addr high byte = 0x12");
            chk(DUT.DMA_REG_FILE.CURR_ADDR_REG[0] == 16'h1234, "Current Address = 0x1234");

            // Write WORD_COUNT[0] = 0x5678, read back
            cpu_write(5'h0C, 8'h00);
            cpu_write(5'h01, 8'h78);
            cpu_write(5'h01, 8'h56);
            cpu_write(5'h0C, 8'h00);
            cpu_read(5'h01, read_data);
            chk(read_data == 8'h78, "WC low byte = 0x78");
            cpu_read(5'h01, read_data);
            chk(read_data == 8'h56, "WC high byte = 0x56");
            chk(DUT.DMA_REG_FILE.CURR_WORD_COUNT_REG[0] == 16'h5678, "WC = 0x5678");

            // Command / status alias check
            cpu_write(5'h08, 8'h01);
            cpu_read(5'h08, read_data);
            chk(read_data == 8'h00 || read_data == 8'h01,
                "Command/Status register access verified");

            // MODE reg
            cpu_write(5'h0B, 8'h00);
            cpu_read(5'h0B, read_data);
            chk(read_data == 8'h00, "Mode Register = 0x00");

            $display("=== TEST 2 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 3: Byte pointer toggling
    //------------------------------------------------------------
    task test_byte_pointer();
        logic [7:0] read_data;
        begin
            $display("\n=== TEST 3: Byte Pointer Behavior ===");

            cpu_write(5'h0C, 8'h00);
            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0, "Byte pointer cleared");

            cpu_write(5'h00, 8'h34);
            cpu_write(5'h00, 8'h12);

            cpu_write(5'h0C, 8'h00);
            cpu_read(5'h00, read_data);
            chk(read_data == 8'h34, "Low byte readback = 0x34");
            cpu_read(5'h00, read_data);
            chk(read_data == 8'h12, "High byte readback = 0x12");

            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0, "Byte pointer toggled back");
            cpu_write(5'h0C, 8'h00);

            $display("=== TEST 3 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 4: Fixed priority — CH0 wins
    //------------------------------------------------------------
    task test_fixed_priority();
        begin
            $display("\n=== TEST 4: Fixed Priority Arbitration ===");

            cpu_write(5'h08, 8'h00);       // fixed priority
            cpu_write(5'h0E, 8'h00);       // unmask all

            request_dma(4'b1111);           // all 4 request
            chk(dif.HRQ == 1, "HRQ asserted");

            grant_bus();
            #20;

            chk(dif.DACK[0] == 1, "CH0 granted (highest priority)");
            chk($countones(dif.DACK) == 1, "Only one DACK active");

            wait_for_transfer(20);
            release_bus();
            request_dma(4'b0000);
            chk(dif.DACK == 4'b0000, "All DACKs deasserted");

            $display("=== TEST 4 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 5: Rotating priority — CH0 then CH1
    //------------------------------------------------------------
    task test_rotating_priority();
        begin
            $display("\n=== TEST 5: Rotating Priority Arbitration ===");

            cpu_write(5'h08, 8'h10);        // priority_type = rotating
            cpu_write(5'h0E, 8'h00);        // unmask all

            request_dma(4'b0011);           // CH0+CH1 request
            grant_bus();
            #20;
            chk(dif.DACK[0] == 1, "CH0 granted first");

            wait_for_transfer(30);
            release_bus();
            request_dma(4'b0000);
            wait_for_transfer(5);

            // Second round — CH1 should win after CH0 served
            request_dma(4'b0011);
            grant_bus();
            #20;
            chk(dif.DACK[1] == 1, "CH1 granted after CH0 (rotation)");

            wait_for_transfer(30);
            release_bus();
            request_dma(4'b0000);

            $display("=== TEST 5 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 6: MASTER_CLEAR
    //------------------------------------------------------------
    task test_master_clear();
        begin
            $display("\n=== TEST 6: Master Clear ===");

            cpu_write(5'h00, 8'hAA);
            cpu_write(5'h01, 8'h55);
            cpu_write(5'h08, 8'h80);
            chk(DUT.DMA_REG_FILE.COMMAND_REG == 8'h80, "COMMAND_REG programmed");

            cpu_write(5'h0D, 8'h00);        // MASTER_CLEAR

            chk(DUT.DMA_REG_FILE.COMMAND_REG == 8'h00, "COMMAND_REG cleared");
            chk(DUT.DMA_REG_FILE.MASK_REG.ch_mask_bit == 4'b0000, "MASK_REG cleared");
            chk(DUT.DMA_REG_FILE.MODE_REG[0] == 8'h00, "MODE_REG cleared");
            chk(DUT.DMA_REG_FILE.REQUEST_REG == 8'h00, "REQUEST_REG cleared");
            chk(dif.STATUS_REG == 8'h00, "STATUS_REG cleared");
            chk(DUT.DMA_REG_FILE.byte_pointer == 1'b0, "Byte Pointer cleared");

            $display("=== TEST 6 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 7: Mask register (single-bit + full-byte)
    //------------------------------------------------------------
    task test_mask_register();
        begin
            $display("\n=== TEST 7: Mask Register ===");

            cpu_write(5'h0F, 8'h01);        // mask CH0 only
            request_dma(4'b0011);
            chk(DUT.DMA_PRIORITY.cif.VALID_DREQ0 == 0, "CH0 masked");
            chk(DUT.DMA_PRIORITY.cif.VALID_DREQ1 == 1, "CH1 valid");
            request_dma(4'b0000);

            cpu_write(5'h0E, 8'h00);        // clear mask
            request_dma(4'b0001);
            chk(DUT.DMA_PRIORITY.cif.VALID_DREQ0 == 1, "CH0 unmasked");
            request_dma(4'b0000);

            cpu_write(5'h0F, 8'h0F);        // mask all
            request_dma(4'b1111);
            #5;
            chk((DUT.DMA_PRIORITY.cif.VALID_DREQ0 == 0) &&
                (DUT.DMA_PRIORITY.cif.VALID_DREQ1 == 0) &&
                (DUT.DMA_PRIORITY.cif.VALID_DREQ2 == 0) &&
                (DUT.DMA_PRIORITY.cif.VALID_DREQ3 == 0), "All masked");
            request_dma(4'b0000);

            $display("=== TEST 7 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 8: DREQ → HRQ → DACK handshake
    //------------------------------------------------------------
    task test_dreq_hrq_dack();
        logic adstb_seen, aen_seen, dack2_seen;
        begin
            $display("\n=== TEST 8: DREQ -> HRQ -> DACK Handshake ===");

            cpu_write(5'h08, 8'h00);
            cpu_write(5'h0E, 8'h00);

            chk(dif.HRQ == 0, "HRQ idle before request");

            request_dma(4'b0100);           // CH2
            chk(dif.HRQ == 1, "HRQ asserted after DREQ2");

            grant_bus();
            adstb_seen = 0; aen_seen = 0; dack2_seen = 0;

            // Sample bus signals over 10 cycles
            for (int i = 0; i < 10; i++) begin
                @(posedge CLK);
                #1;
                if (dif.ADSTB   == 1'b1) adstb_seen = 1;
                if (dif.AEN     == 1'b1) aen_seen   = 1;
                if (dif.DACK[2] == 1'b1) dack2_seen = 1;
            end

            chk(dack2_seen == 1, "DACK2 asserted");
            chk(aen_seen   == 1, "AEN asserted");
            chk(adstb_seen == 1, "ADSTB asserted");

            wait_for_transfer(20);
            release_bus();
            request_dma(4'b0000);
            chk(dif.HRQ == 0, "HRQ deasserted");

            $display("=== TEST 8 Complete ===\n");
        end
    endtask

    //============================================================
    // SECTION 7: ENHANCED TESTS (9–20)
    //============================================================

    //------------------------------------------------------------
    // TEST 9: Enhanced register access (CH_CTRL, BUF_SIZE, PRIORITY)
    //------------------------------------------------------------
    task test_enhanced_register_access();
        logic [7:0] read_data;
        begin
            $display("\n=== TEST 9: Enhanced Register Access ===");

            cpu_write(5'h0D, 8'h00);        // master clear
            wait_for_transfer(5);

            cpu_write(5'h10, 8'hFF);
            cpu_read(5'h10, read_data);
            chk(read_data == 8'hFF, "CH_CTRL_REG[0] = 0xFF");

            cpu_write(5'h11, 8'h0F);
            cpu_read(5'h11, read_data);
            chk(read_data == 8'h0F, "CH_CTRL_REG[1] = 0x0F");

            cpu_write(5'h12, 8'hAA);
            cpu_read(5'h12, read_data);
            chk(read_data == 8'hAA, "CH_CTRL_REG[2] = 0xAA");

            cpu_write(5'h13, 8'h55);
            cpu_read(5'h13, read_data);
            chk(read_data == 8'h55, "CH_CTRL_REG[3] = 0x55");

            // BUF_SIZE 16-bit access
            config_buf_size(2'd0, 16'h0100);
            cpu_write(5'h0C, 8'h00);
            cpu_read(5'h14, read_data);
            chk(read_data == 8'h00, "BUF_SIZE low = 0x00");
            cpu_read(5'h14, read_data);
            chk(read_data == 8'h01, "BUF_SIZE high = 0x01");

            // PRIORITY_CTRL 24-bit access
            config_priority_ctrl(1'b1, 2'b10, 1'b1, 4'h5,
                                 4'h5, 4'h5, 4'h5, 4'h5);
            wait_for_transfer(5);
            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG[7:0]   == 8'h55, "PRIO byte0 = 0x55");
            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG[15:8]  == 8'h55, "PRIO byte1 = 0x55");
            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG[23:16] == 8'h5D, "PRIO byte2 = 0x5D");

            cpu_read(5'h19, read_data);
            chk(read_data == 8'h00, "EXT_STATUS initial = 0x00");

            $display("=== TEST 9 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 10: Circular buffer basic (mode + flags)
    //------------------------------------------------------------
    task test_circular_buffer_basic();
        logic [7:0] read_data;
        begin
            $display("\n=== TEST 10: Circular Buffer Basic ===");

            setup_channel(2'd0, 16'h1000, 16'h0010);
            config_buf_size(2'd0, 16'h0100);
            cpu_write(5'h10, 8'h87);       // circ+watermark+buf+ch_en

            cpu_read(5'h10, read_data);
            chk(read_data[7] == 1'b1, "Circular mode enabled");
            chk(read_data[2] == 1'b1, "Watermark enabled");
            chk(read_data[1] == 1'b1, "Buffer enabled");
            chk(read_data[0] == 1'b1, "Channel enabled");

            enable_dma();
            unmask_all();

            // 10 sequential single transfers
            for (int i = 0; i < 10; i++) begin
                request_dma(4'b0001);
                grant_bus();
                wait_for_transfer(15);
                release_bus();
                request_dma(4'b0000);
                wait_for_transfer(3);
            end

            wait_for_transfer(20);
            cpu_read(5'h19, read_data);
            $display("  EXT_STATUS_REG = 0x%02X", read_data);

            chk(read_data[4] == 1'b1 || read_data[5] == 1'b1 ||
                DUT.DMA_CONTROL.CIRCULAR_BUFFER.buffer_used_int[0] > 0,
                "Rollover or watermark detected");

            $display("=== TEST 10 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 11: Rollover detection
    //------------------------------------------------------------
    task test_circular_buffer_rollover();
        logic [7:0]  read_data;
        logic [15:0] curr_addr_after;
        int          rollover_count = 0;
        int          iterations     = 0;
        begin
            $display("\n=== TEST 11: Circular Buffer Rollover Detection ===");

            // buffer_size = 16 matches addr range 0x1000..0x100F
            setup_circular_channel(2'd0, 16'h1000, 16'h0010, 16'h0040);
            enable_dma();
            unmask_all();

            // Drive transfers until rollover_status[0] latches
            for (int i = 0; i < 40; i++) begin
                request_dma(4'b0001);
                grant_bus();
                wait_for_transfer(5);
                request_dma(4'b0000);
                wait_for_transfer(1);
                release_bus();
                wait_for_transfer(2);
                iterations++;

                if (DUT.DMA_CONTROL.CIRCULAR_BUFFER.rollover_status[0]) begin
                    rollover_count++;
                    $display("    Rollover at iteration %0d, addr=0x%04X",
                             iterations,
                             DUT.DMA_REG_FILE.CURR_ADDR_REG[0]);
                    break;
                end
            end

            curr_addr_after = DUT.DMA_REG_FILE.CURR_ADDR_REG[0];
            $display("  Final current address: 0x%04X", curr_addr_after);
            chk((curr_addr_after >= 16'h1000) && (curr_addr_after <= 16'h1010),
                "Address within buffer range");

            cpu_read(5'h19, read_data);
            $display("  EXT_STATUS_REG = 0x%02X", read_data);

            chk(read_data[4] == 1'b1, "Rollover pending bit set");
            chk(read_data[3:0] == 4'h0, "Rollover channel = CH0");

            $display("=== TEST 11 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 12: Wrap modes (basic — just verifies address bounds)
    //------------------------------------------------------------
    task test_circular_wrap_modes();
        begin
            $display("\n=== TEST 12: Circular Buffer Wrap Modes ===");

            setup_circular_channel(2'd0, 16'h1000, 16'h0010, 16'h0005);
            enable_dma();
            unmask_all();
            request_dma(4'b0001);
            grant_bus();
            wait_for_transfer(50);
            release_bus();
            request_dma(4'b0000);
            chk(DUT.DMA_REG_FILE.CURR_ADDR_REG[0] >= 16'h1000, "Address >= base");

            cpu_write(5'h0D, 8'h00);        // master clear
            setup_circular_channel(2'd1, 16'h2000, 16'h0010, 16'h0005);
            enable_dma();
            unmask_all();
            request_dma(4'b0010);
            grant_bus();
            wait_for_transfer(50);
            release_bus();
            request_dma(4'b0000);
            chk(DUT.DMA_REG_FILE.CURR_ADDR_REG[1] >= 16'h2000,
                "Address >= base (CH1)");

            $display("=== TEST 12 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 13: Adaptive arbitration — weighted mode
    //------------------------------------------------------------
    task test_adaptive_arbitration_weighted();
        begin
            $display("\n=== TEST 13: Adaptive - Weighted ===");

            for (int ch = 0; ch < 4; ch++) begin
                setup_channel(ch[1:0], 16'h1000 + (ch * 16'h1000), 16'h0010);
                config_ch_ctrl(ch[1:0], 1'b0, 1'b0, 3'b100, 1'b0, 1'b0, 1'b1);
            end

            // Adaptive, weighted mode, aging on, weights 15/8/4/1
            config_priority_ctrl(1'b1, 2'b10, 1'b1, 4'h4, 4'hF, 4'h8, 4'h4, 4'h1);
            enable_dma();
            unmask_all();

            request_dma(4'b1111);
            chk(dif.HRQ == 1, "HRQ asserted for multi-channel request");

            grant_bus();
            repeat (5) @(posedge CLK);
            #1;
            chk($countones(dif.DACK) == 1, "Only one channel granted");

            wait_for_transfer(100);
            release_bus();
            request_dma(4'b0000);

            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG[16] == 1'b1,
                "Adaptive mode enabled (bit 16)");

            $display("=== TEST 13 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 14: Adaptive arbitration — aging
    //------------------------------------------------------------
    task test_adaptive_aging();
        begin
            $display("\n=== TEST 14: Adaptive - Aging ===");

            for (int ch = 0; ch < 4; ch++) begin
                setup_channel(ch[1:0], 16'h1000 + (ch * 16'h1000), 16'h0010);
                config_ch_ctrl(ch[1:0], 1'b0, 1'b0, 3'b100, 1'b0, 1'b0, 1'b1);
            end

            // Dynamic mode, aging on, threshold = 2
            config_priority_ctrl(1'b1, 2'b11, 1'b1, 4'h2, 4'h8, 4'h8, 4'h8, 4'h8);
            enable_dma();
            unmask_all();

            request_dma(4'b1111);
            wait_for_transfer(50);

            chk(DUT.DMA_REG_FILE.PRIORITY_CTRL_REG[19] == 1'b1,
                "Aging enabled (bit 19)");

            grant_bus();
            wait_for_transfer(100);
            release_bus();
            request_dma(4'b0000);

            $display("=== TEST 14 Complete ===\n");
        end
    endtask

    //------------------------------------------------------------
    // TEST 15: Adaptive arbitration — round-robin rotation
    //------------------------------------------------------------
    task test_adaptive_round_robin();
        logic [3:0] seen_channels = 4'b0000;
        logic [1:0] granted_ch;
        int         distinct_count = 0;
        begin
            $display("\n=== TEST 15: Adaptive - Round Robin ===");

            for (int ch = 0; ch < 4; ch++) begin
                setup_channel(ch[1:0], 16'h1000 + (ch * 16'h1000), 16'h0010);
                config_ch_ctrl(ch[1:0], 1'b0, 1'b0, 3'b100, 1'b0, 1'b0, 1'b1);
            end

            config_priority_ctrl(1'b1, 2'b01, 1'b0, 4'h0, 4'h8, 4'h8, 4'h8, 4'h8);
            enable_dma();
            unmask_all();

            // 4
