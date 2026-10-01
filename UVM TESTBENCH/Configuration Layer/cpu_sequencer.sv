//============================================================
// File        : cpu_sequencer.sv
// Description : CPU Sequencer Typedef
//============================================================
// INTERVIEW POINTS:
//   1. Just a typedef — no custom class needed.
//   2. uvm_sequencer #(item_type) is generic in UVM.
//   3. Typedef improves readability + avoids repeating the
//      full parametrized type everywhere.
//============================================================

`ifndef CPU_SEQUENCER_SV
`define CPU_SEQUENCER_SV

// Typed sequencer: routes cpu_seq_item from sequences → driver
typedef uvm_sequencer #(cpu_seq_item) cpu_sequencer;

`endif // CPU_SEQUENCER_SV
