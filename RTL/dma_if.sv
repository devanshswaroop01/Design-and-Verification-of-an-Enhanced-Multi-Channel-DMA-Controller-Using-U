//============================================================
// File        : dma_if.sv
// Description : DMA Top-Level Interface (UVM-ready)
//               Probes all DUT pins + internal regs + status
//============================================================
// INTERVIEW POINT:
//   This is a MONITOR/DRIVER-facing interface. It exposes:
//     - Physical pins (bus, handshake, control)
//     - Internal register mirrors (for scoreboard/coverage)
//     - Decoded command strobes (for protocol checks)
//     - UVM helper signals (XFER_PULSE, byte_pointer, etc.)
//   Clocking blocks / modports are intentionally omitted here
//   (added at agent level in UVM).
//============================================================

`ifndef DMA_IF_SV
`define DMA_IF_SV

interface dma_if
(
    input logic CLK,     // System clock
    input logic RESET    // Active-high async reset
);

    //============================================================
    // SECTION 1: EXTERNAL BUS SIGNALS (physical pins)
    //============================================================
    // NOTE: split address into low [4:0] + upper [3:0]
    //       → lower 5 bits select register (0x00–0x1F),
    //         upper bits used for external memory addressing.
    wire [4:0] ADDR_L;    // Register address bits
    wire [3:0] ADDR_U;    // Upper address bits
    wire [7:0] DB;        // Bidirectional 8-bit data bus
    wire IOR_N;           // I/O Read   (active LOW)
    wire IOW_N;           // I/O Write  (active LOW)
    wire MEMR_N;          // Memory Read (active LOW)
    wire MEMW_N;          // Memory Write(active LOW)

    //============================================================
    // SECTION 2: DMA HANDSHAKE (DUT-driven)
    //============================================================
    logic HRQ;            // Hold Request → CPU
    logic AEN;            // Address Enable (bus ownership)
    logic ADSTB;          // Address Strobe (latch upper addr)
    logic EOP_N;          // End of Process (active LOW)

    //============================================================
    // SECTION 3: SYSTEM CONTROL
    //============================================================
    logic CS_N;           // Chip select (active LOW)   [TB-driven]
    logic HLDA;           // Hold Acknowledge           [TB-driven]
    logic [3:0] DREQ;     // DMA requests per channel   [TB-driven]
    logic [3:0] DACK;     // DMA acknowledges per ch    [DUT-driven]

    //============================================================
    // SECTION 4: INTERNAL REGISTER MIRRORS (base regs)
    //============================================================
    // These are NOT pins — they are RTL hierarchical probes
    // brought out for the UVM scoreboard / functional coverage.
    //------------------------------------------------------------
    logic [7:0] MODE_REG_0, MODE_REG_1, MODE_REG_2, MODE_REG_3;
    logic [7:0] COMMAND_REG, REQUEST_REG, MASK_REG, STATUS_REG;

    logic [15:0] BASE_ADDR_0, BASE_ADDR_1, BASE_ADDR_2, BASE_ADDR_3;
    logic [15:0] CURR_ADDR_0, CURR_ADDR_1, CURR_ADDR_2, CURR_ADDR_3;
    logic [15:0] BASE_WC_0,   BASE_WC_1,   BASE_WC_2,   BASE_WC_3;
    logic [15:0] CURR_WC_0,   CURR_WC_1,   CURR_WC_2,   CURR_WC_3;

    //============================================================
    // SECTION 5: INTERNAL REGISTER MIRRORS (enhanced regs)
    //============================================================
    logic [7:0]  CH_CTRL_REG_0, CH_CTRL_REG_1, CH_CTRL_REG_2, CH_CTRL_REG_3;
    logic [15:0] BUF_SIZE_REG_0, BUF_SIZE_REG_1, BUF_SIZE_REG_2, BUF_SIZE_REG_3;
    logic [23:0] PRIORITY_CTRL_REG;
    logic [7:0]  EXT_STATUS_REG;

    //============================================================
    // SECTION 6: DECODED COMMAND STROBES (base)
    //============================================================
    // One pulse per decoded register access.
    // Used by monitor to check: address decode + direction + ch.
    //------------------------------------------------------------
    logic READ_ANY_REG_CMD;

    logic WRITE_BASE_ADDR_CH0_REG_CMD, WRITE_BASE_ADDR_CH1_REG_CMD,
          WRITE_BASE_ADDR_CH2_REG_CMD, WRITE_BASE_ADDR_CH3_REG_CMD;

    logic WRITE_BASE_WORD_COUNT_CH0_REG_CMD, WRITE_BASE_WORD_COUNT_CH1_REG_CMD,
          WRITE_BASE_WORD_COUNT_CH2_REG_CMD, WRITE_BASE_WORD_COUNT_CH3_REG_CMD;

    logic READ_CURR_ADDR_CH0_REG_CMD, READ_CURR_ADDR_CH1_REG_CMD,
          READ_CURR_ADDR_CH2_REG_CMD, READ_CURR_ADDR_CH3_REG_CMD;

    logic READ_CURR_WORD_COUNT_CH0_REG_CMD, READ_CURR_WORD_COUNT_CH1_REG_CMD,
          READ_CURR_WORD_COUNT_CH2_REG_CMD, READ_CURR_WORD_COUNT_CH3_REG_CMD;

    logic WRITE_COMMAND_REG_CMD,     READ_STATUS_REG_CMD;
    logic WRITE_REQUEST_REG_CMD,     WRITE_MODE_REG_CMD,   READ_MODE_REG_CMD;
    logic CLEAR_BYTE_POINTER_CMD,    SET_BYTE_POINTER_CMD;
    logic MASTER_CLEAR_CMD,          CLEAR_MASK_REG_CMD;
    logic CLEAR_MODE_REG_COUNT_CMD;
    logic WRITE_MASK_REG_CMD,        READ_MASK_REG_CMD;

    //============================================================
    // SECTION 7: DECODED COMMAND STROBES (enhanced)
    //============================================================
    logic WRITE_CH_CTRL_CH0_REG_CMD, WRITE_CH_CTRL_CH1_REG_CMD,
          WRITE_CH_CTRL_CH2_REG_CMD, WRITE_CH_CTRL_CH3_REG_CMD;

    logic WRITE_BUF_SIZE_CH0_REG_CMD, WRITE_BUF_SIZE_CH1_REG_CMD,
          WRITE_BUF_SIZE_CH2_REG_CMD, WRITE_BUF_SIZE_CH3_REG_CMD;

    logic WRITE_PRIORITY_CTRL_REG_CMD;
    logic READ_EXT_STATUS_REG_CMD;

    //============================================================
    // SECTION 8: TRANSFER VISIBILITY (UVM)
    //============================================================
    logic XFER_PULSE;   // 1-cycle pulse per completed transfer

    //============================================================
    // SECTION 9: BYTE-POINTER VISIBILITY
    //============================================================
    // 16-bit regs use 1-bit pointer (low/high byte)
    // 24-bit regs use 2-bit pointer (3 bytes)
    logic [0:0] byte_pointer;       // for 16-bit registers
    logic [1:0] priority_byte_ptr;  // for 24-bit priority reg

    //============================================================
    // SECTION 10: ACTIVE CHANNEL VISIBILITY
    //============================================================
    logic [1:0] active_chnum;   // 0–3 currently serviced
    logic [3:0] active_dack;    // one-hot DACK
    logic       VALID_DACK;     // OR of active_dack
    logic       timeout;        // TC / transfer complete

    //============================================================
    // SECTION 11: CIRCULAR BUFFER VISIBILITY
    //============================================================
    logic [15:0] buffer_used_0, buffer_used_1,
                 buffer_used_2, buffer_used_3;

    logic [3:0]  rollover_status;     // current rollover flags
    logic [3:0]  rollover_latched;    // sticky rollover flags
    logic        watermark_reached;   // watermark hit
    logic        rollover_any;        // OR of rollover_status

endinterface : dma_if

`endif // DMA_IF_SV
