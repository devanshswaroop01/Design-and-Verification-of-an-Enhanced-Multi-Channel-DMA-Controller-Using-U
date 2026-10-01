//============================================================
// File        : dma_sequencer.sv
// Description : DMA Sequencer Typedef
//============================================================
// INTERVIEW POINTS:
//   1. Currently NOT instantiated — the DMA agent is passive.
//   2. Kept as a hook for future active DMA stimulus generation.
//   3. Same typedef pattern as CPU sequencer.
//============================================================

`ifndef DMA_SEQUENCER_SV
`define DMA_SEQUENCER_SV

// Typed sequencer: routes dma_seq_item from sequences → driver
typedef uvm_sequencer #(dma_seq_item) dma_sequencer;

`endif // DMA_SEQUENCER_SV
