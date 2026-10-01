//============================================================
// File        : dma_virtual_sequencer.sv
// Description : UVM Virtual Sequencer
//               Holds handles to agent sequencers + RAL model
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_sequencer (generic, no item type).
//   2. Holds handles (not ports) to child sequencers.
//   3. Virtual sequences access agent sequencers via
//      p_sequencer.<handle>.start(...).
//   4. Also carries reg_model handle for register-aware sequences.
//   5. Handles populated in env's connect_phase.
//============================================================

`ifndef DMA_VIRTUAL_SEQUENCER_SV
`define DMA_VIRTUAL_SEQUENCER_SV

class dma_virtual_sequencer extends uvm_sequencer;

    //------------------------------------------------------------
    // Child sequencer handles (populated by env)
    //------------------------------------------------------------
    uvm_sequencer #(cpu_seq_item)  cpu_seqr;
    uvm_sequencer #(dma_seq_item)  dma_seqr;    // null in passive mode

    //------------------------------------------------------------
    // RAL model handle (for register-aware sequences)
    //------------------------------------------------------------
    dma_reg_block reg_model;

    `uvm_component_utils(dma_virtual_sequencer)

    function new(string name = "dma_virtual_sequencer",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //============================================================
    // BUILD PHASE — fetch RAL model
    //============================================================
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(dma_reg_block)::get(this, "", "reg_model", reg_model)) begin
            `uvm_info("VSEQR",
                "No reg_model in config_db — RAL access from virtual sequences disabled",
                UVM_MEDIUM)
        end
    endfunction

endclass

`endif // DMA_VIRTUAL_SEQUENCER_SV

