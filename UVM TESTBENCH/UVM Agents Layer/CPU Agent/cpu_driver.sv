//============================================================
// File        : cpu_driver.sv
// Description : UVM CPU Driver
//               Drives CPU bus cycles (read/write registers)
//               in response to cpu_seq_item from sequencer.
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_driver #(cpu_seq_item).
//   2. Drives CS_N, IOR_N, IOW_N, ADDR_L, ADDR_U, DB.
//   3. Gets vif + cfg via uvm_config_db in build_phase.
//   4. Uses seq_item_port.get_next_item / item_done handshake.
//   5. Tri-states shared bus signals when idle → DUT can drive.
//============================================================

`ifndef CPU_DRIVER_SV
`define CPU_DRIVER_SV

class cpu_driver extends uvm_driver #(cpu_seq_item);

    //------------------------------------------------------------
    // Handles (from config_db)
    //------------------------------------------------------------
    virtual dma_if   vif;
    cpu_agent_config cfg;

    `uvm_component_utils(cpu_driver)

    function new(string name = "cpu_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //============================================================
    // BUILD PHASE — fetch vif and cfg
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(virtual dma_if)::get(this, "", "vif", vif))
            `uvm_fatal("CPU_DRV", "No virtual interface 'vif' in config_db")

        if (!uvm_config_db #(cpu_agent_config)::get(this, "", "cfg", cfg)) begin
            `uvm_info("CPU_DRV", "No cpu_agent_config — using defaults", UVM_MEDIUM)
            cfg = cpu_agent_config::type_id::create("cfg");
        end
    endfunction

    //============================================================
    // RUN PHASE — main driver loop
    //============================================================
    virtual task run_phase(uvm_phase phase);
        cpu_seq_item req;

        initialize_bus();
        wait_for_reset_deassert();

        forever begin
            seq_item_port.get_next_item(req);      // blocking pull

            `uvm_info("CPU_DRV",
                $sformatf("Received transaction: %s", req.convert2string()),
                UVM_HIGH)

            if (req.is_read) do_read(req);
            else             do_write(req);

            // NOTE: put_response() is commented out — sequences
            // don't call get_response(), so pushing responses
            // would overflow the response queue.
            seq_item_port.item_done();              // handshake complete
        end
    endtask

    //============================================================
    // initialize_bus — drive bus to idle state
    //============================================================
    // FIX 1: DREQ and HLDA removed from initialization.
    //        These are owned by the DMA driver. Driving them
    //        here as well would create a multi-driver race.
    //------------------------------------------------------------
    protected virtual task initialize_bus();
        @(posedge vif.CLK);
        vif.CS_N   <= 1'b1;      // deselected
        vif.IOR_N  <= 1'b1;      // read inactive
        vif.IOW_N  <= 1'b1;      // write inactive
        vif.ADDR_L <= 5'bz;      // tri-state
        vif.ADDR_U <= 4'bz;
        vif.DB     <= 8'bz;
        // DREQ / HLDA — owned by dma_driver, not touched here.
        `uvm_info("CPU_DRV",
            "Bus initialized to idle (DREQ/HLDA owned by DMA driver)",
            UVM_MEDIUM)
    endtask

    //============================================================
    // wait_for_reset_deassert
    //============================================================
    protected virtual task wait_for_reset_deassert();
        @(posedge vif.CLK);
        while (vif.RESET) @(posedge vif.CLK);
        `uvm_info("CPU_DRV", "Reset deasserted, driver ready", UVM_MEDIUM)
    endtask

    //============================================================
    // do_write — one CPU write cycle
    //============================================================
    protected virtual task do_write(cpu_seq_item item);
        @(posedge vif.CLK);
        // Drive setup phase
        vif.CS_N   <= 1'b0;
        vif.IOR_N  <= 1'b1;      // read inactive
        vif.IOW_N  <= 1'b0;      // write active
        vif.ADDR_L <= item.addr;
        vif.ADDR_U <= 4'h0;      // upper addr = 0 for register decode
        vif.DB     <= item.data;

        `uvm_info("CPU_DRV",
            $sformatf("WRITE addr=0x%02X data=0x%02X",
                      item.addr, item.data),
            UVM_HIGH)

        @(posedge vif.CLK);
        // Deassert / tri-state after one cycle
        vif.IOW_N  <= 1'b1;
        vif.ADDR_L <= 5'bz;
        vif.ADDR_U <= 4'bz;
        vif.DB     <= 8'bz;
        vif.CS_N   <= 1'b1;

        @(posedge vif.CLK);
    endtask

    //============================================================
    // do_read — one CPU read cycle
    //============================================================
    protected virtual task do_read(cpu_seq_item item);
        @(posedge vif.CLK);
        vif.CS_N   <= 1'b0;
        vif.IOR_N  <= 1'b0;      // read active
        vif.IOW_N  <= 1'b1;      // write inactive
        vif.ADDR_L <= item.addr;
        vif.ADDR_U <= 4'h0;
        vif.DB     <= 8'bz;      // let DUT drive

        @(posedge vif.CLK);
        item.data = vif.DB;      // sample

        `uvm_info("CPU_DRV",
            $sformatf("READ  addr=0x%02X data=0x%02X",
                      item.addr, item.data),
            UVM_HIGH)

        vif.IOR_N  <= 1'b1;
        vif.ADDR_L <= 5'bz;
        vif.ADDR_U <= 4'bz;
        vif.CS_N   <= 1'b1;

        @(posedge vif.CLK);
    endtask

endclass

`endif // CPU_DRIVER_SV

//CPU Driver FSM (per transaction)

   // IDLE
   //  │ get_next_item
   //  ▼
   // SETUP ─── drive CS=0, addr, dir, data
   //  │
   //  │ posedge CLK
   //  ▼
   // ACCESS ── DUT samples (read) / captures (write)
   //  │
   //  │ posedge CLK
   //  ▼
   // RELEASE ─ tri-state all bus signals
   //  │
   //  │ posedge CLK
   //  ▼
   // IDLE
