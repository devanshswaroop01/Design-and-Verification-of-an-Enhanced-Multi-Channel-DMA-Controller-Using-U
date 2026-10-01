//============================================================
// File        : dma_env.sv
// Description : UVM Environment for DMA Controller
//               Top-level container wiring all components.
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_env.
//   2. build_phase: create all children.
//   3. connect_phase: wire TLM connections.
//   4. Publishes config to agents with wildcard scope ("cpu_agt.*")
//      so children can also get it (BLOCKER 7).
//   5. Topology (visualized):
//        cpu_agt  ──► predictor, ref_model, scoreboard, coverage
//        dma_agt  ──► ref_model, scoreboard, coverage
//        ref_model ─► scoreboard (expected side)
//============================================================

`ifndef DMA_ENV_SV
`define DMA_ENV_SV

class dma_env extends uvm_env;

    //============================================================
    // COMPONENT HANDLES
    //============================================================
    cpu_agent               cpu_agt;
    dma_agent               dma_agt;
    dma_virtual_sequencer   vseqr;

    dma_reg_block           reg_model;
    dma_reg_adapter         adapter;
    dma_reg_predictor       predictor;

    dma_reference_model     ref_model;
    dma_scoreboard          scoreboard;
    dma_coverage            coverage;

    //============================================================
    // CONFIG HANDLES
    //============================================================
    cpu_agent_config        cpu_cfg;
    dma_agent_config        dma_cfg;

    `uvm_component_utils(dma_env)

    function new(string name = "dma_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //============================================================
    // BUILD PHASE — create all children
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        //--------------------------------------------------
        // Step 1: fetch agent configs from config_db
        //--------------------------------------------------
        if (!uvm_config_db #(cpu_agent_config)::get(this, "", "cpu_cfg", cpu_cfg)) begin
            `uvm_info("ENV", "No cpu_agent_config — using default (ACTIVE)", UVM_MEDIUM)
            cpu_cfg = cpu_agent_config::type_id::create("cpu_cfg");
            cpu_cfg.is_active    = UVM_ACTIVE;
            cpu_cfg.has_coverage = 1'b1;
        end

        if (!uvm_config_db #(dma_agent_config)::get(this, "", "dma_cfg", dma_cfg)) begin
            `uvm_info("ENV", "No dma_agent_config — using default (ACTIVE)", UVM_MEDIUM)
            dma_cfg = dma_agent_config::type_id::create("dma_cfg");
            dma_cfg.is_active = UVM_ACTIVE;
        end

        //--------------------------------------------------
        // Step 2: distribute configs to agents
        //--------------------------------------------------
        // BLOCKER 7 FIX: use "cpu_agt.*" wildcard so children
        // (driver, monitor) also receive cfg via config_db.
        // Previously scoped as "cpu_agt" only → driver fell back
        // to defaults on every run.
        //--------------------------------------------------
        uvm_config_db #(cpu_agent_config)::set(this, "cpu_agt.*", "cfg", cpu_cfg);
        uvm_config_db #(dma_agent_config)::set(this, "dma_agt.*", "cfg", dma_cfg);

        //--------------------------------------------------
        // Step 3: RAL model + adapter + predictor
        //--------------------------------------------------
        reg_model = dma_reg_block::type_id::create("reg_model");
        reg_model.build();                          // must build before lock

        adapter = dma_reg_adapter::type_id::create("adapter");

        predictor = dma_reg_predictor::type_id::create("predictor", this);
        uvm_config_db #(dma_reg_block)::set(this, "predictor", "reg_model", reg_model);

        // Publish RAL model broadly (vseqr + wildcard for tests)
        uvm_config_db #(dma_reg_block)::set(this, "vseqr", "reg_model", reg_model);
        uvm_config_db #(dma_reg_block)::set(this, "*",     "reg_model", reg_model);

        //--------------------------------------------------
        // Step 4: create agents
        //--------------------------------------------------
        cpu_agt = cpu_agent::type_id::create("cpu_agt", this);
        dma_agt = dma_agent::type_id::create("dma_agt", this);

        //--------------------------------------------------
        // Step 5: create checkers and coverage
        //--------------------------------------------------
        ref_model  = dma_reference_model::type_id::create("ref_model",  this);
        scoreboard = dma_scoreboard::type_id::create("scoreboard",      this);
        coverage   = dma_coverage::type_id::create("coverage",          this);

        //--------------------------------------------------
        // Step 6: create virtual sequencer
        //--------------------------------------------------
        vseqr = dma_virtual_sequencer::type_id::create("vseqr", this);

    endfunction

    //============================================================
    // CONNECT PHASE — wire TLM connections
    //============================================================
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        //--------------------------------------------------
        // 1. RAL — adapter + sequencer
        //--------------------------------------------------
        adapter.set_sequencer(cpu_agt.sequencer);
        reg_model.dma_map.set_sequencer(cpu_agt.sequencer, adapter);
        reg_model.dma_map.set_auto_predict(0);    // use external predictor

        //--------------------------------------------------
        // 2. Predictor subscribes to CPU monitor
        //--------------------------------------------------
        cpu_agt.get_ap().connect(predictor.analysis_export);

        //--------------------------------------------------
        // 3. Reference model subscribes to CPU + DMA monitors
        //--------------------------------------------------
        cpu_agt.get_ap().connect(ref_model.cpu_export);
        dma_agt.get_ap().connect(ref_model.dma_export);

        //--------------------------------------------------
        // 4. Scoreboard subscribes to CPU + DMA + expected
        //--------------------------------------------------
        cpu_agt.get_ap().connect(scoreboard.cpu_export);
        dma_agt.get_ap().connect(scoreboard.dma_export);
        ref_model.expected_port.connect(scoreboard.exp_export);

        //--------------------------------------------------
        // 5. Coverage subscribes to CPU + DMA monitors
        //--------------------------------------------------
        cpu_agt.get_ap().connect(coverage.cpu_export);
        dma_agt.get_ap().connect(coverage.dma_export);

        //--------------------------------------------------
        // 6. Virtual sequencer — populate handles
        //--------------------------------------------------
        vseqr.cpu_seqr  = cpu_agt.sequencer;
        if (dma_agt.is_active == UVM_ACTIVE)
            vseqr.dma_seqr = dma_agt.sequencer;
        vseqr.reg_model = reg_model;

        `uvm_info("ENV", "Environment connect_phase complete", UVM_MEDIUM)
    endfunction

    //============================================================
    // END OF ELABORATION — print topology
    //============================================================
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);

        if (uvm_report_enabled(UVM_MEDIUM)) begin
            `uvm_info("ENV", "DMA Verification Environment Topology:", UVM_MEDIUM)
            `uvm_info("ENV", "  cpu_agt (ACTIVE)   -> cpu_driver, cpu_monitor, cpu_sequencer", UVM_MEDIUM)
            if (dma_agt.is_active == UVM_ACTIVE)
                `uvm_info("ENV", "  dma_agt (ACTIVE)   -> dma_driver, dma_monitor, dma_sequencer", UVM_MEDIUM)
            else
                `uvm_info("ENV", "  dma_agt (PASSIVE)  -> dma_monitor", UVM_MEDIUM)
            `uvm_info("ENV", "  reg_model + adapter + predictor", UVM_MEDIUM)
            `uvm_info("ENV", "  ref_model, scoreboard, coverage", UVM_MEDIUM)
            `uvm_info("ENV", "  vseqr (virtual sequencer)", UVM_MEDIUM)
        end
    endfunction

endclass

`endif // DMA_ENV_SV 

                              --─────────────────────────────────┐
                              │           dma_env                │
                              │                                  │
                              │  ┌──────────────────────────┐   │
                              │  │       cpu_agent          │   │
                              │  │   (ACTIVE)               │   │
                              │  │   ┌────────────┐         │   │
                              │  │   │ sequencer  │         │   │
                              │  │   └─────┬──────┘         │   │
                              │  │         │                │   │
                              │  │   ┌─────▼──────┐         │   │
                              │  │   │ driver     │         │   │
                              │  │   └────────────┘         │   │
                              │  │   ┌────────────┐         │   │
                              │  │   │ monitor    │──► ap ──┼───┼──► predictor
                              │  │   └────────────┘         │   │
                              │  └──────────────────────────┘   │
                              │                                 │
                              │  ┌──────────────────────────┐   │
                              │  │       dma_agent          │   │
                              │  │   (ACTIVE)               │   │
                              │  │   ┌────────────┐         │   │
                              │  │   │ sequencer  │         │   │
                              │  │   └─────┬──────┘         │   │
                              │  │   ┌─────▼──────┐         │   │
                              │  │   │ driver     │         │   │
                              │  │   └────────────┘         │   │
                              │  │   ┌────────────┐         │   │
                              │  │   │ monitor    │──► ap ──┼──┼──┐
                              │  │   └────────────┘         │   │  │
                              │  └──────────────────────────┘   │  │
                              │                                 │  │
                              │  ┌──────────────────────────┐   │  │
                              │  │  dma_reg_block (RAL)     │   │  │
                              │  │  dma_reg_adapter         │   │  │
                              │  │  dma_reg_predictor       │◄──┼──┘
                              │  └──────────────────────────┘   │
                              │                                 │
                              │  ┌──────────────────────────┐   │
                              │  │  dma_reference_model     │◄──┼──┐
                              │  │    expected_port ────────┼───┼──┼──► scoreboard.exp_export
                              │  └──────────────────────────┘   │  │
                              │                                 │  │
                              │  ┌──────────────────────────┐   │  │
                              │  │  dma_scoreboard          │◄──┼──┘
                              │  └──────────────────────────┘   │
                              │                                 │
                              │  ┌──────────────────────────┐   │
                              │  │  dma_coverage            │◄──┼──── (both agents)
                              │  └──────────────────────────┘   │
                              │                                 │
                              │  ┌──────────────────────────┐   │
                              │  │  dma_virtual_sequencer   │   │
                              │  │   (holds cpu_seqr,       │   │
                              │  │    dma_seqr, reg_model)  │   │
                              │  └──────────────────────────┘   │
                              └─────────────────────────────────┘
                                            │
                                            ▼
                                    Test / Sequences
