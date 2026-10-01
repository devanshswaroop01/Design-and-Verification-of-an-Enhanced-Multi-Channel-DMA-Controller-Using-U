//============================================================
// File        : dma_reg_adapter.sv
// Description : UVM RAL Adapter for DMA Controller
//               Translates:
//                  RAL → bus (reg2bus)  : uvm_reg_bus_op → cpu_seq_item
//                  bus → RAL (bus2reg)  : cpu_seq_item → uvm_reg_bus_op
//============================================================
// INTERVIEW POINTS:
//   1. Extends uvm_reg_adapter — the standard RAL bridge.
//   2. Two mandatory methods:
//        reg2bus() : RAL wants to read/write → produce a bus item
//        bus2reg() : bus returned data      → update RAL rw
//   3. reg2bus() takes `const ref` — READ-only (can't modify rw)
//   4. bus2reg() takes `ref` — WRITABLE (writes back rw.data)
//   5. supports_byte_enable / provides_responses = 0 for this bus.
//============================================================

`ifndef DMA_REG_ADAPTER_SV
`define DMA_REG_ADAPTER_SV

class dma_reg_adapter extends uvm_reg_adapter;

    //------------------------------------------------------------
    // Optional: handle to the CPU sequencer (not strictly needed;
    // RAL uses the sequencer set via uvm_reg_map::set_sequencer).
    //------------------------------------------------------------
    uvm_sequencer #(cpu_seq_item) cpu_seqr;

    `uvm_object_utils(dma_reg_adapter)

    //------------------------------------------------------------
    // CONSTRUCTOR
    //------------------------------------------------------------
    function new(string name = "dma_reg_adapter");
        super.new(name);
        supports_byte_enable = 0;   // DMA bus has no byte enables
        provides_responses   = 0;   // Adapter does not consume responses
    endfunction

    function void set_sequencer(uvm_sequencer #(cpu_seq_item) s);
        cpu_seqr = s;
    endfunction

    //============================================================
    // REG 2 BUS  (RAL → bus)
    //============================================================
    // Called by the RAL framework when you do reg.read()/reg.write():
    //   1. RAL builds uvm_reg_bus_op (kind, addr, data)
    //   2. RAL calls reg2bus() to get a bus transaction
    //   3. RAL sends the transaction through the sequencer
    //
    // NOTE: `rw` is `const ref` → must NOT be modified here.
    //       Any attempt to set rw.data/rw.status will fail to compile.
    //------------------------------------------------------------
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);

        cpu_seq_item item;
        logic [4:0]  addr;

        // DMA register address is 5-bit (0x00–0x1F).
        addr = rw.addr[4:0];

        //--------------------------------------------------------
        // Build the item based on direction
        //--------------------------------------------------------
        if (rw.kind == UVM_READ) begin
            item = cpu_seq_item::type_id::create("read_item");
            item.is_read = 1'b1;
            item.addr    = addr;
            item.data    = 8'h00;         // placeholder; sampled in bus2reg

            `uvm_info("ADP",
                $sformatf("reg2bus READ  addr=0x%02X", addr),
                UVM_HIGH)
        end else begin
            item = cpu_seq_item::type_id::create("write_item");
            item.is_read = 1'b0;
            item.addr    = addr;
            item.data    = rw.data[7:0];  // take low 8 bits from RAL

            `uvm_info("ADP",
                $sformatf("reg2bus WRITE addr=0x%02X data=0x%02X",
                          addr, rw.data[7:0]),
                UVM_HIGH)
        end

        return item;
    endfunction

    //============================================================
    // BUS 2 REG  (bus → RAL)
    //============================================================
    // Called by the RAL framework after the driver finishes.
    // The driver's returned cpu_seq_item is unpacked into `rw`.
    //
    // NOTE: `rw` is `ref` (NOT const) — this is where read data
    //       is captured and returned to the caller of reg.read().
    //------------------------------------------------------------
    virtual function void bus2reg(uvm_sequence_item bus_item,
                                  ref uvm_reg_bus_op rw);

        cpu_seq_item item;

        // Type-safety: ensure the returned item is what we expected
        if (!$cast(item, bus_item)) begin
            `uvm_fatal("ADP", "bus_item is not a cpu_seq_item")
        end

        rw.kind    = item.is_read ? UVM_READ : UVM_WRITE;
        rw.addr    = {27'b0, item.addr};    // zero-extend 5→32
        rw.data    = {56'b0, item.data};    // zero-extend 8→64
        rw.byte_en = '1;                    // all bytes enabled
        rw.status  = UVM_IS_OK;

        `uvm_info("ADP",
            $sformatf("bus2reg  %s addr=0x%02X data=0x%02X",
                      item.is_read ? "READ" : "WRITE",
                      item.addr, item.data),
            UVM_HIGH)
    endfunction

endclass

`endif // DMA_REG_ADAPTER_SV

// Why the Adapter Exists
//    Test               RAL Model        Adapter         Sequencer       Driver        DUT
//     │                    │                │                │              │            │
//     │ reg.write(addr,..) │                │                │              │            │
//     │───────────────────►│                │                │              │            │
//     │                    │ uvm_reg_bus_op │                │              │            │
//     │                    │───────────────►│                │              │            │
//     │                    │                │  reg2bus()     │              │            │
//     │                    │                │  cpu_seq_item  │              │            │
//     │                    │                │───────────────►│              │            │
//     │                    │                │                │ item         │            │
//     │                    │                │                │─────────────►│            │
//     │                    │                │                │              │ bus cycle  │
//     │                    │                │                │              │───────────►│
//     │                    │                │                │              │◄───────────│
//     │                    │                │  bus2reg()     │              │            │
//     │                    │◄───────────────│◄───────────────│◄─────────────│            │
//     │◄───────────────────│  rw.data       │                │              │            │

