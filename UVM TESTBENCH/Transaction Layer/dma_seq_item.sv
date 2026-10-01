//============================================================
// File        : dma_seq_item.sv
// Description : DMA Bus Transaction Item
//               Dual-purpose: stimulus (drive_dma=1) OR
//                             observation (drive_dma=0).
//============================================================
// INTERVIEW POINTS:
//   1. Carries BOTH handshake signals and internal state.
//   2. drive_dma flag selects behavior:
//        drive_dma=1 → driver drives dreq_drive/hlda_drive
//        drive_dma=0 → item is a pure observation snapshot
//   3. do_compare() compares EVERY field (FIX R4).
//   4. Constraints keep one-hot DACK and valid addr_l.
//============================================================

`ifndef DMA_SEQ_ITEM_SV
`define DMA_SEQ_ITEM_SV

    //============================================================
    // TRANSACTION TYPE ENUMERATION
    //============================================================
    typedef enum logic [3:0] {
        DMA_RESET_TX        = 4'd0,
        DMA_REQ_TX          = 4'd1,
        DMA_GRANT_TX        = 4'd2,
        DMA_TRANSFER_TX     = 4'd3,
        DMA_COMPLETE_TX     = 4'd4,
        DMA_MASTER_CLEAR_TX = 4'd5,
        DMA_ROLLOVER_TX     = 4'd6,
        DMA_ERROR_TX        = 4'd7,
        DMA_REG_WRITE_TX    = 4'd8,
        DMA_REG_READ_TX     = 4'd9,
        DMA_IDLE_TX         = 4'd15
    } dma_tx_type_t;

    //============================================================
    // CYCLE TYPE
    //============================================================
    typedef enum logic {
        IDLE   = 1'b0,
        ACTIVE = 1'b1
    } dma_cycle_t;

    //============================================================
    // DMA SEQUENCE ITEM
    //============================================================
    class dma_seq_item extends uvm_sequence_item;

        //--------------------------------------------------------
        // Transaction identity
        //--------------------------------------------------------
        rand dma_tx_type_t tx_type;
        rand dma_cycle_t   cycle;

        //--------------------------------------------------------
        // Input stimulus (also captured when observed)
        //--------------------------------------------------------
        rand bit [3:0]  dreq;
        rand bit [3:0]  hlda;

        //--------------------------------------------------------
        // DUT handshake outputs (observed)
        //--------------------------------------------------------
        bit [3:0]  hrq;
        bit [3:0]  dack;
        bit        aen;
        bit        adstb;
        bit        eop_n;

        //--------------------------------------------------------
        // CPU bus side (observed during programming)
        //--------------------------------------------------------
        bit [4:0]  addr_l;
        bit [3:0]  addr_u;
        bit [7:0]  db;
        bit        ior_n;
        bit        iow_n;

        //--------------------------------------------------------
        // Extended channel state
        //--------------------------------------------------------
        bit [1:0]  active_chnum;
        bit [3:0]  active_dack;
        bit        valid_dack;
        bit        xfer_pulse;
        bit        timeout;

        //--------------------------------------------------------
        // Circular buffer state
        //--------------------------------------------------------
        bit [15:0] buffer_used_0, buffer_used_1;
        bit [15:0] buffer_used_2, buffer_used_3;
        bit [3:0]  rollover_status;
        bit [3:0]  rollover_latched;
        bit        watermark_reached;
        bit        rollover_any;

        //--------------------------------------------------------
        // Status register snapshot
        //--------------------------------------------------------
        bit [7:0]  ext_status_reg;

        //--------------------------------------------------------
        // DMA drive fields (active mode only)
        //--------------------------------------------------------
        rand bit        drive_dma;
        rand bit [3:0]  dreq_drive;
        rand bit        hlda_drive;

        //--------------------------------------------------------
        // Status & timing
        //--------------------------------------------------------
        uvm_status_e status;
        time         start_time, end_time;

        //========================================================
        // CONSTRUCTOR
        //========================================================
        function new(string name = "dma_seq_item");
            super.new(name);
            status     = UVM_IS_OK;
            drive_dma  = 1'b0;
            dreq_drive = 4'b0000;
            hlda_drive = 1'b0;
        endfunction

        //========================================================
        // UVM AUTOMATION MACROS
        //========================================================
        `uvm_object_utils_begin(dma_seq_item)
            // Transaction identity
            `uvm_field_enum(dma_tx_type_t, tx_type, UVM_ALL_ON)
            `uvm_field_enum(dma_cycle_t,   cycle,   UVM_ALL_ON)

            // Input stimulus
            `uvm_field_int(dreq,  UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(hlda,  UVM_ALL_ON | UVM_HEX)

            // Handshake outputs
            `uvm_field_int(hrq,   UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(dack,  UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(aen,   UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(adstb, UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(eop_n, UVM_ALL_ON | UVM_BIN)

            // CPU bus
            `uvm_field_int(addr_l, UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(addr_u, UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(db,     UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(ior_n,  UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(iow_n,  UVM_ALL_ON | UVM_BIN)

            // Extended channel state
            `uvm_field_int(active_chnum, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(active_dack,  UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(valid_dack,   UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(xfer_pulse,   UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(timeout,      UVM_ALL_ON | UVM_BIN)

            // Circular buffer
            `uvm_field_int(buffer_used_0, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(buffer_used_1, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(buffer_used_2, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(buffer_used_3, UVM_ALL_ON | UVM_DEC)
            `uvm_field_int(rollover_status,   UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(rollover_latched,  UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(watermark_reached, UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(rollover_any,      UVM_ALL_ON | UVM_BIN)

            // Status register snapshot
            `uvm_field_int(ext_status_reg, UVM_ALL_ON | UVM_HEX)

            // DMA drive
            `uvm_field_int(drive_dma,  UVM_ALL_ON | UVM_BIN)
            `uvm_field_int(dreq_drive, UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(hlda_drive, UVM_ALL_ON | UVM_BIN)

            `uvm_field_enum(uvm_status_e, status, UVM_ALL_ON)
        `uvm_object_utils_end

        //========================================================
        // CONVERT TO STRING
        //========================================================
        virtual function string convert2string();
            if (drive_dma) begin
                return $sformatf("[DMA_DRIVE] dreq=0x%X hlda=%b",
                                 dreq_drive, hlda_drive);
            end else begin
                return $sformatf("[%s] cycle=%s dreq=0x%X hlda=0x%X ",
                                  "hrq=0x%X dack=0x%X ch=%0d xfer=%b eop_n=%b",
                                 tx_type.name(), cycle.name(),
                                 dreq, hlda, hrq, dack,
                                 active_chnum, xfer_pulse, eop_n);
            end
        endfunction

        //========================================================
        // COMPARE — FIX R4: compares ALL fields
        //========================================================
        // Rationale: earlier versions only compared base bus
        // signals, so items differing only in active_chnum /
        // buffer_used / rollover / ext_status were declared equal.
        // That silently hid scoreboard mismatches.
        //--------------------------------------------------------
        virtual function bit do_compare(uvm_object rhs,
                                        uvm_comparer comparer);
            dma_seq_item rhs_;
            if (!$cast(rhs_, rhs)) return 0;
            return (super.do_compare(rhs, comparer)                &&
                    // identity
                    (tx_type          == rhs_.tx_type)             &&
                    (cycle            == rhs_.cycle)               &&
                    // stimulus
                    (dreq             == rhs_.dreq)                &&
                    (hlda             == rhs_.hlda)                &&
                    // handshake outputs
                    (hrq              == rhs_.hrq)                 &&
                    (dack             == rhs_.dack)                &&
                    (aen              == rhs_.aen)                 &&
                    (adstb            == rhs_.adstb)               &&
                    (eop_n            == rhs_.eop_n)               &&
                    // CPU bus
                    (addr_l           == rhs_.addr_l)              &&
                    (db               == rhs_.db)                  &&
                    // DMA drive
                    (drive_dma        == rhs_.drive_dma)           &&
                    (dreq_drive       == rhs_.dreq_drive)          &&
                    (hlda_drive       == rhs_.hlda_drive)          &&
                    // extended channel state
                    (active_chnum     == rhs_.active_chnum)        &&
                    (active_dack      == rhs_.active_dack)         &&
                    (valid_dack       == rhs_.valid_dack)          &&
                    (xfer_pulse       == rhs_.xfer_pulse)          &&
                    (timeout          == rhs_.timeout)             &&
                    // circular buffer state
                    (buffer_used_0    == rhs_.buffer_used_0)       &&
                    (buffer_used_1    == rhs_.buffer_used_1)       &&
                    (buffer_used_2    == rhs_.buffer_used_2)       &&
                    (buffer_used_3    == rhs_.buffer_used_3)       &&
                    (rollover_status  == rhs_.rollover_status)     &&
                    (rollover_latched == rhs_.rollover_latched)    &&
                    (watermark_reached== rhs_.watermark_reached)   &&
                    (rollover_any     == rhs_.rollover_any)        &&
                    // ext status
                    (ext_status_reg   == rhs_.ext_status_reg));
        endfunction

        //========================================================
        // CONSTRAINTS
        //========================================================
        // Keeps randomization producing only legal items.
        //--------------------------------------------------------

        constraint c_tx_type {
            tx_type inside {DMA_RESET_TX, DMA_REQ_TX, DMA_GRANT_TX,
                            DMA_TRANSFER_TX, DMA_COMPLETE_TX,
                            DMA_MASTER_CLEAR_TX, DMA_ROLLOVER_TX,
                            DMA_ERROR_TX, DMA_REG_WRITE_TX,
                            DMA_REG_READ_TX, DMA_IDLE_TX};
        }

        // DACK must be one-hot (or zero when idle)
        constraint c_dack_onehot {
            $onehot0(dack);
        }

        // Register address must be in valid range
        constraint c_addr_range {
            addr_l inside {[5'h00 : 5'h19]};
        }

        // If not driving DMA, force stimulus fields to 0
        constraint c_drive_dma {
            if (drive_dma) {
                hlda_drive inside {0, 1};
                dreq_drive inside {[4'b0000 : 4'b1111]};
            } else {
                dreq_drive == 4'b0000;
                hlda_drive == 1'b0;
            }
        }

        //========================================================
        // CONVENIENCE METHODS
        //========================================================
        function bit is_transfer();
            return (cycle == ACTIVE);
        endfunction

        function bit is_grant();
            return (|dack);
        endfunction

        function string get_register_name();
            case (addr_l)
                5'h00: return "BASE_ADDR_CH0";
                5'h01: return "BASE_WC_CH0";
                5'h02: return "BASE_ADDR_CH1";
                5'h03: return "BASE_WC_CH1";
                5'h04: return "BASE_ADDR_CH2";
                5'h05: return "BASE_WC_CH2";
                5'h06: return "BASE_ADDR_CH3";
                5'h07: return "BASE_WC_CH3";
                5'h08: return (ior_n == 1'b0) ? "STATUS" : "COMMAND";
                5'h09: return "REQUEST";
                5'h0A: return "MASK";
                5'h0B: return "MODE";
                5'h0C: return "BYTE_PTR_CTRL";
                5'h0D: return "MASTER_CLEAR";
                5'h0E: return "CLEAR_MASK";
                5'h0F: return (ior_n == 1'b0) ? "READ_MASK" : "WRITE_MASK";
                5'h10: return "CH_CTRL_0";
                5'h11: return "CH_CTRL_1";
                5'h12: return "CH_CTRL_2";
                5'h13: return "CH_CTRL_3";
                5'h14: return "BUF_SIZE_0";
                5'h15: return "BUF_SIZE_1";
                5'h16: return "BUF_SIZE_2";
                5'h17: return "BUF_SIZE_3";
                5'h18: return "PRIORITY_CTRL";
                5'h19: return "EXT_STATUS";
                default: return "UNKNOWN";
            endcase
        endfunction

    endclass

    typedef dma_seq_item dma_transaction;

`endif // DMA_SEQ_ITEM_SV
