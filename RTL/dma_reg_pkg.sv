//============================================================
// File        : dma_reg_pkg.sv
// Description : DMA Controller Register Package
//               (8237-compatible base + enhanced features)
//============================================================
// KEY INTERVIEW POINTS (memorize these):
//   1. Address bus is 5-bit [4:0] → covers 0x00–0x1F (32 regs)
//   2. Data bus is 8-bit  → all regs accessed byte-wise
//   3. 4 channels (0–3), each with base addr + word count
//   4. Several addresses are ALIASED (write vs read differ)
//   5. Packed struct → FIRST member = MSB
//============================================================

package dma_reg_pkg;

    //============================================================
    // SYSTEM PARAMETERS
    //============================================================
    parameter int ADDRESS_WIDTH = 16;   // DMA address bus (not reg addr)
    parameter int DATA_WIDTH    = 8;    // Byte-wide transfers
    parameter int NUM_CHANNELS  = 4;    // Channels 0–3

    //============================================================
    // REGISTER ADDRESS MAP — BASE (8237-compatible, 0x00–0x0F)
    //============================================================
    // NOTE: All addresses are 5-bit to represent 0x10–0x1F too.
    //       (4-bit would truncate 0x10 → 0x0. Classic bug.)

    //---------- Per-channel base address + word count ----------
    // Pattern: even addr = base addr, odd addr = word count
    parameter logic [4:0] BASE_ADDR_REG_CH0_ADDR       = 5'h00;
    parameter logic [4:0] BASE_WORD_COUNT_REG_CH0_ADDR = 5'h01;
    parameter logic [4:0] BASE_ADDR_REG_CH1_ADDR       = 5'h02;
    parameter logic [4:0] BASE_WORD_COUNT_REG_CH1_ADDR = 5'h03;
    parameter logic [4:0] BASE_ADDR_REG_CH2_ADDR       = 5'h04;
    parameter logic [4:0] BASE_WORD_COUNT_REG_CH2_ADDR = 5'h05;
    parameter logic [4:0] BASE_ADDR_REG_CH3_ADDR       = 5'h06;
    parameter logic [4:0] BASE_WORD_COUNT_REG_CH3_ADDR = 5'h07;

    //---------- Control / Status ----------
    // 0x08 ALIASED: WRITE = COMMAND, READ = STATUS
    parameter logic [4:0] COMMAND_REG_ADDR   = 5'h08;
    parameter logic [4:0] STATUS_REG_ADDR    = 5'h08;

    parameter logic [4:0] REQUEST_REG_ADDR   = 5'h09; // SW DMA request
    parameter logic [4:0] MASK_REG_ADDR      = 5'h0A; // single-bit mask
    parameter logic [4:0] MODE_REG_ADDR      = 5'h0B; // per-channel mode

    // 0x0C ALIASED: WRITE = CLEAR byte ptr, READ = SET byte ptr
    // (8237 quirk: reading this reg sets the byte-pointer flip-flop)
    parameter logic [4:0] CLEAR_BYTE_POINTER_ADDR = 5'h0C;
    parameter logic [4:0] SET_BYTE_POINTER_ADDR   = 5'h0C;

    parameter logic [4:0] MASTER_CLEAR_ADDR   = 5'h0D; // global reset
    parameter logic [4:0] CLEAR_MASK_REG_ADDR = 5'h0E; // clear all masks

    // 0x0F ALIASED: WRITE = WRITE_MASK, READ = READ_MASK
    parameter logic [4:0] WRITE_MASK_REG_ADDR = 5'h0F;
    parameter logic [4:0] READ_MASK_REG_ADDR  = 5'h0F;

    //============================================================
    // REGISTER ADDRESS MAP — ENHANCED (0x10–0x19)
    //============================================================

    //---------- Channel control (per-channel) ----------
    parameter logic [4:0] CH_CTRL_REG_CH0_ADDR = 5'h10;
    parameter logic [4:0] CH_CTRL_REG_CH1_ADDR = 5'h11;
    parameter logic [4:0] CH_CTRL_REG_CH2_ADDR = 5'h12;
    parameter logic [4:0] CH_CTRL_REG_CH3_ADDR = 5'h13;

    //---------- Circular buffer size (16-bit each) ----------
    // Accessed via byte_pointer (low byte / high byte)
    parameter logic [4:0] BUF_SIZE_REG_CH0_ADDR = 5'h14;
    parameter logic [4:0] BUF_SIZE_REG_CH1_ADDR = 5'h15;
    parameter logic [4:0] BUF_SIZE_REG_CH2_ADDR = 5'h16;
    parameter logic [4:0] BUF_SIZE_REG_CH3_ADDR = 5'h17;

    //---------- Priority control (24-bit, 3-byte access) ----------
    parameter logic [4:0] PRIORITY_CTRL_REG_ADDR = 5'h18;

    //---------- Extended status (read-only) ----------
    parameter logic [4:0] EXT_STATUS_REG_ADDR    = 5'h19;

    //============================================================
    // STRUCT DEFINITIONS — BASE REGISTERS
    //============================================================
    // RULE: In `packed` struct, the FIRST declared field = MSB.
    //       Always declare MSB-first to match bit maps.

    //------------------------------------------------------------
    // MODE REGISTER (0x0B, Write-Only, one channel at a time)
    //------------------------------------------------------------
    // [7:6] mode_sel    : 00=Demand 01=Single 10=Block 11=Cascade
    // [5]   addr_inc_dec: 0=Increment 1=Decrement
    // [4]   auto_init_en: 1=auto-reload after TC
    // [3:2] trans_type  : 00=Verify 01=Write 10=Read 11=Illegal
    // [1:0] ch_sel      : which channel this write applies to
    //------------------------------------------------------------
    typedef struct packed {
        logic [1:0] mode_sel;
        logic       addr_inc_dec;
        logic       auto_init_en;
        logic [1:0] trans_type;
        logic [1:0] ch_sel;
    } mode_reg_t;

    //------------------------------------------------------------
    // COMMAND REGISTER (0x08, Write-Only) — global control
    //------------------------------------------------------------
    typedef struct packed {
        logic dack_sense;      // DACK polarity
        logic dreq_sense;      // DREQ polarity
        logic late_ext_wr_sel; // Late vs Extended write timing
        logic priority_type;   // 0=Fixed, 1=Rotating priority
        logic timing_type;     // Normal vs Extended timing
        logic dma_en;          // Master DMA enable
        logic ch0_addr_hold;   // Ch0 address hold enable
        logic mem2mem_en;      // Memory-to-Memory mode
    } cmd_reg_t;

    //------------------------------------------------------------
    // REQUEST REGISTER (0x09, Write-Only)
    //   [7:4] reserved (must be 0)
    //   [3:0] ch_request — software DMA request per channel
    //------------------------------------------------------------
    typedef struct packed {
        logic [3:0] reserved;
        logic [3:0] ch_request;
    } req_reg_t;

    //------------------------------------------------------------
    // MASK REGISTER (0x0A / 0x0F, Write-Only)
    //   [7:4] reserved
    //   [3:0] ch_mask_bit — 1 = masked (disabled)
    //------------------------------------------------------------
    typedef struct packed {
        logic [3:0] reserved;
        logic [3:0] ch_mask_bit;
    } mask_reg_t;

    //------------------------------------------------------------
    // STATUS REGISTER (0x08, Read-Only)
    //   [7:4] ch_timeout — Terminal Count reached per channel
    //   [3:0] ch_request — Request pending per channel
    //------------------------------------------------------------
    typedef struct packed {
        logic [3:0] ch_timeout;  // MSB half
        logic [3:0] ch_request;  // LSB half
    } status_reg_t;

    //============================================================
    // STRUCT DEFINITIONS — ENHANCED REGISTERS
    //============================================================

    //------------------------------------------------------------
    // CHANNEL CONTROL REGISTER (0x10–0x13, per-channel)
    //------------------------------------------------------------
    // [7]   circ_en       : circular buffer enable
    // [6]   burst_en      : burst transfer enable
    // [5:3] priority_level: 0–7
    // [2]   watermark_en  : watermark detection
    // [1]   buffer_en     : buffer enable
    // [0]   channel_en    : channel enable
    //------------------------------------------------------------
    typedef struct packed {
        logic       circ_en;
        logic       burst_en;
        logic [2:0] priority_level;
        logic       watermark_en;
        logic       buffer_en;
        logic       channel_en;
    } ch_ctrl_reg_t;

    //------------------------------------------------------------
    // BUFFER SIZE REGISTER (0x14–0x17)
    //   Circular buffer size in bytes (16-bit)
    //------------------------------------------------------------
    typedef struct packed {
        logic [15:0] buffer_size;
    } buf_size_reg_t;

    //------------------------------------------------------------
    // PRIORITY CONTROL REGISTER (0x18, 24-bit)
    //------------------------------------------------------------
    // [23:20] aging_threshold
    // [19]    aging_en
    // [18:17] arb_mode : 00=Fixed 01=Round-Robin 10=Weighted 11=Dynamic
    // [16]    adaptive_en
    // [15:12] weight_ch3
    // [11:8]  weight_ch2
    // [7:4]   weight_ch1
    // [3:0]   weight_ch0
    //------------------------------------------------------------
    typedef struct packed {
        logic [3:0] aging_threshold; // [23:20]
        logic       aging_en;        // [19]
        logic [1:0] arb_mode;        // [18:17]
        logic       adaptive_en;     // [16]
        logic [3:0] weight_ch3;      // [15:12]
        logic [3:0] weight_ch2;      // [11:8]
        logic [3:0] weight_ch1;      // [7:4]
        logic [3:0] weight_ch0;      // [3:0]
    } priority_ctrl_reg_t;

    //------------------------------------------------------------
    // EXTENDED STATUS REGISTER (0x19, Read-Only)
    //------------------------------------------------------------
    // [7]   overflow_error
    // [6]   underflow_error
    // [5]   watermark_reached
    // [4]   rollover_pending
    // [3:0] rollover_channel
    //------------------------------------------------------------
    // FIX NOTE: Earlier buggy version had rollover_channel at
    // [7:4] and overflow_error at [0]. Corrected to MSB-first
    // declaration order so it matches the spec above.
    //------------------------------------------------------------
    typedef struct packed {
        logic       overflow_error;    // [7]
        logic       underflow_error;   // [6]
        logic       watermark_reached; // [5]
        logic       rollover_pending;  // [4]
        logic [3:0] rollover_channel;  // [3:0]
    } ext_status_reg_t;

endpackage : dma_reg_pkg
