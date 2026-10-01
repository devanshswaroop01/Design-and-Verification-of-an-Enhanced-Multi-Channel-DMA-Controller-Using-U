//============================================================
// File        : dma_agent.sv
// Description : UVM DMA Agent (selectable ACTIVE/PASSIVE)
//============================================================
// INTERVIEW POINTS:
//   1. Same structure as cpu_agent, but with dma_* children.
//   2. Default is UVM_ACTIVE (drives DREQ/HLDA).
//   3. Can be built PASSIVE for system-level integration
//      where the DMA bus is driven externally.
//   4. get_ap() exposes monitor's analysis port.
//============================================================

`ifndef DMA_AGENT_SV
`define DMA_AGENT_SV

class dma_agent extends uvm_agent;

    dma_driver      driver;
    dma_monitor     monitor;
    dma_sequencer   sequencer;
    dma_agent_config cfg;

    `uvm_component_utils(dma_agent)

    function new(string name = "dma_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //============================================================
    // BUILD PHASE
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        //--------------------------------------------------
        // Step 1: fetch config
        //--------------------------------------------------
        if (!uvm_config_db #(dma_agent_config)::get(this, "", "cfg", cfg)) begin
            `uvm_info("DMA_AGENT",
                "No dma_agent_config in config_db — using defaults (ACTIVE)",
                UVM_MEDIUM)
            cfg = dma_agent_config::type_id::create("cfg");
            cfg.is_active = UVM_ACTIVE;
        end

        //--------------------------------------------------
        // Step 2: propagate mode
        //--------------------------------------------------
        is_active = cfg.is_active;

        //--------------------------------------------------
        // Step 3: forward VIF to children
        //--------------------------------------------------
        if (cfg.vif != null) begin
            uvm_config_db #(virtual dma_if)::set(this, "monitor", "vif", cfg.vif);
            uvm_config_db #(virtual dma_if)::set(this, "driver",  "vif", cfg.vif);
        end

        //--------------------------------------------------
        // Step 4: create children
        //--------------------------------------------------
        monitor = dma_monitor::type_id::create("monitor", this);

        if (is_active == UVM_ACTIVE) begin
            driver    = dma_driver::type_id::create("driver", this);
            sequencer = dma_sequencer::type_id::create("sequencer", this);
            `uvm_info("DMA_AGENT", "Built as ACTIVE agent", UVM_MEDIUM)
        end else begin
            `uvm_info("DMA_AGENT",
                "Built as PASSIVE agent (monitor only)", UVM_MEDIUM)
        end
    endfunction

    //============================================================
    // CONNECT PHASE
    //============================================================
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (is_active == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
            `uvm_info("DMA_AGENT",
                "Connected driver.seq_item_port to sequencer.seq_item_export",
                UVM_HIGH)
        end
    endfunction

    //============================================================
    // Accessor
    //============================================================
    function uvm_analysis_port #(dma_seq_item) get_ap();
        return monitor.ap;
    endfunction

endclass

`endif // DMA_AGENT_SV

//Agent Anatomy

   // ┌─────────────────────────────────────────────┐
   // │              cpu_agent / dma_agent          │
   // │                                             │
   // │  ┌───────────────┐    ┌──────────────────┐  │
   // │  │  sequencer    │◄───│  sequences run   │  │
   // │  │  (typed)      │    │  from test/env   │  │
   // │  └───────┬───────┘    └──────────────────┘  │
   // │          │ seq_item_export                  │
   // │          │                                  │
   // │  ┌───────▼───────┐                          │
   // │  │  driver       │  (ACTIVE mode only)      │
   // │  │  (uvm_driver) │                          │
   // │  └───────┬───────┘                          │
   // │          │                                  │
   // │          ▼ drives DUT pins                  │
   // │                                             │
   // │  ┌───────────────┐                          │
   // │  │  monitor      │  (always present)        │
   // │  │  (uvm_monitor)│                          │
   // │  └───────┬───────┘                          │
   // │          │ analysis_port (get_ap())         │
   // │          ▼                                  │
   // └─────────────────────────────────────────────┘
   //            │
   //            ▼ to subscribers (scoreboard, coverage, predictor)
