//============================================================
// File        : dma_control_if.sv
// Description : Internal control interface between DMA
//               sub-blocks (control FSM ↔ datapath).
//============================================================
// INTERVIEW POINT:
//   - Signals here are active-HIGH internally (ior, iow,
//     memr, memw). Polarity inversion happens at the top
//     level (pins are active-LOW: IOR_N etc.).
//   - VALID_DREQx are *qualified* requests (after mask +
//     mode check), not raw DREQ pins.
//   - ldTemp* / ldCurr* are datapath load enables for the
//     two-stage address/word-count update pipeline.
//============================================================

interface dma_control_if(
    input logic CLK,
    input logic RESET
);

    //============================================================
    // SECTION 1: TRANSFER CONTROL (internal, active HIGH)
    //============================================================
    logic eop;     // End of Process
    logic aen;     // Address Enable
    logic adstb;   // Address Strobe
    logic ior;     // I/O Read
    logic iow;     // I/O Write
    logic memr;    // Memory Read
    logic memw;    // Memory Write

    //============================================================
    // SECTION 2: BUS HANDSHAKE
    //============================================================
    logic hrq;          // Hold Request to CPU
    logic VALID_DACK;   // Any valid DACK

    //============================================================
    // SECTION 3: CHANNEL CONTROL
    //============================================================
    logic VALID_DREQ0, VALID_DREQ1, VALID_DREQ2, VALID_DREQ3;
    logic [3:0] active_dack;    // one-hot
    logic [1:0] active_chnum;   // 0–3

    //============================================================
    // SECTION 4: TIMING / STATUS
    //============================================================
    logic timeout;        // TC reached
    logic en_addr_out;    // Enable address output driver

    //============================================================
    // SECTION 5: DATAPATH LOAD ENABLES
    //============================================================
    // Two-stage update: temp regs capture new values, then
    // committed to current regs on next cycle.
    logic ldCurrAddrTemp;   // load curr addr → temp
    logic ldCurrWordTemp;   // load curr word → temp
    logic ldTempCurrAddr;   // commit temp → curr addr
    logic ldTempCurrWord;   // commit temp → curr word

endinterface : dma_control_if
