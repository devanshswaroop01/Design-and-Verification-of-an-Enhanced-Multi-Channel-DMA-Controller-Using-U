# Enhanced Multi-Channel DMA Controller

### Design and UVM-Based Verification with Adaptive Arbitration and Circular Transfer Support

[![Language](https://img.shields.io/badge/Language-SystemVerilog-blue.svg)](https://en.wikipedia.org/wiki/SystemVerilog)
[![UVM](https://img.shields.io/badge/UVM-1.2-green.svg)](https://www.accellera.org/downloads/standards/uvm)
[![Simulator](https://img.shields.io/badge/Simulator-Synopsys%20VCS-lightgrey.svg)]()
[![Verification](https://img.shields.io/badge/Verification-21%20Test%20Families%20%7C%2083%20Sub--Tests-brightgreen.svg)]()
[![Status](https://img.shields.io/badge/Status-Frozen%20%7C%20Documented-brightgreen.svg)]()

---

## 📖 Overview

This repository contains the RTL design and UVM-based verification environment for an **enhanced four-channel DMA controller inspired by the Intel 8237A architecture**.

The design extends the classical programmable DMA concept with:

- Four independently configurable DMA channels
- Programmable address and word-count registers
- Byte-pointer based multi-byte register access
- Fixed and rotating arbitration behavior
- Adaptive-related arbitration controls
- Per-channel circular-buffer support
- Rollover and watermark monitoring
- Overflow/underflow status
- Extended channel/status registers
- Burst-related configuration
- UVM 1.2 verification infrastructure
- Reference-model based checking
- Independent scoreboard comparison
- SystemVerilog Assertions (SVA)
- Transaction-level and signal-level functional coverage

> **Scope note:** The controller is **8237-inspired**. This project does not claim complete architectural or behavioral conformance with the original Intel 8237A device.

---

# 🎯 Project Highlights

| Feature | Description |
|---|---|
| **4 DMA channels** | CH0–CH3 with independent channel configuration |
| **16-bit address path** | Programmable DMA address handling |
| **8-bit data path** | Byte-oriented CPU/DMA interface |
| **26-register architecture** | Register space from `0x00` to `0x19` |
| **Byte-pointer protocol** | Multi-byte registers accessed using sequential byte-pointer operations |
| **Adaptive arbitration** | Fixed / rotating / adaptive-related arbitration controls |
| **Circular buffers** | Per-channel buffer size, rollover, watermark and error monitoring |
| **Extended status** | Rollover, watermark, overflow and underflow status |
| **UVM 1.2** | CPU/DMA agents, RAL, reference model, scoreboard and coverage |
| **Independent checking** | Expected values generated separately from DUT observations |
| **44 active assertions** | Protocol and selected feature-oriented SVA |
| **21 test families** | 83 defined sub-tests |
| **37 DMA transfers** | Observed transfer events used for final scoreboard comparison |

---

# 🏗️ Architecture

## Overall Architecture

```text
                         ┌─────────────────────────────────────┐
                         │              DMA TOP                │
                         │                                     │
                         │  ┌──────────────┐ ┌──────────────┐  │
CPU / Software ─────────►│  │ Command /    │ │ DMA Register │  │
                         │  │ Register     │►│ File         │  │
                         │  │ Decoder      │ │ 26 Registers │  │
                         │  └──────────────┘ └──────┬───────┘  │
                         │                          │          │
                         │              ┌───────────▼────────┐ │
                         │              │ Channel / Priority │ │
                         │              │ Control            │ │
                         │              └───────────┬────────┘ │
                         │                          │          │
DREQ0 ──────────────────►│                          ▼          │
DREQ1 ──────────────────►│                 ┌────────────────┐  │
DREQ2 ──────────────────►│                 │ Arbitration /  │  │
DREQ3 ──────────────────►│                 │ Priority Logic │  │
                         │                 └───────┬────────┘  │
                         │                         │           │
                         │                         ▼           │
                         │                 ┌────────────────┐  │
                         │                 │ DMA Control    │  │
                         │                 │ FSM            │  │
                         │                 └───────┬────────┘  │
                         │                         │           │
                         │                         ▼           │
                         │                 ┌────────────────┐  │
                         │                 │ DMA Datapath / │  │
                         │                 │ Address Logic  │  │
                         │                 └───────┬────────┘  │
                         │                         │           │
                         │                         ▼           │
                         │                 ┌────────────────┐  │
                         │                 │ Circular Buffer│  │
                         │                 │ / Status Logic │  │
                         │                 └────────────────┘  │
                         └─────────────────────────────────────┘
```

DMA Transfer Flow
```text
             Channel Request
                  │
                  ▼
             DREQ / REQ
                  │
                  ▼
          Request Qualification
                  │
                  ▼
                 HRQ
                  │
                  ▼
                HLDA
                  │
                  ▼
          Channel Grant / DACK
                  │
                  ▼
             Address Phase
                  │
                  ▼
          Read / Write Phase
                  │
                  ▼
             XFER_PULSE
                  │
                  ▼
       Address / Word Count Update
                  │
          ┌───────┴────────┐
          │                │
          ▼                ▼
      Completion       Rollover
          │                │
          └───────┬────────┘
                  ▼
             Next Request
```

🔢 Register Map
Address	Register	Width	Access	Description
0x00–0x07	BASE_ADDR / BASE_WC	16-bit	R/W	Channel base address and word count
0x08	COMMAND / STATUS	8-bit	W/R	Command and status access
0x09	REQUEST	8-bit	W/R	Software DMA request
0x0A	MASK_SINGLE	8-bit	W	Single-channel mask control
0x0B	MODE	8-bit	W	Transfer-mode configuration
0x0C	CLEAR_BYTE_PTR / SET_BYTE_PTR	8-bit	W/R	Byte-pointer control
0x0D	MASTER_CLEAR	8-bit	W	Master-clear command
0x0E	CLEAR_MASK	8-bit	W	Clear channel masks
0x0F	MASK_ALL / MASK_STATUS	8-bit	W/R	Full-channel mask control
0x10–0x13	CH_CTRL	8-bit	R/W	Per-channel control
0x14–0x17	BUF_SIZE	16-bit	R/W	Circular-buffer size
0x18	PRIORITY_CTRL	24-bit	R/W	Arbitration and priority configuration
0x19	EXT_STATUS	8-bit	R	Extended status

📁 Repository Structure

```text
dma-controller-uvm/
│
├── rtl/
│   ├── dma_reg_pkg.sv
│   ├── dma_if.sv
│   ├── dma_control_if.sv
│   ├── dma_sw_commands.sv
│   ├── dma_regfile.sv
│   ├── dma_datapath.sv
│   ├── dma_control.sv
│   ├── dma_priority.sv
│   ├── dma_adaptive_arbiter.sv
│   ├── dma_circular_buffer.sv
│   └── dma_top.sv
│
├── tb/
│   ├── dma_uvm_pkg.sv
│   ├── cpu_seq_item.sv
│   ├── dma_seq_item.sv
│   ├── cpu_agent_config.sv
│   ├── dma_agent_config.sv
│   ├── cpu_sequencer.sv
│   ├── dma_sequencer.sv
│   ├── dma_reg_block.sv
│   ├── dma_reg_adapter.sv
│   ├── dma_reg_predictor.sv
│   ├── cpu_driver.sv
│   ├── cpu_monitor.sv
│   ├── cpu_agent.sv
│   ├── dma_driver.sv
│   ├── dma_monitor.sv
│   ├── dma_agent.sv
│   ├── dma_reference_model.sv
│   ├── dma_scoreboard.sv
│   ├── dma_coverage.sv
│   ├── dma_virtual_sequencer.sv
│   ├── dma_env.sv
│   ├── dma_sequence_library.sv
│   ├── dma_test_library.sv
│   ├── dma_assertions.sv
│   ├── dma_ext_assertions.sv
│   ├── dma_ext_coverage_sv.sv
│   └── dma_tb_top.sv
│
├── sim/
│   ├── run_all.sh
│   ├── run_smoke.sh
│   ├── filelist.f
│   └── waves/
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── REGISTER_MAP.md
│   ├── VERIFICATION_PLAN.md
│   ├── ISSUES_LOG.md
│   ├── FIX_HISTORY.md
│   ├── LIMITATIONS.md
│   ├── COVERAGE_REPORT.md
│   └── INTERVIEW_QA.md
│
├── images/
│   ├── block_diagram.png
│   ├── fsm_diagram.png
│   ├── verification_flow.png
│   └── waveforms/
│
├── LICENSE
└── README.md
```

🚀 Quick Start
Prerequisites
SystemVerilog IEEE 1800-compatible simulator
Synopsys VCS / QuestaSim / Xcelium
UVM 1.2
GNU Make or equivalent build system
Waveform viewer such as Verdi, DVE or EPWave
Clone Repository
git clone https://github.com/<user>/dma-controller-uvm.git
cd dma-controller-uvm
Configure UVM
export UVM_HOME=/path/to/uvm-1.2
export SIM=vcs
Run Smoke Test
make smoke
Run Individual Test
make test TEST=dma_transfer_test
Run Regression
make all
Open Waveforms
make wave 

🧪 UVM Verification Environment
Verification Architecture

```text
                         ┌─────────────────────────────┐
                         │          dma_tb_top         │
                         │                             │
                         │ CLK / RESET / dma_if / DUT  │
                         └──────────────┬──────────────┘
                                        │
                         ┌──────────────▼────────────┐
                         │           dma_env         │
                         │                           │
              ┌──────────┴──────────┐   ┌────────────┴────────┐
              │     CPU Agent       │   │      DMA Agent      │
              │      ACTIVE         │   │       ACTIVE        │
              │ driver/monitor/seqr │   │ driver/monitor/seqr │
              └──────────┬──────────┘   └────────────┬────────┘
                         │                           │
                         └────────────┬──────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │      RAL Predictor      │
                         └────────────┬────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │    Reference Model      │
                         │   Expected Prediction   │
                         └────────────┬────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │       Scoreboard        │
                         │ Independent Comparison  │
                         └────────────┬────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │ Coverage + Assertions   │
                         └─────────────────────────┘
```
Component Responsibilities
Component	Responsibility
cpu_agent	CPU-side register programming and observation
dma_agent	DMA request/handshake stimulus and observation
dma_reg_block	UVM RAL representation of the register set
dma_reg_adapter	RAL-to-bus transaction conversion
dma_reg_predictor	Updates RAL mirror from observed CPU activity
dma_reference_model	Independently predicts expected DMA behavior
dma_scoreboard	Compares expected and observed DMA transactions
dma_coverage	Transaction-level functional coverage
dma_assertions	Baseline protocol SVA
dma_ext_assertions	Extended feature-oriented SVA
dma_ext_coverage_sv	Signal-level/bind-mounted coverage
dma_virtual_sequencer	Cross-agent coordination
dma_env	Top-level UVM verification environment


🧾 Verification Test Matrix

The final verification campaign contains:

21 test families
83 sub-tests
400+ register checks
1,962 CPU events
37 real DMA transfers
222 random operations
200 stress iterations
Verification Area	Evidence
Reset	Reset and initialization testing
Register programming	Read/write and configuration checks
Byte-pointer	Multi-byte register access
Master clear	Global control behavior
Masking	Channel mask control
DMA handshake	DREQ → HRQ → HLDA → DACK
Fixed priority	Priority arbitration
Rotating priority	Rotating arbitration behavior
Adaptive-related modes	Configuration and selected activity
Circular buffer	Basic operation and rollover
Watermark	Threshold/status behavior
Overflow/underflow	Error-status behavior
Multi-channel	CH0–CH3 integrated activity
Random	Randomized register/configuration activity
Stress	Repeated mixed operations
Integrated transfer	End-to-end DMA transfer checking

📊 Final Verification Results
Scoreboard

The final DMA transfer comparison produced:

Metric	Result
Expected DMA events	37
Observed DMA events	37
Scoreboard comparisons	37
Matches	37
Mismatches	0

The 37/37 result applies to the DMA transfer comparisons performed by the integrated transfer test. It does not imply exhaustive verification of every DUT feature.

Coverage
Coverage Metric	Result
CPU-register coverage	87.95%
DMA-transfer coverage	52.22%
Overall transaction-level coverage	61.01%
Protocol signal coverage	76.25%
Extended-feature signal coverage	66.31%
Combined signal-level coverage	71.28%

These values represent the peak coverage reached by the final verification campaign and should not be interpreted as exhaustive functional closure.

✅ Assertions

The final verification configuration contains:

Metric	Result
Active assertions	44
Passing assertions	44
Assertion failures	0
Intentionally disabled assertions	1
Documented unimplemented assertion	1

The assertions complement transaction-level checking and functional coverage rather than replacing them.

🔬 Multi-Channel Verification

The integrated DMA transfer test demonstrated transfer activity across all four channels.

Channel	Initial Address	Final Address	Final Word Count
CH0	0x1000	0x1028	0x0058
CH1	0x2000	0x2028	0x0058
CH2	0x3000	0x3028	0x0058
CH3	0x4000	0x4028	0x0058

This demonstrates observed activity on all four channels in the integrated transfer scenario.

It does not constitute exhaustive verification of every arbitration configuration or long-term fairness property.

🐛 Verification Findings and Debug History

The project underwent multiple RTL and UVM debugging iterations.

Important verification corrections included:

Fix	Issue	Resolution
M1	Circular-buffer outputs not visible at top level	Connected required outputs through dma_top
M2	CH1–CH3 completion/timeout observation	Diagnosed and corrected
M3	Aggregate completion masking per-channel activity	Added per-channel completion checks
M4	Scoreboard dependence on DUT-observed values	Added independent expected-value comparison
R1	Assertion timing windows	Corrected/widened required windows
R2	Mask-register read/decode gap	Corrected decoder/read path
R3	Reference-model completion/timeout prediction	Added
R4	Missing transaction comparison fields	Added to do_compare
R5	Missing CH1–CH3 coverage	Added per-channel coverage
R6	RAL warning severity	Restored intended warning behavior

The important engineering principle was to distinguish:

```text
Observed failure
      ↓
Root-cause isolation
      ↓
Targeted correction
      ↓
Regression verification
      ↓
Evidence-based closure
```

⚠️ Known Limitations

The final project is frozen for documentation and portfolio use, but the verification campaign does not claim exhaustive closure.

Adaptive Arbitration

Weighted, rotating, dynamic and aging-related behavior is exercised to different extents. Exact long-term properties such as mathematical fairness, starvation freedom and weight-proportional service are not exhaustively demonstrated.

Auto-Initialization

Automatic terminal-count reload behavior is outside the demonstrated verification evidence.

Burst Operation

Burst configuration is exercised, but complete multi-transfer burst semantics are not exhaustively characterized.

Circular Buffer

Additional combinations of buffer size, direction, occupancy, rollover boundaries and simultaneous operations require further verification.

RAL / Byte-Pointer Abstraction

The physical byte-pointer protocol does not map naturally onto a conventional linear RAL representation. Direct byte-level sequences therefore remain necessary for protocol-sensitive operations.

Reference Model

The reference model is not a complete executable specification of every enhanced feature.

Coverage Closure

The reported 61.01% transaction-level and 71.28% signal-level coverage values represent the peak coverage reached by the current campaign.

Register-Level Scoreboard

The primary scoreboard comparison is associated with DMA transfer events. Configuration-focused tests do not necessarily produce transfer-level scoreboard comparisons.

Physical Implementation

The project focuses on RTL simulation and functional verification. It does not claim:

post-layout timing closure
physical area analysis
power analysis
CDC sign-off
formal sign-off
silicon validation

 
🚧 Future Work
 Extend adaptive arbitration reference modeling
 Add quantitative weighted/aging arbitration analysis
 Add exhaustive circular-buffer boundary scenarios
 Add complete burst-transfer verification
 Add auto-init / terminal-count reload verification
 Extend register-level independent scoreboard prediction
 Add additional constrained-random coverage crosses
 Extend assertion coverage for adaptive/aging semantics
 Perform synthesis and timing analysis
 Evaluate area and power
 Add CDC analysis
 Evaluate FPGA prototype implementation

 
🛠️ Tools and Technologies
Technology / Tool	Purpose
SystemVerilog	RTL and verification language
UVM 1.2	Verification methodology
Synopsys VCS	Primary simulation environment
QuestaSim	Simulation/debug compatibility
Verdi / DVE / EPWave	Waveform/debug analysis
Vivado / Quartus	Optional synthesis/FPGA analysis
Git	Version control
Make / Shell	Build and regression automation


📚 Documentation
Document	Description
ARCHITECTURE.md	RTL architecture, block diagrams and control flow
REGISTER_MAP.md	Register definitions and access behavior
VERIFICATION_PLAN.md	Verification strategy and test planning
ISSUES_LOG.md	Debug findings and issue history
FIX_HISTORY.md	Chronological verification corrections
LIMITATIONS.md	Known limitations and future work
COVERAGE_REPORT.md	Final coverage results
INTERVIEW_QA.md	Interview preparation material 



🎓 Interview-Ready Highlights

This project demonstrates experience with:

RTL Design
Multi-channel DMA architecture
Control-FSM design
Register-file design
Byte-pointer protocols
Arbitration logic
Circular-buffer logic
Address/count management
Status/error generation
Design Verification
UVM agents
Sequencers and drivers
Monitors
UVM RAL
Reference models
Independent scoreboards
Functional coverage
SystemVerilog Assertions
Randomized and stress testing
Debugging

The project emphasizes a traceable debugging methodology:

```text
Symptom Classification
        ↓
Root-Cause Isolation
        ↓
Targeted Fix
        ↓
Regression
        ↓
Evidence
        ↓
Documentation
```

The verification process specifically addressed issues involving:

Multi-channel completion observation
Scoreboard independence
Circular-buffer observability
Assertion timing
Register decoding
Reference-model prediction
Transaction comparison
Coverage completeness


📈 Project Statistics
Metric	Final Value
DMA channels	4
Registers	26
Control FSM states	9
Test families	21
Sub-tests	83
CPU bus events	1,962
Real DMA transfers	37
Scoreboard matches	37 / 37
Scoreboard mismatches	0
Random operations	222
Stress iterations	200
Active assertions	44
Passing assertions	44
Peak CPU-register coverage	87.95%
Peak DMA-transfer coverage	52.22%
Peak transaction-level coverage	61.01%
Peak signal-level coverage	71.28%


🏆 Portfolio Summary

Enhanced Multi-Channel DMA Controller — RTL + UVM Verification

A four-channel, 8237-inspired DMA controller implemented in synthesizable SystemVerilog and verified using a structured UVM environment.

The project combines:
```text

RTL Design
   +
Programmable DMA Architecture
   +
Adaptive Arbitration
   +
Circular Buffer Support
   +
UVM Verification
   +
RAL
   +
Reference Model
   +
Independent Scoreboard
   +
Assertions
   +
Functional Coverage
   +
Random / Stress Verification
```
The final verification evidence includes 21 test families, 83 sub-tests, 1,962 CPU events, 37 observed DMA transfers, 37/37 scoreboard matches, 44/44 active assertions passing, 87.95% CPU-register coverage, 61.01% peak transaction-level coverage, and 71.28% peak signal-level coverage.



🙏 Acknowledgments
Intel 8237A DMA Controller documentation
Accellera Systems Initiative — UVM 1.2
IEEE SystemVerilog Standard — IEEE 1800
Course mentors and technical reviewers
📬 Contact

Author: [Your Name]
Email: [your.email@example.com]
LinkedIn: linkedin.com/in/your-profile
Portfolio: your-portfolio-site.com
