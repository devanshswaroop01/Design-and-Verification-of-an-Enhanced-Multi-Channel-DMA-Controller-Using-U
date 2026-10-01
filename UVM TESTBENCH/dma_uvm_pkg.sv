//============================================================
// File        : dma_uvm_pkg.sv
// Description : UVM Verification Package for DMA Controller
//               Central compilation manifest.
//============================================================
// INTERVIEW POINTS:
//   1. A UVM package = one namespace for all verification classes.
//   2. Compile ORDER matters — `include order defines dependencies.
//   3. Typical order: items → config → RAL → agents → env →
//      sequences → tests.
//   4. This package must be compiled AFTER RTL packages and
//      interfaces, and BEFORE the top TB module.
//   5. Commented-out includes = files merged into *_library.sv
//      (common refactor when too many small files hurt build time).
//============================================================

`ifndef DMA_UVM_PKG_SV
`define DMA_UVM_PKG_SV

package dma_uvm_pkg;

    //============================================================
    // SECTION 1: UVM LIBRARY
    //============================================================
    // Import UVM base classes first — everything else depends on it.
    // `uvm_macros.svh` provides `uvm_object_utils`, `uvm_component_utils`,
    // `uvm_info`, `uvm_error`, etc.
    //------------------------------------------------------------
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    //============================================================
    // SECTION 2: RTL REGISTER PACKAGE
    //============================================================
    // Import RTL register definitions so sequence items and RAL
    // can reference register addresses and field structs.
    //------------------------------------------------------------
    import dma_reg_pkg::*;

    //============================================================
    // SECTION 3: TRANSACTION ITEMS
    //============================================================
    // Sequence items are the smallest unit of stimulus/observation.
    //   cpu_seq_item : CPU bus read/write transaction
    //   dma_seq_item : DMA transfer descriptor / observation
    // Must be compiled FIRST among user classes — everything
    // downstream (drivers, monitors, sequences) uses them.
    //------------------------------------------------------------
    `include "cpu_seq_item.sv"
    `include "dma_seq_item.sv"

    //============================================================
    // SECTION 4: CONFIGURATION OBJECTS
    //============================================================
    // Config classes carry agent/environment settings (active/
    // passive mode, interface handles, knobs). Compiled after
    // items, before agents (agents consume config).
    //------------------------------------------------------------
    `include "cpu_agent_config.sv"
    `include "dma_agent_config.sv"

    //============================================================
    // SECTION 5: SEQUENCER TYPEDEFS
    //============================================================
    // Sequencers are typed (`uvm_sequencer #(item_type)`).
    // Typedefs must exist before drivers/agents instantiate them.
    //------------------------------------------------------------
    `include "cpu_sequencer.sv"
    `include "dma_sequencer.sv"

    //============================================================
    // SECTION 6: RAL MODEL
    //============================================================
    // Register Abstraction Layer compilation order:
    //   1. Block   — the register map hierarchy
    //   2. Adapter — converts uvm_reg_bus_op ↔ cpu_seq_item
    //   3. Predictor — updates mirror on observed bus activity
    //------------------------------------------------------------
    `include "dma_reg_block.sv"
    `include "dma_reg_adapter.sv"
    `include "dma_reg_predictor.sv"

    //============================================================
    // SECTION 7: AGENT COMPONENTS
    //============================================================
    // Order within each agent: driver → monitor → agent.
    //   Agent class uses both driver and monitor handles,
    //   so both must be defined first.
    //------------------------------------------------------------
    // CPU agent (ACTIVE — drives stimulus)
    `include "cpu_driver.sv"
    `include "cpu_monitor.sv"
    `include "cpu_agent.sv"

    // DMA agent (mostly PASSIVE — observes DUT DMA-side behavior)
    `include "dma_driver.sv"      // present but may be stubbed in passive mode
    `include "dma_monitor.sv"
    `include "dma_agent.sv"

    //============================================================
    // SECTION 8: ENVIRONMENT COMPONENTS
    //============================================================
    // Env-level order: helpers (ref model, scoreboard, coverage)
    // first, then virtual sequencer, then env (which contains all).
    //------------------------------------------------------------
    `include "dma_reference_model.sv"   // golden model
    `include "dma_scoreboard.sv"        // comparator
    `include "dma_coverage.sv"          // functional coverage
    `include "dma_virtual_sequencer.sv" // coord across agents
    `include "dma_env.sv"               // top of UVM env

    //============================================================
    // SECTION 9: SEQUENCES
    //============================================================
    // NOTE: Many individual sequence files have been MERGED into
    // one big `dma_sequence_library.sv` to reduce compile time
    // and file count. The commented-out `include` lines are kept
    // for reference / history.
    //------------------------------------------------------------
    // (Legacy — merged into library)
    // `include "dma_base_sequence.sv"
    // ... [baseline + extended sequences] ...

    `include "dma_sequence_library.sv"  // ← the actual live file

    //============================================================
    // SECTION 10: TESTS
    //============================================================
    // Same pattern: many test files merged into
    // `dma_test_library.sv`. Tests must be compiled LAST —
    // they depend on everything (env, sequences, configs).
    //------------------------------------------------------------
    // (Legacy — merged into library)
    // `include "dma_base_test.sv"
    // ... [baseline + extended tests] ...

    `include "dma_test_library.sv"      // ← the actual live file

endpackage : dma_uvm_pkg

`endif // DMA_UVM_PKG_SV
