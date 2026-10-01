//============================================================
// File        : cpu_agent.sv
// Description : UVM CPU Agent (ACTIVE)
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_agent — a standard container component.
//   2. Always creates monitor.
//   3. Creates driver + sequencer ONLY if is_active == UVM_ACTIVE.
//   4. Propagates VIF to children via uvm_config_db in build_phase.
//   5. Wires driver.seq_item_port ↔ sequencer.seq_item_export
//      in connect_phase.
//   6. Provides get_ap() so external components can subscribe to
//      the monitor's analysis port without touching internals.
//============================================================

`ifndef CPU_AGENT_SV
`define CPU_AGENT_SV

class cpu_agent extends uvm_agent;

    //------------------------------------------------------------
    // Child component handles
    //------------------------------------------------------------
    cpu_driver                     driver;
    cpu_monitor                    monitor;
    uvm_sequencer #(cpu_seq_item)  sequencer;

    //------------------------------------------------------------
    // Config handle
    //------------------------------------------------------------
    cpu_agent_config cfg;

    `uvm_component_utils(cpu_agent)

    function new(string name = "cpu_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //============================================================
    // BUILD PHASE
    //============================================================
    // Order matters:
    //   1. Fetch cfg from config_db
    //   2. Set this.is_active = cfg.is_active (UVM base-class field)
    //   3. Publish VIF to children
    //   4. Create children (monitor always; driver/sequencer if active)
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        //--------------------------------------------------
        // Step 1: fetch config (or use defaults)
        //--------------------------------------------------
        if (!uvm_config_db #(cpu_agent_config)::get(this, "", "cfg", cfg)) begin
            `uvm_info("CPU_AGENT",
                "No cpu_agent_config in config_db — using defaults (ACTIVE)",
                UVM_MEDIUM)
            cfg = cpu_agent_config::type_id::create("cfg");
            cfg.is_active    = UVM_ACTIVE;
            cfg.has_coverage = 1'b1;
        end

        //--------------------------------------------------
        // Step 2: propagate mode to UVM base class field
        //--------------------------------------------------
        is_active = cfg.is_active;

        //--------------------------------------------------
        // Step 3: forward VIF to child components
        //--------------------------------------------------
        if (cfg.vif != null) begin
            uvm_config_db #(virtual dma_if)::set(this, "driver",  "vif", cfg.vif);
            uvm_config_db #(virtual dma_if)::set(this, "monitor", "vif", cfg.vif);
        end

        //--------------------------------------------------
        // Step 4: create children
        //--------------------------------------------------
        // Monitor is ALWAYS created (both active & passive modes).
        monitor = cpu_monitor::type_id::create("monitor", this);

        // Driver + sequencer only in ACTIVE mode.
        if (is_active == UVM_ACTIVE) begin
            driver    = cpu_driver::type_id::create("driver", this);
            sequencer = uvm_sequencer #(cpu_seq_item)::type_id::create("sequencer", this);
            `uvm_info("CPU_AGENT", "Built as ACTIVE agent", UVM_MEDIUM)
        end else begin
            `uvm_info("CPU_AGENT", "Built as PASSIVE agent", UVM_MEDIUM)
        end
    endfunction

    //============================================================
    // CONNECT PHASE — wire driver to sequencer
    //============================================================
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (is_active == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
            `uvm_info("CPU_AGENT",
                "Connected driver.seq_item_port to sequencer.seq_item_export",
                UVM_HIGH)
        end
    endfunction

    //============================================================
    // Accessor — expose monitor's analysis port
    //============================================================
    function uvm_analysis_port #(cpu_seq_item) get_ap();
        return monitor.ap;
    endfunction

endclass

`endif // CPU_AGENT_SV 

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
