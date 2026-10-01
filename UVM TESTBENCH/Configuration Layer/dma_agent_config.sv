//============================================================
// File        : dma_agent_config.sv
// Description : DMA Agent Configuration Object
//============================================================
// INTERVIEW POINTS:
//   1. Same pattern as cpu_agent_config — just fewer fields.
//   2. Defaults to UVM_ACTIVE (agent drives DREQ/HLDA).
//   3. Passive mode available for system-level integration.
//============================================================

`ifndef DMA_AGENT_CONFIG_SV
`define DMA_AGENT_CONFIG_SV

class dma_agent_config extends uvm_object;

    virtual dma_if vif;

    // Default ACTIVE — this agent drives DREQ/HLDA
    uvm_active_passive_enum is_active = UVM_ACTIVE;

    bit has_coverage = 1'b1;

    `uvm_object_utils_begin(dma_agent_config)
        `uvm_field_enum(uvm_active_passive_enum, is_active,   UVM_ALL_ON)
        `uvm_field_int (has_coverage,                         UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "dma_agent_config");
        super.new(name);
    endfunction

endclass

`endif // DMA_AGENT_CONFIG_SV
