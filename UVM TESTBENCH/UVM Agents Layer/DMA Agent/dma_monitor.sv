//============================================================
// File        : dma_monitor.sv
// Description : UVM DMA Monitor (Extended)
//               Observes DMA handshake + extended register state
//============================================================
// INTERVIEW POINTS:
//   1. Priority order for cycle classification (FIX 3):
//        XFER_PULSE > HLDA > CPU > idle
//      Ensures exactly ONE published item per event cycle.
//   2. Emits dma_seq_item via analysis port to:
//        - reference model
//        - scoreboard
//        - coverage
//   3. Two independent event detectors:
//        - XFER_PULSE rising edge → DMA_TRANSFER_TX
//        - rollover_any rising edge → DMA_ROLLOVER_TX
//   4. FIX A: XFER_PULSE block now samples EVERY compared field
//      (previously left eop_n/aen/adstb/addr/db at 0 → false
//      mismatches like obs=0 exp=1 on eop_n).
//============================================================

`ifndef DMA_MONITOR_SV
`define DMA_MONITOR_SV

class dma_monitor extends uvm_monitor;

    virtual dma_if vif;

    //------------------------------------------------------------
    // Analysis port
    //------------------------------------------------------------
    uvm_analysis_port #(dma_seq_item) ap;

    //------------------------------------------------------------
    // Edge-detect state
    //------------------------------------------------------------
    bit prev_cpu_active;
    bit prev_hlda;
    bit prev_xfer_pulse;
    bit prev_rollover_any;

    //------------------------------------------------------------
    // Stats
    //------------------------------------------------------------
    int unsigned num_cpu_writes;
    int unsigned num_cpu_reads;
    int unsigned num_dma_transfers;
    int unsigned num_grants;
    int unsigned num_rollovers;

    `uvm_component_utils(dma_monitor)

    function new(string name = "dma_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap = new("ap", this);
        num_cpu_writes    = 0;
        num_cpu_reads     = 0;
        num_dma_transfers = 0;
        num_grants        = 0;
        num_rollovers     = 0;
    endfunction

    //============================================================
    // BUILD PHASE
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual dma_if)::get(this, "", "vif", vif))
            `uvm_fatal("DMA_MON", "No virtual interface 'vif' in config_db")
    endfunction

    //============================================================
    // RUN PHASE — main sampling loop
    //============================================================
    virtual task run_phase(uvm_phase phase);
        dma_seq_item tx;

        wait_for_reset_deassert();
        `uvm_info("DMA_MON", "Monitor started", UVM_MEDIUM)

        forever begin
            @(posedge vif.CLK);
            #1;    // allow combinational signals to settle

            //========================================================
            // Classify the cycle — FIX 3 priority:
            //   XFER_PULSE  (highest — handled below, no item here)
            //   HLDA        → DMA transfer cycle
            //   CS_N=0      → CPU programming cycle
            //   else        → idle
            //========================================================

            //---------- XFER_PULSE cycle ----------
            // Handled by dedicated block below; skip here to avoid
            // duplicate publication.
            if (vif.XFER_PULSE === 1'b1) begin
                prev_cpu_active <= 1'b0;
                prev_hlda       <= vif.HLDA;
            end

            //---------- DMA transfer cycle ----------
            else if (vif.HLDA === 1'b1) begin
                tx = dma_seq_item::type_id::create("dma_tx");
                sample_dma_cycle(tx);
                send_transaction(tx);
                prev_cpu_active <= 1'b0;
                prev_hlda       <= 1'b1;
            end

            //---------- CPU programming cycle ----------
            else if (vif.CS_N === 1'b0) begin
                tx = dma_seq_item::type_id::create("cpu_tx");
                sample_cpu_cycle(tx);
                if (tx.tx_type != DMA_IDLE_TX)   // skip idle
                    send_transaction(tx);
                prev_cpu_active <= 1'b1;
                prev_hlda       <= 1'b0;
            end

            //---------- Idle ----------
            else begin
                prev_cpu_active <= 1'b0;
                prev_hlda       <= 1'b0;
            end

            //========================================================
            // Event 1: XFER_PULSE rising edge (FIX 3 + FIX A)
            //========================================================
            // FIX A: Now samples ALL fields the scoreboard compares
            //        (was previously leaving eop_n/aen/adstb/addr/db
            //         at 0 → false mismatch on every transfer).
            //========================================================
            if (vif.XFER_PULSE === 1'b1 && prev_xfer_pulse === 1'b0) begin
                tx = dma_seq_item::type_id::create("xfer_tx");
                tx.tx_type            = DMA_TRANSFER_TX;
                tx.cycle              = ACTIVE;

                //----- Handshake -----
                tx.dreq               = vif.DREQ;
                tx.hlda               = {3'b0, vif.HLDA};
                tx.hrq                = {3'b0, vif.HRQ};
                tx.dack               = vif.DACK;
                tx.aen                = vif.AEN;          // FIX A
                tx.adstb              = vif.ADSTB;        // FIX A
                tx.eop_n              = vif.EOP_N;        // FIX A ← key failure point

                //----- Address/data -----
                tx.addr_l             = vif.ADDR_L;       // FIX A
                tx.addr_u             = vif.ADDR_U;       // FIX A
                tx.db                 = vif.DB;           // FIX A

                //----- Bus control -----
                tx.ior_n              = vif.IOR_N;        // FIX A
                tx.iow_n              = vif.IOW_N;        // FIX A

                //----- Extended state -----
                tx.active_chnum       = vif.active_chnum;
                tx.active_dack        = vif.active_dack;
                tx.valid_dack         = vif.VALID_DACK;
                tx.xfer_pulse         = 1'b1;
                tx.timeout            = vif.timeout;

                //----- Circular buffer state -----
                tx.buffer_used_0      = vif.buffer_used_0;
                tx.buffer_used_1      = vif.buffer_used_1;
                tx.buffer_used_2      = vif.buffer_used_2;
                tx.buffer_used_3      = vif.buffer_used_3;
                tx.rollover_status    = vif.rollover_status;
                tx.rollover_latched   = vif.rollover_latched;
                tx.watermark_reached  = vif.watermark_reached;
                tx.rollover_any       = vif.rollover_any;
                tx.ext_status_reg     = vif.EXT_STATUS_REG;

                num_dma_transfers++;
                send_transaction(tx);
            end
            prev_xfer_pulse <= vif.XFER_PULSE;

            //========================================================
            // Event 2: rollover rising edge (independent)
            //========================================================
            if (vif.rollover_any === 1'b1 && prev_rollover_any === 1'b0) begin
                tx = dma_seq_item::type_id::create("rollover_tx");
                tx.tx_type          = DMA_ROLLOVER_TX;
                tx.rollover_status  = vif.rollover_status;
                tx.rollover_latched = vif.rollover_latched;
                tx.rollover_any     = vif.rollover_any;
                tx.active_chnum     = vif.active_chnum;
                num_rollovers++;
                send_transaction(tx);
            end
            prev_rollover_any <= vif.rollover_any;

        end
    endtask

    //============================================================
    // sample_cpu_cycle — classify CPU programming cycle
    //============================================================
    protected virtual task sample_cpu_cycle(ref dma_seq_item tx);
        tx.tx_type = DMA_IDLE_TX;
        tx.cycle   = IDLE;

        tx.dreq   = vif.DREQ;
        tx.hlda   = {3'b0, vif.HLDA};
        tx.addr_l = vif.ADDR_L;
        tx.addr_u = vif.ADDR_U;
        tx.ior_n  = vif.IOR_N;
        tx.iow_n  = vif.IOW_N;
        tx.db     = vif.DB;

        if (vif.IOW_N === 1'b0 && vif.IOR_N === 1'b1) begin
            tx.tx_type = DMA_REG_WRITE_TX;
            num_cpu_writes++;
        end
        else if (vif.IOR_N === 1'b0 && vif.IOW_N === 1'b1) begin
            tx.tx_type = DMA_REG_READ_TX;
            num_cpu_reads++;
        end
    endtask

    //============================================================
    // sample_dma_cycle — classify DMA transfer cycle
    //============================================================
    protected virtual task sample_dma_cycle(ref dma_seq_item tx);

        // Handshake
        tx.hrq    = {3'b0, vif.HRQ};
        tx.aen    = vif.AEN;
        tx.adstb  = vif.ADSTB;
        tx.eop_n  = vif.EOP_N;
        tx.dack   = vif.DACK;
        tx.dreq   = vif.DREQ;
        tx.hlda   = {3'b0, vif.HLDA};

        // Address/data
        tx.addr_l = vif.ADDR_L;
        tx.addr_u = vif.ADDR_U;
        tx.db     = vif.DB;

        // Bus control
        tx.ior_n  = vif.IOR_N;
        tx.iow_n  = vif.IOW_N;

        // Extended state
        tx.active_chnum  = vif.active_chnum;
        tx.active_dack   = vif.active_dack;
        tx.valid_dack    = vif.VALID_DACK;
        tx.xfer_pulse    = vif.XFER_PULSE;
        tx.timeout       = vif.timeout;

        // Circular buffer state
        tx.buffer_used_0     = vif.buffer_used_0;
        tx.buffer_used_1     = vif.buffer_used_1;
        tx.buffer_used_2     = vif.buffer_used_2;
        tx.buffer_used_3     = vif.buffer_used_3;
        tx.rollover_status   = vif.rollover_status;
        tx.rollover_latched  = vif.rollover_latched;
        tx.watermark_reached = vif.watermark_reached;
        tx.rollover_any      = vif.rollover_any;
        tx.ext_status_reg    = vif.EXT_STATUS_REG;

        // Classify
        if (|vif.DACK)                                          tx.tx_type = DMA_GRANT_TX;
        else if (!vif.EOP_N)                                    tx.tx_type = DMA_COMPLETE_TX;
        else if (!vif.MEMR_N || !vif.MEMW_N || !vif.IOR_N || !vif.IOW_N)
                                                                tx.tx_type = DMA_TRANSFER_TX;
        else                                                    tx.tx_type = DMA_REQ_TX;

        if (tx.tx_type == DMA_GRANT_TX) num_grants++;
    endtask

    //============================================================
    // send_transaction — publish via analysis port
    //============================================================
    protected virtual function void send_transaction(dma_seq_item tx);
        ap.write(tx);
    endfunction

    //============================================================
    // wait_for_reset_deassert
    //============================================================
    protected virtual task wait_for_reset_deassert();
        @(posedge vif.CLK);
        while (vif.RESET) @(posedge vif.CLK);
        `uvm_info("DMA_MON", "Reset deasserted, monitoring begins", UVM_MEDIUM)
    endtask

    //============================================================
    // REPORT PHASE — stats
    //============================================================
    virtual function void report_phase(uvm_phase phase);
        `uvm_info("DMA_MON",
            $sformatf("Monitor stats: CPU_W=%0d CPU_R=%0d DMA_XFER=%0d GRANTS=%0d ROLLOVERS=%0d",
                      num_cpu_writes, num_cpu_reads, num_dma_transfers,
                      num_grants, num_rollovers),
            UVM_LOW)
    endfunction

endclass

`endif // DMA_MONITOR_SV  
