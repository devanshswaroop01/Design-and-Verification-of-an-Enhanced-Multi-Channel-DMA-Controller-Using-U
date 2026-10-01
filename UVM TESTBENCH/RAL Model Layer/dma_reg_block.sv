//============================================================
// File        : dma_reg_block.sv
// Description : UVM RAL Model for DMA Controller
//               All 26 registers modeled.
//============================================================
// INTERVIEW POINTS:
//   1. RAL = software mirror of the DUT register map.
//   2. Three levels: block → register → field.
//   3. uvm_reg subclass for each register width (8/16/24).
//   4. Each register has ONE field spanning its full width.
//   5. Address map (uvm_reg_map) ties registers to addresses.
//   6. Backdoor paths enable peek/poke via hierarchical names.
//   7. lock_model() freezes the model after build.
//============================================================

`ifndef DMA_REG_BLOCK_SV
`define DMA_REG_BLOCK_SV

    //============================================================
    // PART 1: CUSTOM UVM_REG SUBCLASSES (one per width)
    //============================================================
    // UVM needs a concrete uvm_reg subclass per register width.
    // Each just passes the width to super.new(name, n_bits, coverage).
    //------------------------------------------------------------

    class dma_reg8_rw extends uvm_reg;
        `uvm_object_utils(dma_reg8_rw)
        function new(string name = "dma_reg8_rw");
            super.new(name, 8, UVM_NO_COVERAGE);
        endfunction
    endclass

    class dma_reg8_ro extends uvm_reg;
        `uvm_object_utils(dma_reg8_ro)
        function new(string name = "dma_reg8_ro");
            super.new(name, 8, UVM_NO_COVERAGE);
        endfunction
    endclass

    class dma_reg8_wo extends uvm_reg;
        `uvm_object_utils(dma_reg8_wo)
        function new(string name = "dma_reg8_wo");
            super.new(name, 8, UVM_NO_COVERAGE);
        endfunction
    endclass

    class dma_reg16_rw extends uvm_reg;
        `uvm_object_utils(dma_reg16_rw)
        function new(string name = "dma_reg16_rw");
            super.new(name, 16, UVM_NO_COVERAGE);
        endfunction
    endclass

    class dma_reg24_rw extends uvm_reg;
        `uvm_object_utils(dma_reg24_rw)
        function new(string name = "dma_reg24_rw");
            super.new(name, 24, UVM_NO_COVERAGE);
        endfunction
    endclass

    //============================================================
    // PART 2: REGISTER BLOCK
    //============================================================
    class dma_reg_block extends uvm_reg_block;

        //--------------------------------------------------------
        // Register handles (one per DUT register)
        //--------------------------------------------------------
        // Base channel regs (16-bit)
        rand dma_reg16_rw base_addr_ch0, base_wc_ch0;
        rand dma_reg16_rw base_addr_ch1, base_wc_ch1;
        rand dma_reg16_rw base_addr_ch2, base_wc_ch2;
        rand dma_reg16_rw base_addr_ch3, base_wc_ch3;

        // Control/status regs (8-bit)
        rand dma_reg8_wo  command_reg;
        rand dma_reg8_ro  status_reg;
        rand dma_reg8_rw  request_reg;
        rand dma_reg8_rw  mask_reg;
        rand dma_reg8_rw  mode_reg;
        rand dma_reg8_wo  clear_byte_ptr;
        rand dma_reg8_wo  master_clear;
        rand dma_reg8_wo  clear_mask;
        rand dma_reg8_wo  write_mask_reg;
        rand dma_reg8_ro  read_mask_reg;

        // Enhanced regs
        rand dma_reg8_rw  ch_ctrl_reg_0, ch_ctrl_reg_1;
        rand dma_reg8_rw  ch_ctrl_reg_2, ch_ctrl_reg_3;
        rand dma_reg16_rw buf_size_reg_0, buf_size_reg_1;
        rand dma_reg16_rw buf_size_reg_2, buf_size_reg_3;
        rand dma_reg24_rw priority_ctrl_reg;
        rand dma_reg8_ro  ext_status_reg;

        //--------------------------------------------------------
        // Field handles (one field per register, spanning width)
        //--------------------------------------------------------
        uvm_reg_field f_base_addr_ch0, f_base_wc_ch0;
        uvm_reg_field f_base_addr_ch1, f_base_wc_ch1;
        uvm_reg_field f_base_addr_ch2, f_base_wc_ch2;
        uvm_reg_field f_base_addr_ch3, f_base_wc_ch3;

        uvm_reg_field f_command, f_status, f_request, f_mask, f_mode;
        uvm_reg_field f_clear_byte_ptr, f_master_clear, f_clear_mask;
        uvm_reg_field f_write_mask, f_read_mask;

        uvm_reg_field f_ch_ctrl_0, f_ch_ctrl_1, f_ch_ctrl_2, f_ch_ctrl_3;
        uvm_reg_field f_buf_size_0, f_buf_size_1, f_buf_size_2, f_buf_size_3;
        uvm_reg_field f_priority_ctrl, f_ext_status;

        //--------------------------------------------------------
        // Address map
        //--------------------------------------------------------
        uvm_reg_map dma_map;

        `uvm_object_utils(dma_reg_block)

        function new(string name = "dma_reg_block");
            super.new(name, UVM_NO_COVERAGE);
        endfunction

        //========================================================
        // HELPER: create_reg
        //========================================================
        // Wraps the 3-arg uvm_reg::configure() + 9-arg
        // uvm_reg_field::configure() into a single call.
        // Reduces boilerplate to 1 line per register.
        //--------------------------------------------------------
        function void create_reg(
            uvm_reg             reg_h,
            output uvm_reg_field field_h,
            input  string        field_name,
            input  int unsigned  size,
            input  string        access,       // "RW" / "RO" / "WO"
            input  uvm_reg_data_t reset,
            input  string        hdl_slice     // backdoor path (relative)
        );
            // Register configure — 3 args only
            reg_h.configure(this);

            // Field configure — 9 args
            field_h = new(field_name);
            field_h.configure(
                reg_h,      // parent register
                size,       // bit width
                0,          // lsb position (field starts at bit 0)
                access,     // access policy
                0,          // volatile
                reset,      // reset value
                1,          // has_reset = 1
                1,          // is_rand = 1
                0           // individually_accessible = 0
            );

            // Optional backdoor path (relative to block hdl_path)
            if (hdl_slice != "")
                reg_h.add_hdl_path_slice(hdl_slice, 0, size);
        endfunction

        //========================================================
        // BUILD
        //========================================================
        virtual function void build();

            //--------------------------------------------------
            // Address map: base=0, byte-width=1, little-endian
            //--------------------------------------------------
            dma_map = create_map("dma_map", 0, 1, UVM_LITTLE_ENDIAN, 0);

            // Block-level backdoor path (absolute)
            // Registers use RELATIVE paths → UVM concatenates:
            //   "dut.DMA_REG_FILE" + "." + "BASE_ADDR_REG[0]"
            //--------------------------------------------------
            add_hdl_path("dut.DMA_REG_FILE");

            //--------------------------------------------------
            // 16-bit channel registers (0x00–0x07)
            //--------------------------------------------------
            base_addr_ch0 = dma_reg16_rw::type_id::create("base_addr_ch0");
            create_reg(base_addr_ch0, f_base_addr_ch0, "f_base_addr_ch0",
                       16, "RW", 16'h0000, "BASE_ADDR_REG[0]");

            base_wc_ch0 = dma_reg16_rw::type_id::create("base_wc_ch0");
            create_reg(base_wc_ch0, f_base_wc_ch0, "f_base_wc_ch0",
                       16, "RW", 16'h0000, "BASE_WORD_COUNT_REG[0]");

            base_addr_ch1 = dma_reg16_rw::type_id::create("base_addr_ch1");
            create_reg(base_addr_ch1, f_base_addr_ch1, "f_base_addr_ch1",
                       16, "RW", 16'h0000, "BASE_ADDR_REG[1]");

            base_wc_ch1 = dma_reg16_rw::type_id::create("base_wc_ch1");
            create_reg(base_wc_ch1, f_base_wc_ch1, "f_base_wc_ch1",
                       16, "RW", 16'h0000, "BASE_WORD_COUNT_REG[1]");

            base_addr_ch2 = dma_reg16_rw::type_id::create("base_addr_ch2");
            create_reg(base_addr_ch2, f_base_addr_ch2, "f_base_addr_ch2",
                       16, "RW", 16'h0000, "BASE_ADDR_REG[2]");

            base_wc_ch2 = dma_reg16_rw::type_id::create("base_wc_ch2");
            create_reg(base_wc_ch2, f_base_wc_ch2, "f_base_wc_ch2",
                       16, "RW", 16'h0000, "BASE_WORD_COUNT_REG[2]");

            base_addr_ch3 = dma_reg16_rw::type_id::create("base_addr_ch3");
            create_reg(base_addr_ch3, f_base_addr_ch3, "f_base_addr_ch3",
                       16, "RW", 16'h0000, "BASE_ADDR_REG[3]");

            base_wc_ch3 = dma_reg16_rw::type_id::create("base_wc_ch3");
            create_reg(base_wc_ch3, f_base_wc_ch3, "f_base_wc_ch3",
                       16, "RW", 16'h0000, "BASE_WORD_COUNT_REG[3]");

            //--------------------------------------------------
            // Control/status registers (0x08–0x0F)
            //--------------------------------------------------
            command_reg = dma_reg8_wo::type_id::create("command_reg");
            create_reg(command_reg, f_command, "f_command",
                       8, "WO", 8'h00, "COMMAND_REG");

            status_reg = dma_reg8_ro::type_id::create("status_reg");
            create_reg(status_reg, f_status, "f_status",
                       8, "RO", 8'h00, "STATUS_REG");

            request_reg = dma_reg8_rw::type_id::create("request_reg");
            create_reg(request_reg, f_request, "f_request",
                       8, "RW", 8'h00, "REQUEST_REG");

            mask_reg = dma_reg8_rw::type_id::create("mask_reg");
            create_reg(mask_reg, f_mask, "f_mask",
                       8, "RW", 8'h00, "MASK_REG");

            mode_reg = dma_reg8_rw::type_id::create("mode_reg");
            create_reg(mode_reg, f_mode, "f_mode",
                       8, "RW", 8'h00, "MODE_REG[0]");

            // Special: no backdoor path (write-only side-effect regs)
            clear_byte_ptr = dma_reg8_wo::type_id::create("clear_byte_ptr");
            create_reg(clear_byte_ptr, f_clear_byte_ptr, "f_clear_byte_ptr",
                       8, "WO", 8'h00, "");

            master_clear = dma_reg8_wo::type_id::create("master_clear");
            create_reg(master_clear, f_master_clear, "f_master_clear",
                       8, "WO", 8'h00, "");

            clear_mask = dma_reg8_wo::type_id::create("clear_mask");
            create_reg(clear_mask, f_clear_mask, "f_clear_mask",
                       8, "WO", 8'h00, "");

            write_mask_reg = dma_reg8_wo::type_id::create("write_mask_reg");
            create_reg(write_mask_reg, f_write_mask, "f_write_mask",
                       8, "WO", 8'h00, "");

            read_mask_reg = dma_reg8_ro::type_id::create("read_mask_reg");
            create_reg(read_mask_reg, f_read_mask, "f_read_mask",
                       8, "RO", 8'h00, "MASK_REG");

            //--------------------------------------------------
            // Enhanced registers (0x10–0x19)
            //--------------------------------------------------
            ch_ctrl_reg_0 = dma_reg8_rw::type_id::create("ch_ctrl_reg_0");
            create_reg(ch_ctrl_reg_0, f_ch_ctrl_0, "f_ch_ctrl_0",
                       8, "RW", 8'h00, "CH_CTRL_REG[0]");

            ch_ctrl_reg_1 = dma_reg8_rw::type_id::create("ch_ctrl_reg_1");
            create_reg(ch_ctrl_reg_1, f_ch_ctrl_1, "f_ch_ctrl_1",
                       8, "RW", 8'h00, "CH_CTRL_REG[1]");

            ch_ctrl_reg_2 = dma_reg8_rw::type_id::create("ch_ctrl_reg_2");
            create_reg(ch_ctrl_reg_2, f_ch_ctrl_2, "f_ch_ctrl_2",
                       8, "RW", 8'h00, "CH_CTRL_REG[2]");

            ch_ctrl_reg_3 = dma_reg8_rw::type_id::create("ch_ctrl_reg_3");
            create_reg(ch_ctrl_reg_3, f_ch_ctrl_3, "f_ch_ctrl_3",
                       8, "RW", 8'h00, "CH_CTRL_REG[3]");

            buf_size_reg_0 = dma_reg16_rw::type_id::create("buf_size_reg_0");
            create_reg(buf_size_reg_0, f_buf_size_0, "f_buf_size_0",
                       16, "RW", 16'h0000, "BUF_SIZE_REG[0]");

            buf_size_reg_1 = dma_reg16_rw::type_id::create("buf_size_reg_1");
            create_reg(buf_size_reg_1, f_buf_size_1, "f_buf_size_1",
                       16, "RW", 16'h0000, "BUF_SIZE_REG[1]");

            buf_size_reg_2 = dma_reg16_rw::type_id::create("buf_size_reg_2");
            create_reg(buf_size_reg_2, f_buf_size_2, "f_buf_size_2",
                       16, "RW", 16'h0000, "BUF_SIZE_REG[2]");

            buf_size_reg_3 = dma_reg16_rw::type_id::create("buf_size_reg_3");
            create_reg(buf_size_reg_3, f_buf_size_3, "f_buf_size_3",
                       16, "RW", 16'h0000, "BUF_SIZE_REG[3]");

            priority_ctrl_reg = dma_reg24_rw::type_id::create("priority_ctrl_reg");
            create_reg(priority_ctrl_reg, f_priority_ctrl, "f_priority_ctrl",
                       24, "RW", 24'h000000, "PRIORITY_CTRL_REG");

            ext_status_reg = dma_reg8_ro::type_id::create("ext_status_reg");
            create_reg(ext_status_reg, f_ext_status, "f_ext_status",
                       8, "RO", 8'h00, "EXT_STATUS_REG");

            //--------------------------------------------------
            // MAP REGISTERS TO ADDRESSES
            //--------------------------------------------------
            // Base channel regs (0x00–0x07)
            dma_map.add_reg(base_addr_ch0, 5'h00, "RW");
            dma_map.add_reg(base_wc_ch0,   5'h01, "RW");
            dma_map.add_reg(base_addr_ch1, 5'h02, "RW");
            dma_map.add_reg(base_wc_ch1,   5'h03, "RW");
            dma_map.add_reg(base_addr_ch2, 5'h04, "RW");
            dma_map.add_reg(base_wc_ch2,   5'h05, "RW");
            dma_map.add_reg(base_addr_ch3, 5'h06, "RW");
            dma_map.add_reg(base_wc_ch3,   5'h07, "RW");

            // Control regs — NOTE aliased addresses (same addr, different access)
            dma_map.add_reg(command_reg,    5'h08, "WO");  // write side
            dma_map.add_reg(status_reg,     5'h08, "RO");  // read side
            dma_map.add_reg(request_reg,    5'h09, "RW");
            dma_map.add_reg(mask_reg,       5'h0A, "RW");
            dma_map.add_reg(mode_reg,       5'h0B, "RW");
            dma_map.add_reg(clear_byte_ptr, 5'h0C, "WO");  // write side
            dma_map.add_reg(master_clear,   5'h0D, "WO");
            dma_map.add_reg(clear_mask,     5'h0E, "WO");
            dma_map.add_reg(write_mask_reg, 5'h0F, "WO");  // write side
            dma_map.add_reg(read_mask_reg,  5'h0F, "RO");  // read side

            // Enhanced regs (0x10–0x19)
            dma_map.add_reg(ch_ctrl_reg_0,     5'h10, "RW");
            dma_map.add_reg(ch_ctrl_reg_1,     5'h11, "RW");
            dma_map.add_reg(ch_ctrl_reg_2,     5'h12, "RW");
            dma_map.add_reg(ch_ctrl_reg_3,     5'h13, "RW");
            dma_map.add_reg(buf_size_reg_0,    5'h14, "RW");
            dma_map.add_reg(buf_size_reg_1,    5'h15, "RW");
            dma_map.add_reg(buf_size_reg_2,    5'h16, "RW");
            dma_map.add_reg(buf_size_reg_3,    5'h17, "RW");
            dma_map.add_reg(priority_ctrl_reg, 5'h18, "RW");
            dma_map.add_reg(ext_status_reg,    5'h19, "RO");

            //--------------------------------------------------
            // Finalize
            //--------------------------------------------------
            // auto_predict=0 → scoreboard must update mirror
            //                  from observed bus traffic (via predictor)
            dma_map.set_auto_predict(0);

            // Freeze the model — no more registers can be added
            lock_model();
        endfunction

    endclass

//    Block:      add_hdl_path("dut.DMA_REG_FILE")           ← absolute
//    Register:   add_hdl_path_slice("BASE_ADDR_REG[0]")     ← relative
//                          │
//                          ▼
//    UVM concatenates: "dut.DMA_REG_FILE.BASE_ADDR_REG[0]"
//                          │
//                          ▼
//    Enables:  reg.peek(status, value);   // read RTL directly
//              reg.poke(status, value);   // write RTL directly

//    FRONTDOOR (reg.write / reg.read):
//        reg.write() → adapter → cpu_seq_item → driver → DUT
//        ✓ Legitimate bus transaction
//        ✓ Checks address decode, timing
//        ✗ Slow (bus cycles)

//    BACKDOOR (reg.poke / reg.peek):
//        reg.poke() → hierarchical path → RTL signal
//        ✓ Instant
//        ✓ No bus traffic
//        ✗ Bypasses DUT logic

// `endif // DMA_REG_BLOCK_SV
