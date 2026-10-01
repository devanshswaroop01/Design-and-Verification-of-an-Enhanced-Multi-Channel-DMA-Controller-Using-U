//============================================================
// File        : cpu_seq_item.sv
// Description : CPU Bus Transaction Item
//               Represents ONE CPU bus cycle (register read/write)
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_sequence_item.
//   2. Two roles:
//        - Stimulus from sequence → driver
//        - Observation from monitor → scoreboard/predictor
//   3. `rand` fields = randomization can control them.
//   4. Constraints shape the random space (valid addr, distributions).
//   5. `uvm_object_utils_*` registers fields for compare/print/copy.
//   6. do_compare() is CUSTOM — used by scoreboard.
//============================================================

`ifndef CPU_SEQ_ITEM_SV
`define CPU_SEQ_ITEM_SV

class cpu_seq_item extends uvm_sequence_item;

    //============================================================
    // FIELDS
    //============================================================
    // rand → eligible for `randomize()` calls.
    // Non-rand fields (status) are set by driver/adapter.
    //------------------------------------------------------------
    rand bit        is_read;     // 1 = read, 0 = write
    rand bit [4:0]  addr;        // 5-bit register address (0x00–0x1F)
    rand bit [7:0]  data;        // data payload (write) / sampled (read)

    uvm_status_e    status;      // UVM_IS_OK / UVM_NOT_OK (set by driver)

    // Metadata (not randomized — for debug/trace only)
    time            start_time;
    time            end_time;
    int             cycle_count;

    //============================================================
    // CONSTRAINTS
    //============================================================
    // Constrain the RANDOM space so randomization produces only
    // legal CPU accesses with a bias toward interesting cases.
    //------------------------------------------------------------

    // Only valid register addresses (0x00–0x19)
    constraint c_valid_addr {
        addr inside {[5'h00 : 5'h19]};
    }

    // Favor edge data values (0x00, 0xFF) to hit corner cases
    constraint c_data_dist {
        data dist {
            8'h00           := 5,
            8'hFF           := 5,
            [8'h01 : 8'hFE] := 90
        };
    }

    // 60% writes, 40% reads — realistic programming mix
    constraint c_rw_dist {
        is_read dist {
            1'b0 := 60,
            1'b1 := 40
        };
    }

    //============================================================
    // CONSTRUCTOR
    //============================================================
    function new(string name = "cpu_seq_item");
        super.new(name);
        status      = UVM_IS_OK;
        cycle_count = 1;
    endfunction

    //============================================================
    // UVM AUTOMATION MACROS
    //============================================================
    // Register fields so UVM can auto-implement:
    //   copy / compare / print / pack / unpack
    // Without this, do_print()/do_compare() fall back to super.
    //------------------------------------------------------------
    `uvm_object_utils_begin(cpu_seq_item)
        `uvm_field_int (is_read,     UVM_ALL_ON | UVM_DEC)
        `uvm_field_int (addr,        UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (data,        UVM_ALL_ON | UVM_HEX)
        `uvm_field_enum(uvm_status_e, status, UVM_ALL_ON)
        `uvm_field_int (cycle_count, UVM_ALL_ON | UVM_DEC)
    `uvm_object_utils_end

    //============================================================
    // CONVERT TO STRING
    //============================================================
    // Used in log messages — shows at a glance what happened.
    //------------------------------------------------------------
    virtual function string convert2string();
        return $sformatf("[%s] addr=0x%02X data=0x%02X status=%s",
                         is_read ? "READ " : "WRITE",
                         addr, data, status.name());
    endfunction

    //============================================================
    // COMPARE (for scoreboard)
    //============================================================
    // Explicit — only compares fields that MATTER for correctness.
    // Deliberately excludes status/timing metadata.
    //------------------------------------------------------------
    virtual function bit do_compare(uvm_object rhs,
                                    uvm_comparer comparer);
        cpu_seq_item rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        return (super.do_compare(rhs, comparer) &&
                (is_read == rhs_.is_read) &&
                (addr    == rhs_.addr)    &&
                (data    == rhs_.data));
    endfunction

    //============================================================
    // CONVENIENCE METHODS
    //============================================================

    function bit is_write();
        return !is_read;
    endfunction

    // 16-bit and 24-bit regs need multi-byte (byte-pointer) access
    function bit is_multi_byte();
        case (addr)
            5'h00, 5'h01, 5'h02, 5'h03,
            5'h04, 5'h05, 5'h06, 5'h07,     // base addr / WC
            5'h14, 5'h15, 5'h16, 5'h17,     // buffer size
            5'h18:                          // priority ctrl (24-bit)
                return 1;
            default:
                return 0;
        endcase
    endfunction

    // Human-readable register name for logging
    function string get_register_name();
        case (addr)
            5'h00: return "BASE_ADDR_CH0";
            5'h01: return "BASE_WC_CH0";
            5'h02: return "BASE_ADDR_CH1";
            5'h03: return "BASE_WC_CH1";
            5'h04: return "BASE_ADDR_CH2";
            5'h05: return "BASE_WC_CH2";
            5'h06: return "BASE_ADDR_CH3";
            5'h07: return "BASE_WC_CH3";
            5'h08: return is_read ? "STATUS" : "COMMAND";
            5'h09: return "REQUEST";
            5'h0A: return "MASK";
            5'h0B: return "MODE";
            5'h0C: return is_read ? "SET_BYTE_PTR" : "CLEAR_BYTE_PTR";
            5'h0D: return "MASTER_CLEAR";
            5'h0E: return "CLEAR_MASK";
            5'h0F: return is_read ? "READ_MASK" : "WRITE_MASK";
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

    function string print_summary();
        return $sformatf("%s %s = 0x%02X",
                         is_read ? "R" : "W",
                         get_register_name(), data);
    endfunction

endclass

typedef cpu_seq_item cpu_transaction;   // alias for convenience

`endif // CPU_SEQ_ITEM_SV
