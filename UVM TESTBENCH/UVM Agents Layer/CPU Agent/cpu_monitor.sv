//============================================================
// File        : cpu_monitor.sv
// Description : UVM CPU Monitor
//               Passively observes CPU bus cycles on dma_if
//               and emits cpu_seq_item via analysis port.
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_monitor (passive component).
//   2. Has uvm_analysis_port #(cpu_seq_item) — publishes to
//      any subscriber (predictor, ref_model, scoreboard, coverage).
//   3. Uses edge-detect (prev_write_active/prev_read_active) to
//      emit exactly ONE item per bus cycle.
//   4. Skips cycles when CS_N != 0 or HLDA != 0 (not a CPU access).
//   5. For reads, adds #1 delay to let DUT data settle before sampling.
//============================================================

`ifndef CPU_MONITOR_SV
`define CPU_MONITOR_SV

class cpu_monitor extends uvm_monitor;

    virtual dma_if vif;

    //------------------------------------------------------------
    // Analysis port — publish channel
    //------------------------------------------------------------
    uvm_analysis_port #(cpu_seq_item) ap;

    //------------------------------------------------------------
    // Edge-detect state
    //------------------------------------------------------------
    bit prev_write_active;
    bit prev_read_active;

    //------------------------------------------------------------
    // Stats
    //------------------------------------------------------------
    int unsigned num_writes;
    int unsigned num_reads;

    `uvm_component_utils(cpu_monitor)

    function new(string name = "cpu_monitor", uvm_component parent = null);
        super.new(name, parent);
        num_writes = 0;
        num_reads  = 0;
    endfunction

    //============================================================
    // BUILD PHASE — create analysis port, get vif
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);   // must be created in build_phase

        if (!uvm_config_db #(virtual dma_if)::get(this, "", "vif", vif))
            `uvm_fatal("CPU_MON", "No virtual interface 'vif' in config_db")
    endfunction

    //============================================================
    // RUN PHASE — main sampling loop
    //============================================================
    virtual task run_phase(uvm_phase phase);
        cpu_seq_item item;

        wait_for_reset_deassert();
        `uvm_info("CPU_MON", "Monitor started", UVM_MEDIUM)

        forever begin
            @(posedge vif.CLK);

            //--------------------------------------------------
            // Not a CPU access? Skip.
            // CS_N must be 0 AND HLDA must be 0.
            //--------------------------------------------------
            if (vif.CS_N !== 1'b0 || vif.HLDA !== 1'b0) begin
                prev_write_active <= 1'b0;
                prev_read_active  <= 1'b0;
                continue;
            end

            //--------------------------------------------------
            // WRITE cycle detection: IOW_N=0, IOR_N=1
            //--------------------------------------------------
            if (vif.IOW_N === 1'b0 && vif.IOR_N === 1'b1) begin
                if (!prev_write_active) begin      // rising edge only
                    item = cpu_seq_item::type_id::create("mon_wr");
                    item.is_read    = 1'b0;
                    item.addr       = vif.ADDR_L;
                    item.data       = vif.DB;      // driver-driven → sample directly
                    item.status     = UVM_IS_OK;
                    item.start_time = $time;

                    num_writes++;

                    `uvm_info("CPU_MON",
                        $sformatf("Observed WRITE: %s = 0x%02X",
                                  item.get_register_name(), item.data),
                        UVM_LOW)

                    ap.write(item);                // publish!
                end
                prev_write_active <= 1'b1;
                prev_read_active  <= 1'b0;
            end
            //--------------------------------------------------
            // READ cycle detection: IOR_N=0, IOW_N=1
            //--------------------------------------------------
            else if (vif.IOR_N === 1'b0 && vif.IOW_N === 1'b1) begin
                if (!prev_read_active) begin       // rising edge only
                    item = cpu_seq_item::type_id::create("mon_rd");
                    item.is_read    = 1'b1;
                    item.addr       = vif.ADDR_L;
                    item.status     = UVM_IS_OK;
                    item.start_time = $time;

                    #1;                            // let DUT drive settle
                    item.data = vif.DB;

                    num_reads++;

                    `uvm_info("CPU_MON",
                        $sformatf("Observed READ: %s = 0x%02X",
                                  item.get_register_name(), item.data),
                        UVM_LOW)

                    ap.write(item);
                end
                prev_read_active  <= 1'b1;
                prev_write_active <= 1'b0;
            end
            //--------------------------------------------------
            // No active cycle — reset edge detect state
            //--------------------------------------------------
            else begin
                prev_write_active <= 1'b0;
                prev_read_active  <= 1'b0;
            end
        end
    endtask

    //============================================================
    // wait_for_reset_deassert
    //============================================================
    protected virtual task wait_for_reset_deassert();
        @(posedge vif.CLK);
        while (vif.RESET) @(posedge vif.CLK);
        `uvm_info("CPU_MON", "Reset deasserted, monitoring begins", UVM_MEDIUM)
    endtask

    //============================================================
    // REPORT PHASE
    //============================================================
    virtual function void report_phase(uvm_phase phase);
        `uvm_info("CPU_MON",
            $sformatf("Monitor stats: %0d writes, %0d reads, %0d total",
                      num_writes, num_reads, num_writes + num_reads),
            UVM_LOW)
    endfunction

endclass

`endif // CPU_MONITOR_SV

   //Where Monitors Fit in UVM
      
   DUT pins ───► cpu_monitor ───► ap.write(cpu_seq_item) ────┐
                                                             │
   DUT pins ───► dma_monitor ───► ap.write(dma_seq_item) ────┤
                                                             ▼
                                        ┌──────────────┬──────────────┬──────────────┐
                                        ▼              ▼              ▼              ▼
                                    predictor     ref_model      scoreboard     coverage
                                  (RAL mirror)   (golden)      (comparator)   (functional)
