//============================================================
// File        : dma_test_library.sv
// Description : Merged UVM Test Library for DMA Controller
//
// Project     : Enhanced Multi-Channel DMA Controller
// UVM Version : 1.2
//
// ROLE:
//   Single compilation unit containing all tests. Merged from
//   many small files to reduce compile time and file count.
//
// CONTAINS (in order):
//   Section 1 : dma_base_test              (base + helpers)
//   Section 2 : cpu_single_item_seq        (helper sequence)
//   Section 3 : dma_smoke_test             (quick bring-up)
//   Section 4 : dma_reg_write_test         (register writes)
//   Section 5 : dma_reg_read_test          (register reads)
//   Section 6 : dma_reg_test               (full register RW)
//   Section 7 : dma_dma_read_test          (DMA read config)
//   Section 8 : dma_dma_write_test         (DMA write config)
//   Section 9 : dma_priority_test          (arbiter modes)
//   Section 10: dma_circular_test          (circular buffer)
//   Section 11: dma_error_test             (error recovery)
//   Section 12: dma_random_register_configuration_test
//   Section 13: dma_mixed_programming_test
//   Section 14: dma_back_to_back_dma_test
//   Section 15: dma_channel_configuration_test
//   Section 16: dma_random_test            (RAL random)
//   Section 17: dma_random_regression_test
//   Section 18: dma_stress_test
//   Section 19: dma_reset_test             (reset values)
//   Section 20: dma_byte_pointer_test      (byte-ptr semantics)
//   Section 21: dma_master_clear_test      (MC scope)
//   Section 22: dma_transfer_test          (actual transfers)
//
// INTERVIEW POINTS:
//   1. Base test creates env + configs + vif; helpers reused.
//   2. Every test raises/drops objection on run_phase.
//   3. `report_test_status` prints final pass/fail summary.
//   4. `wait_for_reset` and `do_master_clear` are universal.
//   5. Plusargs allow runtime sizing (NUM_OPS, NUM_ITERS).
//   6. Helper `send_bus_item` sends a single cpu_seq_item.
//   7. Direct sequences (16-bit writes) coexist with RAL access.
//============================================================

`ifndef DMA_TEST_LIBRARY_SV
`define DMA_TEST_LIBRARY_SV


