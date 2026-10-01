//============================================================
// File        : dma_driver.sv
// Description : UVM DMA Driver (Active agent)
//               Drives DREQ/HLDA and waits for XFER_PULSE.
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_driver #(dma_seq_item).
//   2. Drives ONLY: DREQ, HLDA (CPU driver owns the rest).
//   3. Protocol: DREQ → wait HRQ → HLDA → wait XFER_PULSE
//      → deassert → settle.
//   4. FIX C: longer waits (40 cycles) for multi-channel
//      arbitration/transfer.
//   5. FIX D: no put_response() — avoid queue overflow.
//============================================================

`ifndef DMA_DRIVER_SV
`define DMA_DRIVER_SV

class dma_driver extends uvm_driver #(dma_seq_item);

    virtual dma_if vif;

    // Stats for report_phase
    int unsigned num_dma_cycles;
    int unsigned num_xfer_pulses;

    `uvm_component_utils(dma_driver)

    function new(string name = "dma_driver", uvm_component parent = null);
        super.new(name, parent);
        num_dma_cycles  = 0;
        num_xfer_pulses = 0;
    endfunction

    //============================================================
    // BUILD PHASE — fetch vif
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual dma_if)::get(this, "", "vif", vif))
            `uvm_fatal("DMA_DRV", "No virtual interface 'vif' in config_db")
    endfunction

    //============================================================
    // RUN PHASE — main driver loop
    //============================================================
    virtual task run_phase(uvm_phase phase);
        dma_seq_item req;

        initialize_dma_bus();
        wait_for_reset_deassert();

        forever begin
            seq_item_port.get_next_item(req);

            // Only act on stimulus items; observation items are ignored.
            if (req.drive_dma)
                do_dma_cycle(req);

            // FIX D: no put_response() — sequences don't call
            // get_response(); pushing here overflows the response
            // queue with "Response queue overflow" warnings.
            seq_item_port.item_done();
        end
    endtask

    //============================================================
    // initialize_dma_bus — drive handshakes to idle
    //============================================================
    protected virtual task initialize_dma_bus();
        @(posedge vif.CLK);
        vif.DREQ <= 4'b0000;
        vif.HLDA <= 1'b0;
        `uvm_info("DMA_DRV", "DMA bus initialized to idle", UVM_MEDIUM)
    endtask

    //============================================================
    // wait_for_reset_deassert
    //============================================================
    protected virtual task wait_for_reset_deassert();
        @(posedge vif.CLK);
        while (vif.RESET) @(posedge vif.CLK);
        `uvm_info("DMA_DRV", "Reset deasserted, driver ready", UVM_MEDIUM)
    endtask

    //============================================================
    // do_dma_cycle — one complete DREQ → XFER_PULSE sequence
    //============================================================
    protected virtual task do_dma_cycle(dma_seq_item item);
        int  hrq_wait_cycles  = 40;   // FIX C: was 20
        int  xfer_wait_cycles = 40;   // FIX C: was 15
        bit  xfer_seen        = 1'b0;
        bit  hrq_seen         = 1'b0;

        num_dma_cycles++;

        //--------------------------------------------------
        // Step 1: Assert DREQ, wait for HRQ
        //--------------------------------------------------
        @(posedge vif.CLK);
        vif.DREQ <= item.dreq_drive;
        vif.HLDA <= 1'b0;

        for (int i = 0; i < hrq_wait_cycles; i++) begin
            @(posedge vif.CLK);
            if (vif.HRQ === 1'b1) begin
                hrq_seen = 1'b1;
                break;
            end
        end

        `uvm_info("DMA_DRV",
            $sformatf("DMA: DREQ=0x%X -> HRQ=%b (after %0d cycles)",
                      item.dreq_drive, hrq_seen, hrq_wait_cycles),
            UVM_HIGH)

        //--------------------------------------------------
        // Step 2: Assert HLDA (CPU grants bus)
        //--------------------------------------------------
        @(posedge vif.CLK);
        vif.HLDA <= item.hlda_drive;

        //--------------------------------------------------
        // Step 3: Wait for XFER_PULSE (transfer complete)
        //--------------------------------------------------
        for (int i = 0; i < xfer_wait_cycles; i++) begin
            @(posedge vif.CLK);
            if (vif.XFER_PULSE === 1'b1) begin
                xfer_seen = 1'b1;
                num_xfer_pulses++;
                vif.DREQ <= 4'b0000;
                vif.HLDA <= 1'b0;
                `uvm_info("DMA_DRV",
                    $sformatf("DMA: XFER_PULSE observed at cycle %0d (DREQ=0x%X)",
                              i, item.dreq_drive),
                    UVM_HIGH)
                break;
            end
        end

        //--------------------------------------------------
        // Step 4: Fallback — always release bus
        //--------------------------------------------------
        if (!xfer_seen) begin
            vif.DREQ <= 4'b0000;
            vif.HLDA <= 1'b0;
            `uvm_warning("DMA_DRV",
                $sformatf("DMA: XFER_PULSE not observed in %0d cycles (DREQ=0x%X)",
                          xfer_wait_cycles, item.dreq_drive))
        end

        //--------------------------------------------------
        // Step 5: Settle — FSM back to IDLE
        //--------------------------------------------------
        repeat (3) @(posedge vif.CLK);

        `uvm_info("DMA_DRV",
            $sformatf("DMA: transfer complete (DREQ=0x%X)",
                      item.dreq_drive),
            UVM_HIGH)
    endtask

    //============================================================
    // REPORT PHASE — print stats
    //============================================================
    virtual function void report_phase(uvm_phase phase);
        `uvm_info("DMA_DRV",
            $sformatf("DMA driver stats: %0d DMA cycles issued, %0d XFER_PULSEs observed",
                      num_dma_cycles, num_xfer_pulses),
            UVM_LOW)
    endfunction

endclass

`endif // DMA_DRIVER_SV

   //DMA Driver FSM (per transaction)

   // IDLE
   //  │ get_next_item (drive_dma=1)
   //  ▼
   // DREQ ───── drive DREQ[ch]=1, HLDA=0
   //  │         wait for HRQ (up to 40 cyc)
   //  ▼
   // GRANT ──── drive HLDA=1
   //  │         wait for XFER_PULSE (up to 40 cyc)
   //  ▼
   // RELEASE ── DREQ=0, HLDA=0
   //  │
   //  │ 3-cycle settle
   //  ▼
   // IDLE
