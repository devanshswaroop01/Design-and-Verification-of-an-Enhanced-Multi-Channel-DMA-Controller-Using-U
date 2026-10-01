//============================================================
// File        : cpu_agent_config.sv
// Description : CPU Agent Configuration Object
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_object (not uvm_component) — pure data.
//   2. Passed via uvm_config_db from test → agent.
//   3. Carries: virtual interface handle + mode + knobs.
//   4. Virtual interfaces CANNOT go into uvm_field_* macros
//      — UVM handles them specially.
//============================================================

`ifndef CPU_AGENT_CONFIG_SV
`define CPU_AGENT_CONFIG_SV

class cpu_agent_config extends uvm_object;

    //------------------------------------------------------------
    // Virtual interface — the bridge between TB and DUT
    //------------------------------------------------------------
    virtual dma_if vif;

    //------------------------------------------------------------
    // Agent mode
    //   UVM_ACTIVE  → driver + monitor + sequencer
    //   UVM_PASSIVE → monitor only
    //------------------------------------------------------------
    uvm_active_passive_enum is_active = UVM_ACTIVE;

    //------------------------------------------------------------
    // Component enables
    //------------------------------------------------------------
    bit has_coverage = 1'b1;

    //------------------------------------------------------------
    // Timing knob — idle cycles between consecutive accesses
    //------------------------------------------------------------
    int unsigned driver_delay = 1;

    //------------------------------------------------------------
    // UVM automation — registers the *scalar* fields only
    // (vif is intentionally NOT registered)
    //------------------------------------------------------------
    `uvm_object_utils_begin(cpu_agent_config)
        `uvm_field_enum(uvm_active_passive_enum, is_active,   UVM_ALL_ON)
        `uvm_field_int (has_coverage,                         UVM_ALL_ON)
        `uvm_field_int (driver_delay,                         UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "cpu_agent_config");
        super.new(name);
    endfunction

endclass

`endif // CPU_AGENT_CONFIG_SV
