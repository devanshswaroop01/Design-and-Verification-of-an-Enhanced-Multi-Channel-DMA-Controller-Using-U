//============================================================
// File        : dma_sw_commands.sv
// Description : DMA Software Command Decoder (combinational)
//               Decodes CPU register accesses into one-hot
//               command strobes.
//============================================================
// INTERVIEW POINTS:
//   1. This is a PURE combinational decoder — no state.
//   2. It uses the interface (dma_if dif) directly — no ports.
//   3. All outputs default to 0 → prevents latches.
//   4. Access is valid ONLY when: CS_N=0 AND HLDA=0.
//      (HLDA=1 means CPU has given bus to DMA — no sw access.)
//   5. Write cycle: IOW_N=0 AND IOR_N=1.
//      Read  cycle: IOW_N=1 AND IOR_N=0.
//   6. ALIASED addresses (0x08, 0x0C, 0x0F) are decoded by
//      direction — same address, different strobe for R vs W.
//============================================================

module dma_sw_commands (
    dma_if dif   // Virtual-interface style port (SV interface)
);

import dma_reg_pkg::*;   // Bring in address parameters

    always_comb begin

        //============================================================
        // DEFAULT ASSIGNMENTS
        //============================================================
        // RULE: In always_comb, always default all outputs to 0
        //       first → guarantees no inferred latches and makes
        //       the case statement a "one-hot pulse generator".
        //------------------------------------------------------------
        dif.READ_ANY_REG_CMD = 1'b0;

        // Base address regs (per channel)
        dif.WRITE_BASE_ADDR_CH0_REG_CMD = 1'b0;
        dif.WRITE_BASE_ADDR_CH1_REG_CMD = 1'b0;
        dif.WRITE_BASE_ADDR_CH2_REG_CMD = 1'b0;
        dif.WRITE_BASE_ADDR_CH3_REG_CMD = 1'b0;

        // Base word count regs (per channel)
        dif.WRITE_BASE_WORD_COUNT_CH0_REG_CMD = 1'b0;
        dif.WRITE_BASE_WORD_COUNT_CH1_REG_CMD = 1'b0;
        dif.WRITE_BASE_WORD_COUNT_CH2_REG_CMD = 1'b0;
        dif.WRITE_BASE_WORD_COUNT_CH3_REG_CMD = 1'b0;

        // Current address reads (per channel)
        dif.READ_CURR_ADDR_CH0_REG_CMD = 1'b0;
        dif.READ_CURR_ADDR_CH1_REG_CMD = 1'b0;
        dif.READ_CURR_ADDR_CH2_REG_CMD = 1'b0;
        dif.READ_CURR_ADDR_CH3_REG_CMD = 1'b0;

        // Current word count reads (per channel)
        dif.READ_CURR_WORD_COUNT_CH0_REG_CMD = 1'b0;
        dif.READ_CURR_WORD_COUNT_CH1_REG_CMD = 1'b0;
        dif.READ_CURR_WORD_COUNT_CH2_REG_CMD = 1'b0;
        dif.READ_CURR_WORD_COUNT_CH3_REG_CMD = 1'b0;

        // Control / status registers
        dif.WRITE_COMMAND_REG_CMD     = 1'b0;
        dif.READ_STATUS_REG_CMD       = 1'b0;
        dif.WRITE_REQUEST_REG_CMD     = 1'b0;
        dif.WRITE_MODE_REG_CMD        = 1'b0;
        dif.READ_MODE_REG_CMD         = 1'b0;
        dif.CLEAR_BYTE_POINTER_CMD    = 1'b0;
        dif.SET_BYTE_POINTER_CMD      = 1'b0;
        dif.MASTER_CLEAR_CMD          = 1'b0;
        dif.CLEAR_MASK_REG_CMD        = 1'b0;
        dif.CLEAR_MODE_REG_COUNT_CMD  = 1'b0;
        dif.WRITE_MASK_REG_CMD        = 1'b0;
        dif.READ_MASK_REG_CMD         = 1'b0;

        // Enhanced register commands
        dif.WRITE_CH_CTRL_CH0_REG_CMD = 1'b0;
        dif.WRITE_CH_CTRL_CH1_REG_CMD = 1'b0;
        dif.WRITE_CH_CTRL_CH2_REG_CMD = 1'b0;
        dif.WRITE_CH_CTRL_CH3_REG_CMD = 1'b0;

        dif.WRITE_BUF_SIZE_CH0_REG_CMD = 1'b0;
        dif.WRITE_BUF_SIZE_CH1_REG_CMD = 1'b0;
        dif.WRITE_BUF_SIZE_CH2_REG_CMD = 1'b0;
        dif.WRITE_BUF_SIZE_CH3_REG_CMD = 1'b0;

        dif.WRITE_PRIORITY_CTRL_REG_CMD = 1'b0;
        dif.READ_EXT_STATUS_REG_CMD     = 1'b0;

        //============================================================
        // ACCESS QUALIFICATION
        //============================================================
        // CS_N = 0 → chip selected for register access
        // HLDA = 0 → CPU owns bus (DMA must NOT access regs)
        //------------------------------------------------------------
        if (!dif.CS_N && !dif.HLDA) begin

            //============================================================
            // WRITE CYCLE
            //   IOW_N = 0  → write strobe active
            //   IOR_N = 1  → read strobe inactive (avoid conflict)
            //============================================================
            if (!dif.IOW_N && dif.IOR_N) begin

                case (dif.ADDR_L)   // 5-bit register address

                    //---------- BASE REGISTERS ----------
                    BASE_ADDR_REG_CH0_ADDR       : dif.WRITE_BASE_ADDR_CH0_REG_CMD = 1'b1;
                    BASE_ADDR_REG_CH1_ADDR       : dif.WRITE_BASE_ADDR_CH1_REG_CMD = 1'b1;
                    BASE_ADDR_REG_CH2_ADDR       : dif.WRITE_BASE_ADDR_CH2_REG_CMD = 1'b1;
                    BASE_ADDR_REG_CH3_ADDR       : dif.WRITE_BASE_ADDR_CH3_REG_CMD = 1'b1;

                    BASE_WORD_COUNT_REG_CH0_ADDR : dif.WRITE_BASE_WORD_COUNT_CH0_REG_CMD = 1'b1;
                    BASE_WORD_COUNT_REG_CH1_ADDR : dif.WRITE_BASE_WORD_COUNT_CH1_REG_CMD = 1'b1;
                    BASE_WORD_COUNT_REG_CH2_ADDR : dif.WRITE_BASE_WORD_COUNT_CH2_REG_CMD = 1'b1;
                    BASE_WORD_COUNT_REG_CH3_ADDR : dif.WRITE_BASE_WORD_COUNT_CH3_REG_CMD = 1'b1;

                    COMMAND_REG_ADDR             : dif.WRITE_COMMAND_REG_CMD = 1'b1;
                    REQUEST_REG_ADDR             : dif.WRITE_REQUEST_REG_CMD = 1'b1;

                    // 0x0A: single-bit mask write (8237 style)
                    MASK_REG_ADDR                : dif.WRITE_MASK_REG_CMD = 1'b1;

                    MODE_REG_ADDR                : dif.WRITE_MODE_REG_CMD = 1'b1;

                    // 0x0C: write = CLEAR byte pointer
                    CLEAR_BYTE_POINTER_ADDR      : dif.CLEAR_BYTE_POINTER_CMD = 1'b1;

                    MASTER_CLEAR_ADDR            : dif.MASTER_CLEAR_CMD = 1'b1;
                    CLEAR_MASK_REG_ADDR          : dif.CLEAR_MASK_REG_CMD = 1'b1;

                    // 0x0F: write = WRITE mask
                    WRITE_MASK_REG_ADDR          : dif.WRITE_MASK_REG_CMD = 1'b1;

                    //---------- ENHANCED REGISTERS ----------
                    CH_CTRL_REG_CH0_ADDR : dif.WRITE_CH_CTRL_CH0_REG_CMD = 1'b1;
                    CH_CTRL_REG_CH1_ADDR : dif.WRITE_CH_CTRL_CH1_REG_CMD = 1'b1;
                    CH_CTRL_REG_CH2_ADDR : dif.WRITE_CH_CTRL_CH2_REG_CMD = 1'b1;
                    CH_CTRL_REG_CH3_ADDR : dif.WRITE_CH_CTRL_CH3_REG_CMD = 1'b1;

                    BUF_SIZE_REG_CH0_ADDR : dif.WRITE_BUF_SIZE_CH0_REG_CMD = 1'b1;
                    BUF_SIZE_REG_CH1_ADDR : dif.WRITE_BUF_SIZE_CH1_REG_CMD = 1'b1;
                    BUF_SIZE_REG_CH2_ADDR : dif.WRITE_BUF_SIZE_CH2_REG_CMD = 1'b1;
                    BUF_SIZE_REG_CH3_ADDR : dif.WRITE_BUF_SIZE_CH3_REG_CMD = 1'b1;

                    PRIORITY_CTRL_REG_ADDR : dif.WRITE_PRIORITY_CTRL_REG_CMD = 1'b1;

                    default : ;   // no action → all outputs stay 0

                endcase
            end

            //============================================================
            // READ CYCLE
            //   IOR_N = 0  → read strobe active
            //   IOW_N = 1  → write strobe inactive
            //============================================================
            if (dif.IOW_N && !dif.IOR_N) begin

                dif.READ_ANY_REG_CMD = 1'b1;   // generic "read active"

                case (dif.ADDR_L)

                    //---------- BASE REGISTERS ----------
                    // NOTE: Reading the base-address address returns
                    //       the CURRENT address (8237 behaviour).
                    BASE_ADDR_REG_CH0_ADDR       : dif.READ_CURR_ADDR_CH0_REG_CMD = 1'b1;
                    BASE_ADDR_REG_CH1_ADDR       : dif.READ_CURR_ADDR_CH1_REG_CMD = 1'b1;
                    BASE_ADDR_REG_CH2_ADDR       : dif.READ_CURR_ADDR_CH2_REG_CMD = 1'b1;
                    BASE_ADDR_REG_CH3_ADDR       : dif.READ_CURR_ADDR_CH3_REG_CMD = 1'b1;

                    BASE_WORD_COUNT_REG_CH0_ADDR : dif.READ_CURR_WORD_COUNT_CH0_REG_CMD = 1'b1;
                    BASE_WORD_COUNT_REG_CH1_ADDR : dif.READ_CURR_WORD_COUNT_CH1_REG_CMD = 1'b1;
                    BASE_WORD_COUNT_REG_CH2_ADDR : dif.READ_CURR_WORD_COUNT_CH2_REG_CMD = 1'b1;
                    BASE_WORD_COUNT_REG_CH3_ADDR : dif.READ_CURR_WORD_COUNT_CH3_REG_CMD = 1'b1;

                    // 0x08: read = STATUS
                    STATUS_REG_ADDR              : dif.READ_STATUS_REG_CMD = 1'b1;
                    MODE_REG_ADDR                : dif.READ_MODE_REG_CMD   = 1'b1;

                    // 0x0F: read = READ mask
                    READ_MASK_REG_ADDR           : dif.READ_MASK_REG_CMD   = 1'b1;

                    // 0x0C: read = SET byte pointer (8237 quirk)
                    SET_BYTE_POINTER_ADDR        : dif.SET_BYTE_POINTER_CMD = 1'b1;

                    //---------- ENHANCED REGISTERS ----------
                    EXT_STATUS_REG_ADDR          : dif.READ_EXT_STATUS_REG_CMD = 1'b1;

                    default : ;

                endcase
            end
        end
    end

endmodule : dma_sw_commands