//============================================================
// SECTION 1: BASE TEST
//============================================================
// Provides env instantiation, config setup, reset wait, master
// clear helper, and pass/fail reporting. All other tests extend
// this and only implement run_phase().
//------------------------------------------------------------
class dma_base_test extends uvm_test;

    dma_env         env;
    dma_reg_block   reg_model;
    virtual dma_if  vif;

    `uvm_component_utils(dma_base_test)

    function new(string name = "dma_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //--------------------------------------------------------
    // BUILD PHASE — publish configs, create env
    //--------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Suppress known-benign RAL warnings
        uvm_top.set_report_id_action("RegModel",
                                     UVM_DISPLAY | UVM_LOG | UVM_COUNT);
        uvm_top.set_report_id_verbosity("RegModel", UVM_LOW);

        // Fetch VIF
        if (!uvm_config_db #(virtual dma_if)::get(this, "", "vif", vif))
            `uvm_fatal("BASE_TEST", "No virtual interface 'vif' in config_db")

        // Publish CPU agent config (ACTIVE)
        begin
            cpu_agent_config cpu_cfg = cpu_agent_config::type_id::create("cpu_cfg");
            cpu_cfg.vif       = vif;
            cpu_cfg.is_active = UVM_ACTIVE;
            uvm_config_db #(cpu_agent_config)::set(this, "env", "cpu_cfg", cpu_cfg);
        end

        // Publish DMA agent config (ACTIVE — drives DREQ/HLDA)
        begin
            dma_agent_config dma_cfg = dma_agent_config::type_id::create("dma_cfg");
            dma_cfg.vif       = vif;
            dma_cfg.is_active = UVM_ACTIVE;
            uvm_config_db #(dma_agent_config)::set(this, "env", "dma_cfg", dma_cfg);
        end

        env = dma_env::type_id::create("env", this);
    endfunction

    //--------------------------------------------------------
    // CONNECT PHASE — grab RAL handle from env
    //--------------------------------------------------------
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        reg_model = env.reg_model;
    endfunction

    //--------------------------------------------------------
    // END OF ELABORATION — print topology
    //--------------------------------------------------------
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        uvm_top.print_topology();
    endfunction

    //--------------------------------------------------------
    // RUN PHASE — no scenario by default
    //--------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        `uvm_info("BASE_TEST", "Base test running (no scenario)", UVM_MEDIUM)
    endtask

    //--------------------------------------------------------
    // HELPER: wait for reset + N idle cycles
    //--------------------------------------------------------
    task wait_for_reset(input int extra_cycles = 5);
        wait (vif.RESET == 1'b0);
        repeat (extra_cycles) @(posedge vif.CLK);
        `uvm_info("BASE_TEST", "Reset deasserted", UVM_HIGH)
    endtask

    //--------------------------------------------------------
    // HELPER: issue MASTER_CLEAR via RAL
    //--------------------------------------------------------
    task do_master_clear();
        uvm_status_e status;
        reg_model.master_clear.write(status, 8'h00);
        if (status != UVM_IS_OK)
            `uvm_error("BASE_TEST", "Master clear write returned non-OK status")
        repeat (5) @(posedge vif.CLK);
        `uvm_info("BASE_TEST", "Master clear issued via RAL", UVM_HIGH)
    endtask

    //--------------------------------------------------------
    // HELPER: print pass/fail summary from report server
    //--------------------------------------------------------
    function void report_test_status(string test_name);
        uvm_report_server svr = uvm_report_server::get_server();
        int errs     = svr.get_severity_count(UVM_ERROR);
        int fatals   = svr.get_severity_count(UVM_FATAL);
        int warnings = svr.get_severity_count(UVM_WARNING);

        `uvm_info("BASE_TEST", "==================================================", UVM_LOW)
        `uvm_info("BASE_TEST", $sformatf("Test: %s", test_name), UVM_LOW)
        `uvm_info("BASE_TEST", $sformatf("  errors   : %0d", errs),     UVM_LOW)
        `uvm_info("BASE_TEST", $sformatf("  warnings : %0d", warnings), UVM_LOW)
        `uvm_info("BASE_TEST", $sformatf("  fatals   : %0d", fatals),   UVM_LOW)

        if (errs == 0 && fatals == 0)
            `uvm_info("BASE_TEST", "  STATUS   : PASSED", UVM_LOW)
        else
            `uvm_info("BASE_TEST", "  STATUS   : FAILED", UVM_LOW)

        `uvm_info("BASE_TEST", "==================================================", UVM_LOW)
    endfunction

endclass


//============================================================
// SECTION 2: HELPER SEQUENCE — single bus item
//============================================================
// Utility sequence to send one cpu_seq_item. Used by tests
// that want direct byte-level bus access without going through
// a full sequence.
//------------------------------------------------------------
class cpu_single_item_seq extends uvm_sequence #(cpu_seq_item);

    `uvm_object_utils(cpu_single_item_seq)

    //--- Version 1 API (fields) ---
    rand bit        is_read;
    rand bit [4:0]  addr;
    rand bit [7:0]  data;

    //--- Version 2 API (caller supplies item handle) ---
    cpu_seq_item    item;

    function new(string name = "cpu_single_item_seq");
        super.new(name);
    endfunction

    virtual task body();
        cpu_seq_item tx;

        if (item != null) begin
            // Caller supplied item — send it as-is
            start_item(item);
            finish_item(item);
        end else begin
            // Build item from fields
            tx = cpu_seq_item::type_id::create("tx");
            start_item(tx);
            tx.is_read = is_read;
            tx.addr    = addr;
            tx.data    = data;
            finish_item(tx);
        end
        // NO get_response() — avoids response-queue deadlock
    endtask

endclass


//============================================================
// SECTION 3: SMOKE TEST
//============================================================
// Quick bring-up: writes/reads CH_CTRL, BASE_ADDR, PRIORITY.
// Uses RAL for 8-bit, direct sequence for 16/24-bit.
//------------------------------------------------------------
class dma_smoke_test extends dma_base_test;

    `uvm_component_utils(dma_smoke_test)

    function new(string name = "dma_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        bit [15:0]     val16;
        bit [23:0]     val24;
        int            errors = 0;

        phase.raise_objection(this, "Smoke test running");
        wait_for_reset();

        `uvm_info("SMOKE", "=========== DMA SMOKE TEST STARTING ===========", UVM_LOW)

        // Test 1: CH_CTRL_REG_0 via RAL
        reg_model.ch_ctrl_reg_0.write(status, 8'h87);
        if (status != UVM_IS_OK) begin
            `uvm_error("SMOKE", "ch_ctrl_reg_0 write failed")
            errors++;
        end
        reg_model.ch_ctrl_reg_0.read(status, rdata);
        if (status != UVM_IS_OK || rdata[7:0] !== 8'h87) begin
            `uvm_error("SMOKE",
                $sformatf("ch_ctrl_reg_0: exp=0x87 obs=0x%02X", rdata[7:0]))
            errors++;
        end else
            `uvm_info("SMOKE", "  -> PASS: ch_ctrl_reg_0 = 0x87", UVM_LOW)

        // Test 2: BASE_ADDR_CH0 (16-bit, direct)
        write_16bit(5'h00, 16'hABCD);
        read_16bit (5'h00, val16);
        if (val16 !== 16'hABCD) begin
            `uvm_error("SMOKE",
                $sformatf("base_addr_ch0: exp=0xABCD obs=0x%04X", val16))
            errors++;
        end else
            `uvm_info("SMOKE", "  -> PASS: base_addr_ch0 = 0xABCD", UVM_LOW)

        // Test 3: PRIORITY_CTRL_REG (24-bit, direct)
        write_24bit(5'h18, 24'h5D5555);
        read_24bit (5'h18, val24);
        if (val24 !== 24'h5D5555) begin
            `uvm_error("SMOKE",
                $sformatf("priority_ctrl_reg: exp=0x5D5555 obs=0x%06X", val24))
            errors++;
        end else
            `uvm_info("SMOKE", "  -> PASS: priority_ctrl_reg = 0x5D5555", UVM_LOW)

        do_master_clear();

        if (errors == 0)
            `uvm_info("SMOKE", "*** SMOKE TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("SMOKE",
                $sformatf("*** SMOKE TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_smoke_test");
        phase.drop_objection(this, "Smoke test complete");
    endtask

    //--------------------------------------------------------
    // Helper: send one item via CPU sequencer
    //--------------------------------------------------------
    protected task send_bus_item(cpu_seq_item item);
        cpu_single_item_seq seq;
        seq = cpu_single_item_seq::type_id::create("single_seq");
        seq.item = item;
        seq.start(env.cpu_agt.sequencer);
    endtask

    //--------------------------------------------------------
    // Helpers: 16-bit and 24-bit access via direct bus writes
    //--------------------------------------------------------
    protected task write_16bit(bit [4:0] addr, bit [15:0] data);
        cpu_seq_item item;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_lo");
        item.is_read = 1'b0; item.addr = addr; item.data = data[7:0];
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_hi");
        item.is_read = 1'b0; item.addr = addr; item.data = data[15:8];
        send_bus_item(item);
    endtask

    protected task read_16bit(bit [4:0] addr, output bit [15:0] data);
        cpu_seq_item item;
        bit [7:0] lo, hi;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("r_lo");
        item.is_read = 1'b1; item.addr = addr;
        send_bus_item(item); lo = item.data;
        item = cpu_seq_item::type_id::create("r_hi");
        item.is_read = 1'b1; item.addr = addr;
        send_bus_item(item); hi = item.data;
        data = {hi, lo};
    endtask

    protected task write_24bit(bit [4:0] addr, bit [23:0] data);
        cpu_seq_item item;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_b0");
        item.is_read = 1'b0; item.addr = addr; item.data = data[7:0];
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_b1");
        item.is_read = 1'b0; item.addr = addr; item.data = data[15:8];
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_b2");
        item.is_read = 1'b0; item.addr = addr; item.data = data[23:16];
        send_bus_item(item);
    endtask

    protected task read_24bit(bit [4:0] addr, output bit [23:0] data);
        cpu_seq_item item;
        bit [7:0] b0, b1, b2;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("r_b0");
        item.is_read = 1'b1; item.addr = addr;
        send_bus_item(item); b0 = item.data;
        item = cpu_seq_item::type_id::create("r_b1");
        item.is_read = 1'b1; item.addr = addr;
        send_bus_item(item); b1 = item.data;
        item = cpu_seq_item::type_id::create("r_b2");
        item.is_read = 1'b1; item.addr = addr;
        send_bus_item(item); b2 = item.data;
        data = {b2, b1, b0};
    endtask

endclass


//============================================================
// SECTION 4: REGISTER WRITE TEST
//============================================================
// Runs dma_reg_write_seq to program all register groups.
//------------------------------------------------------------
class dma_reg_write_test extends dma_base_test;

    `uvm_component_utils(dma_reg_write_test)
    dma_reg_write_seq seq;

    function new(string name = "dma_reg_write_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Register write test running");
        wait_for_reset();
        do_master_clear();

        seq = dma_reg_write_seq::type_id::create("seq");
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_reg_write_test");
        phase.drop_objection(this, "Register write test complete");
    endtask

endclass


//============================================================
// SECTION 5: REGISTER READ TEST
//============================================================
class dma_reg_read_test extends dma_base_test;

    `uvm_component_utils(dma_reg_read_test)
    dma_reg_read_seq seq;

    function new(string name = "dma_reg_read_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Register read test running");
        wait_for_reset();
        do_master_clear();

        seq = dma_reg_read_seq::type_id::create("seq");
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_reg_read_test");
        phase.drop_objection(this, "Register read test complete");
    endtask

endclass


//============================================================
// SECTION 6: FULL REGISTER ACCESS TEST (mixed RAL + direct)
//============================================================
class dma_reg_test extends dma_base_test;

    `uvm_component_utils(dma_reg_test)

    function new(string name = "dma_reg_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int errors = 0;

        phase.raise_objection(this, "Register test running");
        wait_for_reset();
        do_master_clear();

        `uvm_info("REG_TEST", "=========== DMA REGISTER TEST STARTING ===========", UVM_LOW)

        // Group 1: base addresses (16-bit)
        check_reg_16(5'h00, 16'h1000, "base_addr_ch0", errors);
        check_reg_16(5'h02, 16'h2000, "base_addr_ch1", errors);
        check_reg_16(5'h04, 16'h3000, "base_addr_ch2", errors);
        check_reg_16(5'h06, 16'h4000, "base_addr_ch3", errors);

        // Group 2: word counts (16-bit)
        check_reg_16(5'h01, 16'h0080, "base_wc_ch0", errors);
        check_reg_16(5'h03, 16'h0100, "base_wc_ch1", errors);
        check_reg_16(5'h05, 16'h0040, "base_wc_ch2", errors);
        check_reg_16(5'h07, 16'h0020, "base_wc_ch3", errors);

        // Group 3: CH_CTRL (8-bit) via RAL
        check_reg_8(reg_model.ch_ctrl_reg_0, 8'h87, "ch_ctrl_reg_0", errors);
        check_reg_8(reg_model.ch_ctrl_reg_1, 8'h47, "ch_ctrl_reg_1", errors);
        check_reg_8(reg_model.ch_ctrl_reg_2, 8'h83, "ch_ctrl_reg_2", errors);
        check_reg_8(reg_model.ch_ctrl_reg_3, 8'h01, "ch_ctrl_reg_3", errors);

        // Group 4: BUF_SIZE (16-bit)
        check_reg_16(5'h14, 16'h0100, "buf_size_reg_0", errors);
        check_reg_16(5'h15, 16'h0080, "buf_size_reg_1", errors);
        check_reg_16(5'h16, 16'h0040, "buf_size_reg_2", errors);
        check_reg_16(5'h17, 16'h0020, "buf_size_reg_3", errors);

        // Group 5: PRIORITY (24-bit)
        check_reg_24(5'h18, 24'hABCDEF, "priority_ctrl_reg", errors);

        // Group 6: control (8-bit)
        check_reg_8(reg_model.request_reg, 8'h0F, "request_reg", errors);
        // NOTE: mode_reg uses ch_sel=0 (0x84) so readback from
        //       MODE_REG[0] matches what was written.
        check_reg_8(reg_model.mode_reg,    8'h84, "mode_reg",    errors);

        // Group 7: read-only registers (existence check)
        begin
            uvm_status_e   status;
            uvm_reg_data_t rdata;
            reg_model.status_reg.read(status, rdata);
            if (status != UVM_IS_OK) begin
                `uvm_error("REG_TEST", "status_reg read failed"); errors++;
            end
            reg_model.ext_status_reg.read(status, rdata);
            if (status != UVM_IS_OK) begin
                `uvm_error("REG_TEST", "ext_status_reg read failed"); errors++;
            end
        end

        do_master_clear();

        if (errors == 0)
            `uvm_info("REG_TEST", "*** REGISTER TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("REG_TEST",
                $sformatf("*** REGISTER TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_reg_test");
        phase.drop_objection(this, "Register test complete");
    endtask

    //--------------------------------------------------------
    // Helpers — check 8/16/24-bit registers
    //--------------------------------------------------------
    task check_reg_8(uvm_reg reg_h, bit [7:0] value, string name, ref int errors);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        reg_h.write(status, value);
        if (status != UVM_IS_OK) begin
            `uvm_error("REG_TEST", $sformatf("%s write failed", name))
            errors = errors + 1; return;
        end
        reg_h.read(status, rdata);
        if (status != UVM_IS_OK || rdata[7:0] !== value) begin
            `uvm_error("REG_TEST",
                $sformatf("%s: exp=0x%02X obs=0x%02X", name, value, rdata[7:0]))
            errors = errors + 1; return;
        end
        `uvm_info("REG_TEST",
            $sformatf("  -> PASS: %s = 0x%02X", name, value), UVM_LOW)
    endtask

    task check_reg_16(bit [4:0] addr, bit [15:0] value, string name, ref int errors);
        bit [15:0] observed;
        write_16bit(addr, value);
        read_16bit (addr, observed);
        if (observed !== value) begin
            `uvm_error("REG_TEST",
                $sformatf("%s: exp=0x%04X obs=0x%04X", name, value, observed))
            errors = errors + 1; return;
        end
        `uvm_info("REG_TEST",
            $sformatf("  -> PASS: %s = 0x%04X", name, value), UVM_LOW)
    endtask

    task check_reg_24(bit [4:0] addr, bit [23:0] value, string name, ref int errors);
        bit [23:0] observed;
        write_24bit(addr, value);
        read_24bit (addr, observed);
        if (observed !== value) begin
            `uvm_error("REG_TEST",
                $sformatf("%s: exp=0x%06X obs=0x%06X", name, value, observed))
            errors = errors + 1; return;
        end
        `uvm_info("REG_TEST",
            $sformatf("  -> PASS: %s = 0x%06X", name, value), UVM_LOW)
    endtask

    //--------------------------------------------------------
    // Helpers — direct bus access
    //--------------------------------------------------------
    protected task send_bus_item(cpu_seq_item item);
        cpu_single_item_seq seq;
        seq = cpu_single_item_seq::type_id::create("single_seq");
        seq.item = item;
        seq.start(env.cpu_agt.sequencer);
    endtask

    protected task write_16bit(bit [4:0] addr, bit [15:0] data);
        cpu_seq_item item;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_lo");
        item.is_read = 1'b0; item.addr = addr; item.data = data[7:0];
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_hi");
        item.is_read = 1'b0; item.addr = addr; item.data = data[15:8];
        send_bus_item(item);
    endtask

    protected task read_16bit(bit [4:0] addr, output bit [15:0] data);
        cpu_seq_item item; bit [7:0] lo, hi;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("r_lo");
        item.is_read = 1'b1; item.addr = addr; send_bus_item(item); lo = item.data;
        item = cpu_seq_item::type_id::create("r_hi");
        item.is_read = 1'b1; item.addr = addr; send_bus_item(item); hi = item.data;
        data = {hi, lo};
    endtask

    protected task write_24bit(bit [4:0] addr, bit [23:0] data);
        cpu_seq_item item;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_b0");
        item.is_read = 1'b0; item.addr = addr; item.data = data[7:0];
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_b1");
        item.is_read = 1'b0; item.addr = addr; item.data = data[15:8];
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("w_b2");
        item.is_read = 1'b0; item.addr = addr; item.data = data[23:16];
        send_bus_item(item);
    endtask

    protected task read_24bit(bit [4:0] addr, output bit [23:0] data);
        cpu_seq_item item; bit [7:0] b0, b1, b2;
        item = cpu_seq_item::type_id::create("bp");
        item.is_read = 1'b0; item.addr = 5'h0C; item.data = 8'h00;
        send_bus_item(item);
        item = cpu_seq_item::type_id::create("r_b0");
        item.is_read = 1'b1; item.addr = addr; send_bus_item(item); b0 = item.data;
        item = cpu_seq_item::type_id::create("r_b1");
        item.is_read = 1'b1; item.addr = addr; send_bus_item(item); b1 = item.data;
        item = cpu_seq_item::type_id::create("r_b2");
        item.is_read = 1'b1; item.addr = addr; send_bus_item(item); b2 = item.data;
        data = {b2, b1, b0};
    endtask

endclass


//============================================================
// SECTION 7: DMA READ CONFIGURATION TEST
//============================================================
// Configures each channel for DMA read transfer.
//------------------------------------------------------------
class dma_dma_read_test extends dma_base_test;

    `uvm_component_utils(dma_dma_read_test)
    dma_dma_read_seq seq;

    function new(string name = "dma_dma_read_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "DMA read test running");
        wait_for_reset();
        do_master_clear();

        for (int ch = 0; ch < 4; ch++) begin
            seq = dma_dma_read_seq::type_id::create($sformatf("seq_ch%0d", ch));
            if (!seq.randomize() with {
                channel    == ch;
                base_addr  == (16'h1000 + ch * 16'h1000);
                word_count == 16'h0010;
            }) begin
                `uvm_error("DMA_READ_TEST",
                    $sformatf("Randomization failed for CH%0d", ch))
            end
            seq.start(env.cpu_agt.sequencer);
        end

        report_test_status("dma_dma_read_test");
        phase.drop_objection(this, "DMA read test complete");
    endtask

endclass


//============================================================
// SECTION 8: DMA WRITE CONFIGURATION TEST
//============================================================
class dma_dma_write_test extends dma_base_test;

    `uvm_component_utils(dma_dma_write_test)
    dma_dma_write_seq seq;

    function new(string name = "dma_dma_write_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "DMA write test running");
        wait_for_reset();
        do_master_clear();

        for (int ch = 0; ch < 4; ch++) begin
            seq = dma_dma_write_seq::type_id::create($sformatf("seq_ch%0d", ch));
            if (!seq.randomize() with {
                channel    == ch;
                base_addr  == (16'h2000 + ch * 16'h1000);
                word_count == 16'h0020;
            }) begin
                `uvm_error("DMA_WRITE_TEST",
                    $sformatf("Randomization failed for CH%0d", ch))
            end
            seq.start(env.cpu_agt.sequencer);
        end

        report_test_status("dma_dma_write_test");
        phase.drop_objection(this, "DMA write test complete");
    endtask

endclass


//============================================================
// SECTION 9: PRIORITY TEST
//============================================================
// Exercises all 4 arbitration modes: fixed, rotating,
// adaptive, weighted, aging, RR.
//------------------------------------------------------------
class dma_priority_test extends dma_base_test;

    `uvm_component_utils(dma_priority_test)

    function new(string name = "dma_priority_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task read_priority_ctrl(output bit [23:0] data);
        data = reg_model.priority_ctrl_reg.get();
    endtask

    virtual task run_phase(uvm_phase phase);
        uvm_status_e   status;
        bit [23:0]     val24;
        int            errors = 0;

        phase.raise_objection(this, "Priority test running");
        wait_for_reset();
        do_master_clear();

        `uvm_info("PRIO_TEST", "=========== DMA PRIORITY TEST STARTING ===========", UVM_LOW)

        // Test 1: Fixed priority (COMMAND[4]=0)
        reg_model.command_reg.write(status, 8'h01);
        if (reg_model.command_reg.get()[4] !== 1'b0) begin
            `uvm_error("PRIO_TEST",
                $sformatf("Fixed priority: exp=0 obs=%0d",
                          reg_model.command_reg.get()[4]))
            errors++;
        end else
            `uvm_info("PRIO_TEST", "  -> PASS: Fixed priority configured", UVM_LOW)

        // Test 2: Rotating priority (COMMAND[4]=1)
        reg_model.command_reg.write(status, 8'h11);
        if (reg_model.command_reg.get()[4] !== 1'b1) begin
            `uvm_error("PRIO_TEST",
                $sformatf("Rotating priority mirror: exp=1 obs=%0d",
                          reg_model.command_reg.get()[4]))
            errors++;
        end else
            `uvm_info("PRIO_TEST", "  -> PASS: Rotating priority configured", UVM_LOW)

        // Test 3: Adaptive mode (PRIORITY_CTRL[16]=1)
        write_24bit_via_bus(5'h18, 24'h010000);
        read_priority_ctrl(val24);
        if (val24[16] !== 1'b1) begin
            `uvm_error("PRIO_TEST",
                $sformatf("Adaptive bit: exp=1 obs=%0d", val24[16]))
            errors++;
        end else
            `uvm_info("PRIO_TEST", "  -> PASS: Adaptive mode enabled", UVM_LOW)

        // Test 4: Weighted arbitration (arb_mode=2'b10)
        write_24bit_via_bus(5'h18, 24'h058F55);
        read_priority_ctrl(val24);
        if (val24[18:17] !== 2'b10) begin
            `uvm_error("PRIO_TEST",
                $sformatf("Weighted arb_mode: exp=2'b10 obs=%02b", val24[18:17]))
            errors++;
        end else
            `uvm_info("PRIO_TEST", "  -> PASS: Weighted mode configured", UVM_LOW)

        // Test 5: Aging (aging_en=1, threshold=5)
        write_24bit_via_bus(5'h18, 24'h588855);
        read_priority_ctrl(val24);
        if (val24[19] !== 1'b1 || val24[23:20] !== 4'h5) begin
            `uvm_error("PRIO_TEST",
                $sformatf("Aging: exp en=1,thr=5 obs en=%0d,thr=0x%X",
                          val24[19], val24[23:20]))
            errors++;
        end else
            `uvm_info("PRIO_TEST", "  -> PASS: Aging configured", UVM_LOW)

        // Test 6: Round-robin (arb_mode=2'b01)
        write_24bit_via_bus(5'h18, 24'h032001);
        read_priority_ctrl(val24);
        if (val24[18:17] !== 2'b01) begin
            `uvm_error("PRIO_TEST",
                $sformatf("RR arb_mode: exp=2'b01 obs=%02b", val24[18:17]))
            errors++;
        end else
            `uvm_info("PRIO_TEST", "  -> PASS: RR mode configured", UVM_LOW)

        do_master_clear();

        if (errors == 0)
            `uvm_info("PRIO_TEST", "*** PRIORITY TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("PRIO_TEST",
                $sformatf("*** PRIORITY TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_priority_test");
        phase.drop_objection(this, "Priority test complete");
    endtask

    task write_byte_via_bus(bit [4:0] a, bit [7:0] d);
        cpu_single_item_seq seq;
        seq = cpu_single_item_seq::type_id::create("seq");
        seq.is_read = 1'b0;
        seq.addr    = a;
        seq.data    = d;
        seq.start(env.cpu_agt.sequencer);
    endtask

    task write_24bit_via_bus(bit [4:0] addr, bit [23:0] data);
        write_byte_via_bus(5'h0C, 8'h00);
        write_byte_via_bus(addr, data[7:0]);
        write_byte_via_bus(addr, data[15:8]);
        write_byte_via_bus(addr, data[23:16]);
    endtask

endclass


//============================================================
// SECTION 10: CIRCULAR BUFFER TEST
//============================================================
class dma_circular_test extends dma_base_test;

    `uvm_component_utils(dma_circular_test)

    function new(string name = "dma_circular_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        int            errors = 0;

        phase.raise_objection(this, "Circular test running");
        wait_for_reset();
        do_master_clear();

        `uvm_info("CIRC_TEST", "=========== DMA CIRCULAR BUFFER TEST ===========", UVM_LOW)

        // Test 1: CH0 circular mode config
        reg_model.ch_ctrl_reg_0.write(status, 8'h87);
        reg_model.ch_ctrl_reg_0.read(status, rdata);
        if (status != UVM_IS_OK || rdata[7:0] !== 8'h87) begin
            `uvm_error("CIRC_TEST",
                $sformatf("ch_ctrl_reg_0: exp=0x87 obs=0x%02X", rdata[7:0]))
            errors++;
        end else
            `uvm_info("CIRC_TEST", "  -> PASS: CH_CTRL_REG_0 = 0x87", UVM_LOW)

        // Test 2: CH0 buffer size
        reg_model.buf_size_reg_0.write(status, 16'h0100);
        reg_model.buf_size_reg_0.read(status, rdata);
        if (status != UVM_IS_OK || rdata[15:0] !== 16'h0100) begin
            `uvm_error("CIRC_TEST",
                $sformatf("buf_size_reg_0: exp=0x0100 obs=0x%04X", rdata[15:0]))
            errors++;
        end else
            `uvm_info("CIRC_TEST", "  -> PASS: BUF_SIZE_REG_0 = 0x0100", UVM_LOW)

        // Test 3: CH0 base address
        reg_model.base_addr_ch0.write(status, 16'h1000);
        reg_model.base_addr_ch0.read(status, rdata);
        if (status != UVM_IS_OK || rdata[15:0] !== 16'h1000) begin
            `uvm_error("CIRC_TEST",
                $sformatf("base_addr_ch0: exp=0x1000 obs=0x%04X", rdata[15:0]))
            errors++;
        end else
            `uvm_info("CIRC_TEST", "  -> PASS: BASE_ADDR_CH0 = 0x1000", UVM_LOW)

        // Test 4: EXT_STATUS_REG read
        reg_model.ext_status_reg.read(status, rdata);
        if (status != UVM_IS_OK) begin
            `uvm_error("CIRC_TEST", "ext_status_reg read failed"); errors++;
        end

        // Test 5: Configure CH1-CH3
        reg_model.ch_ctrl_reg_1.write(status, 8'h87);
        reg_model.ch_ctrl_reg_2.write(status, 8'h87);
        reg_model.ch_ctrl_reg_3.write(status, 8'h87);
        reg_model.buf_size_reg_1.write(status, 16'h0080);
        reg_model.buf_size_reg_2.write(status, 16'h0040);
        reg_model.buf_size_reg_3.write(status, 16'h0020);

        // Test 6: Master clear recovery
        do_master_clear();
        reg_model.ext_status_reg.read(status, rdata);
        if (status == UVM_IS_OK && rdata[7:0] == 8'h00)
            `uvm_info("CIRC_TEST", "  -> PASS: ext_status cleared by MC", UVM_LOW)
        else begin
            `uvm_error("CIRC_TEST",
                $sformatf("ext_status not cleared: 0x%02X", rdata[7:0]))
            errors++;
        end

        if (errors == 0)
            `uvm_info("CIRC_TEST", "*** CIRCULAR TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("CIRC_TEST",
                $sformatf("*** CIRCULAR TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_circular_test");
        phase.drop_objection(this, "Circular test complete");
    endtask

endclass


//============================================================
// SECTION 11: ERROR HANDLING TEST
//============================================================
class dma_error_test extends dma_base_test;

    `uvm_component_utils(dma_error_test)

    function new(string name = "dma_error_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        int            errors = 0;

        phase.raise_objection(this, "Error test running");
        wait_for_reset();
        do_master_clear();

        `uvm_info("ERR_TEST", "=========== DMA ERROR HANDLING TEST ===========", UVM_LOW)

        // Test 1: EXT_STATUS_REG starts clean
        reg_model.ext_status_reg.read(status, rdata);
        if (status != UVM_IS_OK || rdata[7:0] !== 8'h00) begin
            `uvm_error("ERR_TEST",
                $sformatf("ext_status not clean: 0x%02X", rdata[7:0]))
            errors++;
        end else
            `uvm_info("ERR_TEST", "  -> PASS: EXT_STATUS_REG = 0x00", UVM_LOW)

        // Test 2: MASK write/clear
        reg_model.write_mask_reg.write(status, 8'h0F);
        if (status != UVM_IS_OK) begin
            `uvm_error("ERR_TEST", "write_mask_reg write failed"); errors++;
        end
        reg_model.clear_mask.write(status, 8'h00);
        if (status != UVM_IS_OK) begin
            `uvm_error("ERR_TEST", "clear_mask write failed"); errors++;
        end else
            `uvm_info("ERR_TEST", "  -> PASS: MASK written and cleared", UVM_LOW)

        // Test 3: COMMAND_REG mirror update
        reg_model.command_reg.write(status, 8'h85);
        if (reg_model.command_reg.get() !== 8'h85) begin
            `uvm_error("ERR_TEST",
                $sformatf("command_reg mirror: exp=0x85 obs=0x%02X",
                          reg_model.command_reg.get()))
            errors++;
        end else
            `uvm_info("ERR_TEST", "  -> PASS: COMMAND_REG mirror = 0x85", UVM_LOW)

        // Test 4: Master clear recovery
        reg_model.ch_ctrl_reg_0.write(status, 8'hFF);
        do_master_clear();
        reg_model.ch_ctrl_reg_0.read(status, rdata);
        if (status != UVM_IS_OK || rdata[7:0] !== 8'h00) begin
            `uvm_error("ERR_TEST",
                $sformatf("ch_ctrl_reg_0 not cleared: 0x%02X", rdata[7:0]))
            errors++;
        end else
            `uvm_info("ERR_TEST", "  -> PASS: CH_CTRL_REG_0 cleared by MC", UVM_LOW)

        // Test 5: PRIORITY_CTRL cleared by MC
        reg_model.priority_ctrl_reg.write(status, 24'hFFFFFF);
        do_master_clear();
        reg_model.priority_ctrl_reg.read(status, rdata);
        if (status != UVM_IS_OK || rdata[23:0] !== 24'h000000) begin
            `uvm_error("ERR_TEST",
                $sformatf("priority_ctrl not cleared: 0x%06X", rdata[23:0]))
            errors++;
        end else
            `uvm_info("ERR_TEST", "  -> PASS: PRIORITY_CTRL cleared", UVM_LOW)

        if (errors == 0)
            `uvm_info("ERR_TEST", "*** ERROR TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("ERR_TEST",
                $sformatf("*** ERROR TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_error_test");
        phase.drop_objection(this, "Error test complete");
    endtask

endclass


//============================================================
// SECTION 12: RANDOM REGISTER CONFIGURATION TEST
//============================================================
class dma_random_register_configuration_test extends dma_base_test;

    `uvm_component_utils(dma_random_register_configuration_test)
    dma_random_reg_cfg_seq seq;

    function new(string name = "dma_random_register_configuration_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Random reg config test running");
        wait_for_reset();
        do_master_clear();

        seq = dma_random_reg_cfg_seq::type_id::create("seq");
        if (!seq.randomize() with { num_ops inside {[30:80]}; })
            `uvm_error("RAND_REG_CFG_TEST", "Randomization failed")
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_random_register_configuration_test");
        phase.drop_objection(this, "Random reg config test complete");
    endtask

endclass


//============================================================
// SECTION 13: MIXED PROGRAMMING TEST
//============================================================
class dma_mixed_programming_test extends dma_base_test;

    `uvm_component_utils(dma_mixed_programming_test)
    dma_mixed_programming_seq seq;

    function new(string name = "dma_mixed_programming_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Mixed programming test running");
        wait_for_reset();
        do_master_clear();

        seq = dma_mixed_programming_seq::type_id::create("seq");
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_mixed_programming_test");
        phase.drop_objection(this, "Mixed programming test complete");
    endtask

endclass


//============================================================
// SECTION 14: BACK-TO-BACK DMA TEST
//============================================================
class dma_back_to_back_dma_test extends dma_base_test;

    `uvm_component_utils(dma_back_to_back_dma_test)
    dma_back_to_back_seq seq;

    function new(string name = "dma_back_to_back_dma_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Back-to-back test running");
        wait_for_reset();
        do_master_clear();

        seq = dma_back_to_back_seq::type_id::create("seq");
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_back_to_back_dma_test");
        phase.drop_objection(this, "Back-to-back test complete");
    endtask

endclass


//============================================================
// SECTION 15: CHANNEL CONFIGURATION TEST
//============================================================
class dma_channel_configuration_test extends dma_base_test;

    `uvm_component_utils(dma_channel_configuration_test)
    dma_channel_config_seq seq;

    function new(string name = "dma_channel_configuration_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Channel config test running");
        wait_for_reset();
        do_master_clear();

        seq = dma_channel_config_seq::type_id::create("seq");
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_channel_configuration_test");
        phase.drop_objection(this, "Channel config test complete");
    endtask

endclass


//============================================================
// SECTION 16: RANDOM REGISTER TEST (RAL)
//============================================================
// Plusarg NUM_OPS overrides the default op count.
//------------------------------------------------------------
class dma_random_test extends dma_base_test;

    `uvm_component_utils(dma_random_test)
    dma_random_reg_seq seq;
    int unsigned       num_ops = 50;

    function new(string name = "dma_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Random test running");

        void'($value$plusargs("NUM_OPS=%d", num_ops));

        wait_for_reset();
        do_master_clear();

        seq = dma_random_reg_seq::type_id::create("seq");
        seq.num_ops = num_ops;
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_random_test");
        phase.drop_objection(this, "Random test complete");
    endtask

endclass


//============================================================
// SECTION 17: RANDOM REGRESSION TEST
//============================================================
class dma_random_regression_test extends dma_base_test;

    `uvm_component_utils(dma_random_regression_test)
    dma_random_regression_seq seq;
    int unsigned              num_iters = 100;

    function new(string name = "dma_random_regression_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Random regression test running");

        void'($value$plusargs("NUM_ITERS=%d", num_iters));

        wait_for_reset();
        do_master_clear();

        seq = dma_random_regression_seq::type_id::create("seq");
        seq.num_iterations = num_iters;
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_random_regression_test");
        phase.drop_objection(this, "Random regression test complete");
    endtask

endclass


//============================================================
// SECTION 18: STRESS TEST
//============================================================
// Plusargs NUM_ITERS and MC_INTERVAL override defaults.
//------------------------------------------------------------
class dma_stress_test extends dma_base_test;

    `uvm_component_utils(dma_stress_test)
    dma_stress_seq seq;
    int unsigned   num_iters   = 200;
    int unsigned   mc_interval = 50;

    function new(string name = "dma_stress_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "Stress test running");

        void'($value$plusargs("NUM_ITERS=%d", num_iters));
        void'($value$plusargs("MC_INTERVAL=%d", mc_interval));

        wait_for_reset();
        do_master_clear();

        seq = dma_stress_seq::type_id::create("seq");
        seq.num_iterations = num_iters;
        seq.mc_interval    = mc_interval;
        seq.start(env.cpu_agt.sequencer);

        report_test_status("dma_stress_test");
        phase.drop_objection(this, "Stress test complete");
    endtask

endclass


//============================================================
// SECTION 19: RESET TEST
//============================================================
// Verifies all registers reset to 0 after reset deassertion.
// Checks byte pointers FIRST (before perturbing them with reads).
//------------------------------------------------------------
class dma_reset_test extends dma_base_test;

    `uvm_component_utils(dma_reset_test)

    function new(string name = "dma_reset_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int errors = 0;

        phase.raise_objection(this, "Reset test running");

        `uvm_info("RESET_TEST", "=========== DMA RESET TEST ===========", UVM_LOW)

        wait_for_reset();
        repeat (5) @(posedge vif.CLK);

        // Check byte pointers FIRST
        if (vif.byte_pointer === 1'b0)
            `uvm_info("RESET_TEST", "  -> PASS: byte_pointer = 0", UVM_LOW)
        else begin
            `uvm_error("RESET_TEST",
                $sformatf("byte_pointer not reset: %b", vif.byte_pointer))
            errors++;
        end

        if (vif.priority_byte_ptr === 2'b00)
            `uvm_info("RESET_TEST", "  -> PASS: priority_byte_ptr = 0", UVM_LOW)
        else begin
            `uvm_error("RESET_TEST",
                $sformatf("priority_byte_ptr not reset: %b", vif.priority_byte_ptr))
            errors++;
        end

        // COMMAND_REG via mirror (write-only in RAL)
        if (reg_model.command_reg.get() == 8'h00)
            `uvm_info("RESET_TEST", "  -> PASS: COMMAND_REG = 0x00", UVM_LOW)
        else begin
            `uvm_error("RESET_TEST",
                $sformatf("COMMAND_REG mirror not reset: 0x%02X",
                          reg_model.command_reg.get()))
            errors++;
        end

        // All 8-bit control regs
        check_reg_8(reg_model.request_reg, 8'h00, "REQUEST_REG", errors);
        check_reg_8(reg_model.mask_reg,    8'h00, "MASK_REG",    errors);
        check_reg_8(reg_model.mode_reg,    8'h00, "MODE_REG",    errors);

        // Channel base + WC (16-bit)
        check_reg_16(reg_model.base_addr_ch0, 16'h0000, "BASE_ADDR_CH0", errors);
        check_reg_16(reg_model.base_addr_ch1, 16'h0000, "BASE_ADDR_CH1", errors);
        check_reg_16(reg_model.base_addr_ch2, 16'h0000, "BASE_ADDR_CH2", errors);
        check_reg_16(reg_model.base_addr_ch3, 16'h0000, "BASE_ADDR_CH3", errors);
        check_reg_16(reg_model.base_wc_ch0,   16'h0000, "BASE_WC_CH0", errors);
        check_reg_16(reg_model.base_wc_ch1,   16'h0000, "BASE_WC_CH1", errors);
        check_reg_16(reg_model.base_wc_ch2,   16'h0000, "BASE_WC_CH2", errors);
        check_reg_16(reg_model.base_wc_ch3,   16'h0000, "BASE_WC_CH3", errors);

        // CH_CTRL (8-bit)
        check_reg_8(reg_model.ch_ctrl_reg_0, 8'h00, "CH_CTRL_REG_0", errors);
        check_reg_8(reg_model.ch_ctrl_reg_1, 8'h00, "CH_CTRL_REG_1", errors);
        check_reg_8(reg_model.ch_ctrl_reg_2, 8'h00, "CH_CTRL_REG_2", errors);
        check_reg_8(reg_model.ch_ctrl_reg_3, 8'h00, "CH_CTRL_REG_3", errors);

        // BUF_SIZE (16-bit)
        check_reg_16(reg_model.buf_size_reg_0, 16'h0000, "BUF_SIZE_REG_0", errors);
        check_reg_16(reg_model.buf_size_reg_1, 16'h0000, "BUF_SIZE_REG_1", errors);
        check_reg_16(reg_model.buf_size_reg_2, 16'h0000, "BUF_SIZE_REG_2", errors);
        check_reg_16(reg_model.buf_size_reg_3, 16'h0000, "BUF_SIZE_REG_3", errors);

        // PRIORITY (24-bit)
        check_reg_24(reg_model.priority_ctrl_reg, 24'h000000, "PRIORITY_CTRL_REG", errors);

        // Read-only status
        check_reg_8(reg_model.status_reg,     8'h00, "STATUS_REG",     errors);
        check_reg_8(reg_model.ext_status_reg, 8'h00, "EXT_STATUS_REG", errors);

        if (errors == 0)
            `uvm_info("RESET_TEST", "*** RESET TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("RESET_TEST",
                $sformatf("*** RESET TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_reset_test");
        phase.drop_objection(this, "Reset test complete");
    endtask

    // Check helpers via RAL
    task check_reg_8(uvm_reg reg_h, bit [7:0] expected, string name, ref int errors);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        reg_h.read(status, rdata);
        if (status != UVM_IS_OK || rdata[7:0] !== expected) begin
            `uvm_error("RESET_TEST",
                $sformatf("%s: exp=0x%02X obs=0x%02X", name, expected, rdata[7:0]))
            errors = errors + 1; return;
        end
        `uvm_info("RESET_TEST",
            $sformatf("  -> PASS: %s = 0x%02X", name, expected), UVM_LOW)
    endtask

    task check_reg_16(uvm_reg reg_h, bit [15:0] expected, string name, ref int errors);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        reg_h.read(status, rdata);
        if (status != UVM_IS_OK || rdata[15:0] !== expected) begin
            `uvm_error("RESET_TEST",
                $sformatf("%s: exp=0x%04X obs=0x%04X", name, expected, rdata[15:0]))
            errors = errors + 1; return;
        end
        `uvm_info("RESET_TEST",
            $sformatf("  -> PASS: %s = 0x%04X", name, expected), UVM_LOW)
    endtask

    task check_reg_24(uvm_reg reg_h, bit [23:0] expected, string name, ref int errors);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        reg_h.read(status, rdata);
        if (status != UVM_IS_OK || rdata[23:0] !== expected) begin
            `uvm_error("RESET_TEST",
                $sformatf("%s: exp=0x%06X obs=0x%06X", name, expected, rdata[23:0]))
            errors = errors + 1; return;
        end
        `uvm_info("RESET_TEST",
            $sformatf("  -> PASS: %s = 0x%06X", name, expected), UVM_LOW)
    endtask

endclass


//============================================================
// SECTION 20: BYTE POINTER TEST
//============================================================
// Verifies byte_pointer toggling on 16-bit access and
// priority_byte_ptr cycling on 24-bit access.
//------------------------------------------------------------
class dma_byte_pointer_test extends dma_base_test;

    `uvm_component_utils(dma_byte_pointer_test)

    function new(string name = "dma_byte_pointer_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int errors = 0;

        phase.raise_objection(this, "Byte pointer test running");
        wait_for_reset();
        do_master_clear();

        `uvm_info("BP_TEST", "=========== BYTE POINTER TEST ===========", UVM_LOW)

        // Test 1: CLEAR_BYTE_PTR resets byte_pointer
        send_write(5'h0C, 8'h00);
        if (vif.byte_pointer == 1'b0)
            `uvm_info("BP_TEST", "  -> PASS: byte_pointer = 0 after CLEAR", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("byte_pointer not cleared: %0d", vif.byte_pointer))
            errors++;
        end

        // Test 2: 16-bit write toggles byte_pointer
        send_write(5'h00, 8'hAA);
        if (vif.byte_pointer == 1'b1)
            `uvm_info("BP_TEST", "  -> PASS: byte_pointer toggled to 1", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("byte_pointer not toggled: %0d", vif.byte_pointer))
            errors++;
        end

        send_write(5'h00, 8'hBB);
        if (vif.byte_pointer == 1'b0)
            `uvm_info("BP_TEST", "  -> PASS: byte_pointer toggled back", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("byte_pointer not toggled back: %0d", vif.byte_pointer))
            errors++;
        end

        // Test 3: 16-bit read toggles byte_pointer
        send_write(5'h0C, 8'h00);
        send_read(5'h00);
        if (vif.byte_pointer == 1'b1)
            `uvm_info("BP_TEST", "  -> PASS: byte_pointer = 1 after read", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("byte_pointer not toggled on read: %0d", vif.byte_pointer))
            errors++;
        end

        // Test 4: 24-bit write cycles priority_byte_ptr 0→1→2→0
        send_write(5'h0C, 8'h00);
        if (vif.priority_byte_ptr == 2'b00)
            `uvm_info("BP_TEST", "  -> PASS: priority_byte_ptr = 0", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("priority_byte_ptr not cleared: %0d", vif.priority_byte_ptr))
            errors++;
        end

        send_write(5'h18, 8'hAA);
        if (vif.priority_byte_ptr == 2'b01)
            `uvm_info("BP_TEST", "  -> PASS: priority_byte_ptr = 1", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("priority_byte_ptr not advanced: %0d", vif.priority_byte_ptr))
            errors++;
        end

        send_write(5'h18, 8'hBB);
        if (vif.priority_byte_ptr == 2'b10)
            `uvm_info("BP_TEST", "  -> PASS: priority_byte_ptr = 2", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("priority_byte_ptr not advanced: %0d", vif.priority_byte_ptr))
            errors++;
        end

        send_write(5'h18, 8'hCC);
        if (vif.priority_byte_ptr == 2'b00)
            `uvm_info("BP_TEST", "  -> PASS: priority_byte_ptr wrapped", UVM_LOW)
        else begin
            `uvm_error("BP_TEST",
                $sformatf("priority_byte_ptr not wrapped: %0d", vif.priority_byte_ptr))
            errors++;
        end

        // Test 5: 16-bit access isolated from priority_byte_ptr
        send_write(5'h0C, 8'h00);
        begin
            bit [1:0] prio_before = vif.priority_byte_ptr;
            send_write(5'h00, 8'h11);
            if (vif.priority_byte_ptr == prio_before)
                `uvm_info("BP_TEST",
                    "  -> PASS: priority_byte_ptr unaffected by 16-bit", UVM_LOW)
            else begin
                `uvm_error("BP_TEST",
                    $sformatf("priority_byte_ptr changed: %0d -> %0d",
                              prio_before, vif.priority_byte_ptr))
                errors++;
            end
        end

        // Test 6: 24-bit access isolated from byte_pointer
        send_write(5'h0C, 8'h00);
        begin
            bit bp_before = vif.byte_pointer;
            send_write(5'h18, 8'h22);
            if (vif.byte_pointer == bp_before)
                `uvm_info("BP_TEST",
                    "  -> PASS: byte_pointer unaffected by 24-bit", UVM_LOW)
            else begin
                `uvm_error("BP_TEST",
                    $sformatf("byte_pointer changed: %0d -> %0d",
                              bp_before, vif.byte_pointer))
                errors++;
            end
        end

        do_master_clear();

        if (errors == 0)
            `uvm_info("BP_TEST", "*** BYTE POINTER TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("BP_TEST",
                $sformatf("*** BYTE POINTER TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_byte_pointer_test");
        phase.drop_objection(this, "Byte pointer test complete");
    endtask

    // Send one byte write, then wait 3 clocks for pointer logic to settle
    task send_write(bit [4:0] addr, bit [7:0] data);
        cpu_single_item_seq seq;
        seq = cpu_single_item_seq::type_id::create("seq");
        seq.is_read = 1'b0;
        seq.addr    = addr;
        seq.data    = data;
        seq.start(env.cpu_agt.sequencer);
        repeat (3) @(posedge vif.CLK);
    endtask

    // Send one byte read (data not captured — only toggles pointer)
    task send_read(bit [4:0] addr);
        cpu_single_item_seq seq;
        seq = cpu_single_item_seq::type_id::create("seq");
        seq.is_read = 1'b1;
        seq.addr    = addr;
        seq.start(env.cpu_agt.sequencer);
        repeat (3) @(posedge vif.CLK);
    endtask

endclass


//============================================================
// SECTION 21: MASTER CLEAR TEST
//============================================================
// Preloads all registers, issues MC, then verifies:
//   - CLEARED registers (control) → 0
//   - RETAINED registers (base addr/WC) → unchanged
//------------------------------------------------------------
class dma_master_clear_test extends dma_base_test;

    `uvm_component_utils(dma_master_clear_test)

    function new(string name = "dma_master_clear_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int errors = 0;

        phase.raise_objection(this, "Master clear test running");
        wait_for_reset();

        `uvm_info("MC_TEST", "=========== MASTER CLEAR TEST ===========", UVM_LOW)

        preload_registers();

        send_write(5'h0D, 8'h00);   // MASTER_CLEAR
        repeat (10) @(posedge vif.CLK);

        `uvm_info("MC_TEST", "Verifying CLEARED registers = 0", UVM_LOW)
        check_cleared(errors);

        `uvm_info("MC_TEST", "Verifying RETAINED registers unchanged", UVM_LOW)
        check_retained(errors);

        if (errors == 0)
            `uvm_info("MC_TEST", "*** MASTER CLEAR TEST PASSED ***", UVM_LOW)
        else
            `uvm_error("MC_TEST",
                $sformatf("*** MASTER CLEAR TEST FAILED (%0d errors) ***", errors))

        report_test_status("dma_master_clear_test");
        phase.drop_objection(this, "Master clear test complete");
    endtask

    // Preload all registers with non-zero values
    task preload_registers();
        uvm_status_e status;
        reg_model.command_reg.write(status, 8'h85);
        reg_model.request_reg.write(status, 8'h0F);
        reg_model.mask_reg.write(status, 8'h0F);
        reg_model.mode_reg.write(status, 8'hC4);

        reg_model.base_addr_ch0.write(status, 16'h1000);
        reg_model.base_addr_ch1.write(status, 16'h2000);
        reg_model.base_addr_ch2.write(status, 16'h3000);
        reg_model.base_addr_ch3.write(status, 16'h4000);
        reg_model.base_wc_ch0.write(status, 16'h0010);
        reg_model.base_wc_ch1.write(status, 16'h0020);
        reg_model.base_wc_ch2.write(status, 16'h0030);
        reg_model.base_wc_ch3.write(status, 16'h0040);

        reg_model.ch_ctrl_reg_0.write(status, 8'h87);
        reg_model.ch_ctrl_reg_1.write(status, 8'h47);
        reg_model.ch_ctrl_reg_2.write(status, 8'h83);
        reg_model.ch_ctrl_reg_3.write(status, 8'h01);

        reg_model.buf_size_reg_0.write(status, 16'h0100);
        reg_model.buf_size_reg_1.write(status, 16'h0080);
        reg_model.buf_size_reg_2.write(status, 16'h0040);
        reg_model.buf_size_reg_3.write(status, 16'h0020);

        reg_model.priority_ctrl_reg.write(status, 24'h5D5555);
    endtask

    // Verify CLEARED registers are 0
    task check_cleared(ref int errors);
        if (reg_model.command_reg.get() == 8'h00)
            `uvm_info("MC_TEST", "  -> PASS: COMMAND_REG = 0x00 (mirror)", UVM_LOW)
        else begin
            `uvm_error("MC_TEST",
                $sformatf("COMMAND_REG mirror not cleared: 0x%02X",
                          reg_model.command_reg.get()))
            errors = errors + 1;
        end

        check_reg_8(reg_model.request_reg,    8'h00, "REQUEST_REG", errors);
        check_reg_8(reg_model.mask_reg,       8'h00, "MASK_REG",    errors);
        check_reg_8(reg_model.mode_reg,       8'h00, "MODE_REG",    errors);

        check_reg_8(reg_model.ch_ctrl_reg_0, 8'h00, "CH_CTRL_REG_0", errors);
        check_reg_8(reg_model.ch_ctrl_reg_1, 8'h00, "CH_CTRL_REG_1", errors);
        check_reg_8(reg_model.ch_ctrl_reg_2, 8'h00, "CH_CTRL_REG_2", errors);
        check_reg_8(reg_model.ch_ctrl_reg_3, 8'h00, "CH_CTRL_REG_3", errors);

        check_reg_16(reg_model.buf_size_reg_0, 16'h0000, "BUF_SIZE_REG_0", errors);
        check_reg_16(reg_model.buf_size_reg_1, 16'h0000, "BUF_SIZE_REG_1", errors);
        check_reg_16(reg_model.buf_size_reg_2, 16'h0000, "BUF_SIZE_REG_2", errors);
        check_reg_16(reg_model.buf_size_reg_3, 16'h0000, "BUF_SIZE_REG_3", errors);

        check_reg_24(reg_model.priority_ctrl_reg, 24'h000000, "PRIORITY_CTRL_REG", errors);

        check_reg_8(reg_model.ext_status_reg, 8'h00, "EXT_STATUS_REG", errors);
    endtask

    // Verify RETAINED registers unchanged
    task check_retained(ref int errors);
        check_reg_16(reg_model.base_addr_ch0, 16'h1000, "BASE_ADDR_CH0", errors);
        check_reg_16(reg_model.base_addr_ch1, 16'h2000, "BASE_ADDR_CH1", errors);
        check_reg_16(reg_model.base_addr_ch2, 16'h3000, "BASE_ADDR_CH2", errors);
        check_reg_16(reg_model.base_addr_ch3, 16'h4000, "BASE_ADDR_CH3", errors);
        check_reg_16(reg_model.base_wc_ch0,   16'h0010, "BASE_WC_CH0", errors);
        check_reg_16(reg_model.base_wc_ch1,   16'h0020, "BASE_WC_CH1", errors);
        check_reg_16(reg_model.base_wc_ch2,   16'h0030, "BASE_WC_CH2", errors);
        check_reg_16(reg_model.base_wc_ch3,   16'h0040, "BASE_WC_CH3", errors);
    endtask

    task check_reg_8(uvm_reg reg_h, bit [7:0] expected, string name, ref int errors);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        reg_h.read(status, rdata);
        if (status != UVM_IS_OK || rdata[7:0] !== expected) begin
            `uvm_error("MC_TEST",
                $sformatf("%s: exp=0x%02X obs=0x%02X", name, expected, rdata[7:0]))
            errors = errors + 1; return;
        end
        `uvm_info("MC_TEST",
            $sformatf("  -> PASS: %s = 0x%02X", name, expected), UVM_LOW)
    endtask

    task check_reg_16(uvm_reg reg_h, bit [15:0] expected, string name, ref int errors);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        reg_h.read(status, rdata);
        if (status != UVM_IS_OK || rdata[15:0] !== expected) begin
            `uvm_error("MC_TEST",
                $sformatf("%s: exp=0x%04X obs=0x%04X", name, expected, rdata[15:0]))
            errors = errors + 1; return;
        end
        `uvm_info("MC_TEST",
            $sformatf("  -> PASS: %s = 0x%04X", name, expected), UVM_LOW)
    endtask

    task check_reg_24(uvm_reg reg_h, bit [23:0] expected, string name, ref int errors);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        reg_h.read(status, rdata);
        if (status != UVM_IS_OK || rdata[23:0] !== expected) begin
            `uvm_error("MC_TEST",
                $sformatf("%s: exp=0x%06X obs=0x%06X", name, expected, rdata[23:0]))
            errors = errors + 1; return;
        end
        `uvm_info("MC_TEST",
            $sformatf("  -> PASS: %s = 0x%06X", name, expected), UVM_LOW)
    endtask

    task send_write(bit [4:0] addr, bit [7:0] data);
        cpu_single_item_seq seq;
        seq = cpu_single_item_seq::type_id::create("seq");
        seq.is_read = 1'b0;
        seq.addr    = addr;
        seq.data    = data;
        seq.start(env.cpu_agt.sequencer);
        repeat (3) @(posedge vif.CLK);
    endtask

endclass


//============================================================
// SECTION 22: TRANSFER TEST (actual DMA transfers)
//============================================================
// Configures channels via RAL, then runs dma_transfer_seq on
// the DMA sequencer to drive DREQ/HLDA and complete transfers.
// Verifies address advance, WC decrement, rollover.
//------------------------------------------------------------
class dma_transfer_test extends dma_base_test;

    `uvm_component_utils(dma_transfer_test)

    function new(string name = "dma_transfer_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "DMA transfer test running");

        wait_for_reset();
        do_master_clear();

        `uvm_info("XFER_TEST", "=========== DMA TRANSFER TEST ===========", UVM_LOW)

        test_linear_transfer(2'd0);
        test_circular_transfer(2'd1);
        test_multi_channel();

        do_master_clear();

        // FIX M3: Per-channel completion verification
        check_all_channels_completed();

        report_test_status("dma_transfer_test");
        phase.drop_objection(this, "DMA transfer test complete");
    endtask

    //--------------------------------------------------------
    // Test 1: Linear transfer on CHx (5 transfers)
    //--------------------------------------------------------
    task test_linear_transfer(bit [1:0] ch);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        bit [15:0]     addr_before, wc_before;
        bit [15:0]     addr_after,  wc_after;

        // Configure CH0 via RAL
        reg_model.base_addr_ch0.write(status, 16'h1000);
        reg_model.base_wc_ch0.write(status,   16'h0010);
        reg_model.ch_ctrl_reg_0.write(status, 8'h01);
        reg_model.mode_reg.write(status, {2'b01, 1'b0, 1'b0, 2'b10, ch});
        reg_model.clear_mask.write(status, 8'h00);
        reg_model.command_reg.write(status, 8'h01);

        reg_model.base_addr_ch0.read(status, rdata); addr_before = rdata[15:0];
        reg_model.base_wc_ch0.read(status, rdata);   wc_before   = rdata[15:0];

        // Execute 5 transfers via DMA agent
        begin
            dma_transfer_seq seq = dma_transfer_seq::type_id::create("seq");
            seq.channel       = ch;
            seq.num_transfers = 5;
            seq.circular_en   = 1'b0;
            seq.start(env.dma_agt.sequencer);
        end

        reg_model.base_addr_ch0.read(status, rdata); addr_after = rdata[15:0];
        reg_model.base_wc_ch0.read(status, rdata);   wc_after   = rdata[15:0];

        if (addr_after > addr_before)
            `uvm_info("XFER_TEST", "  -> PASS: address advanced", UVM_LOW)
        else
            `uvm_error("XFER_TEST",
                $sformatf("Address did not advance: 0x%04X -> 0x%04X",
                          addr_before, addr_after))

        if (wc_after < wc_before)
            `uvm_info("XFER_TEST", "  -> PASS: word count decremented", UVM_LOW)
        else
            `uvm_error("XFER_TEST",
                $sformatf("WC did not decrement: 0x%04X -> 0x%04X",
                          wc_before, wc_after))
    endtask

    //--------------------------------------------------------
    // Test 2: Circular transfer on CHx (20 transfers)
    //--------------------------------------------------------
    task test_circular_transfer(bit [1:0] ch);
        uvm_status_e   status;
        uvm_reg_data_t rdata;

        reg_model.base_addr_ch1.write(status, 16'h2000);
        reg_model.base_wc_ch1.write(status,   16'h0020);
        reg_model.buf_size_reg_1.write(status, 16'h0008);
        reg_model.ch_ctrl_reg_1.write(status, 8'h87);
        reg_model.mode_reg.write(status, {2'b01, 1'b0, 1'b0, 2'b10, ch});
        reg_model.command_reg.write(status, 8'h01);

        begin
            dma_transfer_seq seq = dma_transfer_seq::type_id::create("seq");
            seq.channel       = ch;
            seq.num_transfers = 20;
            seq.circular_en   = 1'b1;
            seq.start(env.dma_agt.sequencer);
        end

        reg_model.ext_status_reg.read(status, rdata);
        `uvm_info("XFER_TEST",
            $sformatf("  EXT_STATUS_REG = 0x%02X", rdata[7:0]), UVM_LOW)

        if (rdata[4] == 1'b1)
            `uvm_info("XFER_TEST", "  -> PASS: Rollover pending set", UVM_LOW)
        else
            `uvm_info("XFER_TEST",
                "  -> Rollover not set (fewer transfers than buffer size)", UVM_LOW)
    endtask

    //--------------------------------------------------------
    // Test 3: Sequential transfers across all 4 channels
    //--------------------------------------------------------
    task test_multi_channel();
        uvm_status_e status;

        reg_model.base_addr_ch0.write(status, 16'h1000);
        reg_model.base_wc_ch0.write(status,   16'h0010);
        reg_model.ch_ctrl_reg_0.write(status, 8'h01);

        reg_model.base_addr_ch1.write(status, 16'h2000);
        reg_model.base_wc_ch1.write(status,   16'h0010);
        reg_model.ch_ctrl_reg_1.write(status, 8'h01);

        reg_model.base_addr_ch2.write(status, 16'h3000);
        reg_model.base_wc_ch2.write(status,   16'h0010);
        reg_model.ch_ctrl_reg_2.write(status, 8'h01);

        reg_model.base_addr_ch3.write(status, 16'h4000);
        reg_model.base_wc_ch3.write(status,   16'h0010);
        reg_model.ch_ctrl_reg_3.write(status, 8'h01);

        reg_model.clear_mask.write(status, 8'h00);
        reg_model.command_reg.write(status, 8'h01);

        for (int ch = 0; ch < 4; ch++) begin
            begin
                dma_transfer_seq seq = dma_transfer_seq::type_id::create("seq");
                seq.channel       = ch[1:0];
                seq.num_transfers = 3;
                seq.circular_en   = 1'b0;
                seq.start(env.dma_agt.sequencer);
            end
            `uvm_info("XFER_TEST",
                $sformatf("  CH%0d: 3 transfers complete", ch), UVM_LOW)
        end
    endtask

    //--------------------------------------------------------
    // HELPER: per-channel completion check (Fix M3)
    //--------------------------------------------------------
    task check_all_channels_completed();
        int unsigned ch0_count, ch1_count, ch2_count, ch3_count;
        bit          all_ran;

        ch0_count = env.ref_model.get_ch_pred_count(2'd0);
        ch1_count = env.ref_model.get_ch_pred_count(2'd1);
        ch2_count = env.ref_model.get_ch_pred_count(2'd2);
        ch3_count = env.ref_model.get_ch_pred_count(2'd3);

        `uvm_info("XFER_TEST", "---- PER-CHANNEL COMPLETION CHECK ----", UVM_LOW)
        `uvm_info("XFER_TEST", $sformatf("  CH0 : %0d", ch0_count), UVM_LOW)
        `uvm_info("XFER_TEST", $sformatf("  CH1 : %0d", ch1_count), UVM_LOW)
        `uvm_info("XFER_TEST", $sformatf("  CH2 : %0d", ch2_count), UVM_LOW)
        `uvm_info("XFER_TEST", $sformatf("  CH3 : %0d", ch3_count), UVM_LOW)

        all_ran = env.ref_model.all_channels_ran();

        if (all_ran)
            `uvm_info("XFER_TEST",
                "  -> PASS: All 4 channels completed at least one transfer",
                UVM_LOW)
        else begin
            string msg = "  -> FAIL: Missing channels:";
            if (ch0_count == 0) msg = {msg, " CH0=0"};
            if (ch1_count == 0) msg = {msg, " CH1=0"};
            if (ch2_count == 0) msg = {msg, " CH2=0"};
            if (ch3_count == 0) msg = {msg, " CH3=0"};
            `uvm_error("XFER_TEST", msg)
        end
    endtask

endclass

`endif // DMA_TEST_LIBRARY_SV
