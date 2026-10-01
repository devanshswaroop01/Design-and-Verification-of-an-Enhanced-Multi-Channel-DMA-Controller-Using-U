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

## 🔢 Register Map

| Address     | Register                          | Width  | Access | Description                              |
|-------------|-----------------------------------|--------|--------|------------------------------------------|
| 0x00–0x07   | BASE_ADDR / BASE_WC               | 16-bit | R/W    | Channel base address and word count      |
| 0x08        | COMMAND / STATUS                  | 8-bit  | W/R    | Command and status access                |
| 0x09        | REQUEST                           | 8-bit  | W/R    | Software DMA request                     |
| 0x0A        | MASK_SINGLE                       | 8-bit  | W      | Single-channel mask control              |
| 0x0B        | MODE                              | 8-bit  | W      | Transfer-mode configuration              |
| 0x0C        | CLEAR_BYTE_PTR / SET_BYTE_PTR     | 8-bit  | W/R    | Byte-pointer control                     |
| 0x0D        | MASTER_CLEAR                      | 8-bit  | W      | Master-clear command                     |
| 0x0E        | CLEAR_MASK                        | 8-bit  | W      | Clear channel masks                      |
| 0x0F        | MASK_ALL / MASK_STATUS            | 8-bit  | W/R    | Full-channel mask control                |
| 0x10–0x13   | CH_CTRL                           | 8-bit  | R/W    | Per-channel control                      |
| 0x14–0x17   | BUF_SIZE                          | 16-bit | R/W    | Circular-buffer size                     |
| 0x18        | PRIORITY_CTRL                     | 24-bit | R/W    | Arbitration and priority configuration   |
| 0x19        | EXT_STATUS                        | 8-bit  | R      | Extended status                          |


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
│   ├── QUICKSTART.md            
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
├── Makefile                    
└── README.md
```

## 🚀 Quick Start

### Prerequisites

| Requirement | Version / Notes |
|---|---|
| **Simulator** | One of: Synopsys VCS (primary), QuestaSim, or Xcelium — must support SystemVerilog IEEE 1800-2017 |
| **UVM library** | UVM 1.2 (Accellera reference implementation) |
| **Build system** | GNU Make 4.0+ |
| **Waveform viewer** | Verdi, DVE, or EPWave (optional but recommended) |
| **OS** | Linux (tested on RHEL/CentOS/Ubuntu) |

> **Note:** The repository is primarily validated against Synopsys VCS. Other simulators may require minor script adjustments in `sim/`.

---

### 1. Clone the Repository

```bash
git clone https://github.com/<your-username>/dma-controller-uvm.git
cd dma-controller-uvm
```

### 2. Configure Environment

Set the UVM installation path and select your simulator:

```bash
export UVM_HOME=/path/to/uvm-1.2
export SIM=vcs          # options: vcs | questasim | xcelium
```

Add these to your `~/.bashrc` or `~/.zshrc` for persistence.

### 3. Verify Setup

```bash
make check
```

This verifies that `UVM_HOME` is set, the simulator binary is on `PATH`, and the file list resolves correctly.

### 4. Run Smoke Test

```bash
make smoke
```

Expected output (tail):
```
UVM_INFO  ...  [SMOKE] Reset sequence completed
UVM_INFO  ...  [SMOKE] Register write/readback passed
UVM_INFO  ...  [TEST_DONE] smoke_test PASSED
```

### 5. Run Individual Test

```bash
make test TEST=dma_transfer_test
```

Replace `dma_transfer_test` with any test from `tb/dma_test_library.sv`.

### 6. Run Full Regression

```bash
make all
```

Runs all 21 test families (83 sub-tests). Results are written to `sim/logs/` and a summary appears in `sim/reports/regression_summary.txt`.

### 7. View Waveforms

```bash
make wave
```

Opens the most recent waveform in Verdi/DVE. To open a specific test's waveform:

```bash
make wave TEST=dma_transfer_test
```

### 8. Clean Build Artifacts

```bash
make clean          # remove build outputs
make clean_all      # remove build outputs + logs + waveforms
```

---

### 📋 All Make Targets

| Target | Description |
|---|---|
| `make check` | Validate environment (UVM_HOME, simulator, filelist) |
| `make smoke` | Run quick smoke test |
| `make test TEST=<name>` | Run a single named test |
| `make all` | Run full regression (21 families / 83 sub-tests) |
| `make wave [TEST=<name>]` | Open waveform viewer |
| `make clean` | Remove build outputs |
| `make clean_all` | Remove build outputs + logs + waves |
| `make help` | Show all available targets |

---

### 🛠️ Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `make: *** No rule to make target 'smoke'` | Makefile missing or wrong directory | Ensure you are in the repo root (`cd dma-controller-uvm`) |
| `UVM_HOME is not set` | Environment not configured | Run `export UVM_HOME=/path/to/uvm-1.2` |
| `vcs: command not found` | Simulator not on `PATH` | Add simulator `bin/` to `PATH` |
| `Error: cannot find uvm_pkg.sv` | Wrong `UVM_HOME` path | Point `UVM_HOME` to the directory containing `src/uvm_pkg.sv` |
| Simulation hangs at time 0 | Reset not toggling | Check `dma_tb_top.sv` clock/reset generation |
| All tests report `UVM_FATAL` | UVM version mismatch | Confirm UVM 1.2 is being compiled (not 1.1d or 1800.2) |

---

### ✅ Next Steps After Quick Start

1. Read `docs/ARCHITECTURE.md` for RTL structure
2. Review `docs/VERIFICATION_PLAN.md` for test strategy
3. Inspect `docs/COVERAGE_REPORT.md` for coverage closure status
4. Explore `tb/dma_test_library.sv` to add custom tests 

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
                         │  ┌─────────────────────┐  │
                         │  │  Virtual Sequencer  │  │
                         │  └──────────┬──────────┘  │
                         │             │             │
                         │  ┌──────────┴──────────┐  │
                         │  │                     │  │
              ┌──────────┴──▼────┐   ┌────────────▼──┴────┐
              │   CPU Agent      │   │      DMA Agent      │
              │    ACTIVE        │   │       ACTIVE        │
              │ driver/monitor/  │   │ driver/monitor/     │
              │ sequencer        │   │ sequencer           │
              └──────────┬───────┘   └────────────┬────────┘
                         │                        │
                         └────────────┬───────────┘
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
| Component | Responsibility |
|---|---|
| `cpu_agent` | CPU-side register programming and observation |
| `dma_agent` | DMA request/handshake stimulus and observation |
| `dma_reg_block` | UVM RAL representation of the register set |
| `dma_reg_adapter` | RAL-to-bus transaction conversion |
| `dma_reg_predictor` | Updates RAL mirror from observed CPU activity |
| `dma_reference_model` | Independently predicts expected DMA behavior |
| `dma_scoreboard` | Compares expected and observed DMA transactions |
| `dma_coverage` | Transaction-level functional coverage |
| `dma_assertions` | Baseline protocol SVA |
| `dma_ext_assertions` | Extended feature-oriented SVA |
| `dma_ext_coverage` | Signal-level/bind-mounted coverage |
| `dma_virtual_sequencer` | Cross-agent coordination |
| `dma_env` | Top-level UVM verification environment |

## 🧾 Verification Test Matrix

The final verification campaign contains:

| Metric | Value |
|---|---|
| Test families | 21 |
| Sub-tests | 83 |
| Register checks | 400+ |
| CPU events | 1,962 |
| Real DMA transfers | 37 |
| Random operations | 222 |
| Stress iterations | 200 |

### Verification Areas

| Verification Area | Sub-Tests | Evidence |
|---|---|---|
| Reset | 6 | Reset and initialization testing |
| Register programming | 24 | Read/write and configuration checks |
| Byte-pointer | 6 | Multi-byte register access |
| Master clear | 4 | Global control behavior |
| Masking | 6 | Channel mask control |
| DMA handshake | 5 | DREQ → HRQ → HLDA → DACK |
| Fixed priority | 4 | Priority arbitration |
| Rotating priority | 4 | Rotating arbitration behavior |
| Adaptive-related modes | 6 | Configuration and selected activity |
| Circular buffer | 5 | Basic operation and rollover |
| Watermark | 3 | Threshold/status behavior |
| Overflow/underflow | 3 | Error-status behavior |
| Multi-channel | 3 | CH0–CH3 integrated activity |
| Random | 2 | Randomized register/configuration activity |
| Stress | 1 | Repeated mixed operations |
| Integrated transfer | 1 | End-to-end DMA transfer checking |
| **Total** | **83** | |


## 📊 Final Verification Results

### Scoreboard

The final DMA transfer comparison produced:

| Metric | Result |
|---|---|
| Expected DMA events | 37 |
| Observed DMA events | 37 |
| Scoreboard comparisons | 37 |
| Matches | 37 |
| Mismatches | 0 |

The 37/37 result applies to the DMA transfer comparisons performed by the integrated transfer test. It does not imply exhaustive verification of every DUT feature.

### Coverage

| Coverage Metric | Result |
|---|---|
| CPU-register coverage | 87.95% |
| DMA-transfer coverage | 52.22% |
| Overall transaction-level coverage | 61.01% |
| Protocol signal coverage | 76.25% |
| Extended-feature signal coverage | 66.31% |
| Combined signal-level coverage | 71.28% |

These values represent the peak coverage reached by the final verification campaign and should not be interpreted as exhaustive functional closure.

### ✅ Assertions

The final verification configuration contains:

| Metric | Result |
|---|---|
| Active assertions | 44 |
| Passing assertions | 44 |
| Assertion failures | 0 |
| Intentionally disabled assertions | 1 |
| Documented unimplemented assertion | 1 |

The assertions complement transaction-level checking and functional coverage rather than replacing them.

### 🔬 Multi-Channel Verification

The integrated DMA transfer test demonstrated transfer activity across all four channels.

| Channel | Initial Address | Final Address | Final Word Count |
|---|---|---|---|
| CH0 | 0x2000 | 0x2010 | 0x0010 |
| CH1 | 0x3000 | 0x3010 | 0x0010 |
| CH2 | 0x4000 | 0x4008 | 0x0008 |
| CH3 | 0x5000 | 0x5008 | 0x0008 |

This demonstrates observed activity on all four channels in the integrated transfer scenario.

It does not constitute exhaustive verification of every arbitration configuration or long-term fairness property.

## 🐛 Verification Findings and Debug History

The project underwent multiple RTL and UVM debugging iterations.

Fix IDs use the following convention:
- **M-prefix** — Verification methodology / model-related fix
- **R-prefix** — RTL / register-related fix

| Fix | Issue | Resolution |
|---|---|---|
| M1 | Circular-buffer outputs not visible at top level | Connected required outputs through `dma_top` |
| M2 | CH1–CH3 completion/timeout observation | Diagnosed and corrected |
| M3 | Aggregate completion masking per-channel activity | Added per-channel completion checks |
| M4 | Scoreboard dependence on DUT-observed values | Added independent expected-value comparison |
| M5 | Complete adaptive-feature reference modeling | Not expanded in current scope (documented) |
| R1 | Assertion timing windows | Corrected/widened required windows |
| R2 | Mask-register read/decode gap | Corrected decoder/read path |
| R3 | Reference-model completion/timeout prediction | Added |
| R4 | Missing transaction comparison fields | Added to `do_compare` |
| R5 | Missing CH1–CH3 coverage | Added per-channel coverage |
| R6 | RAL warning severity | Restored intended warning behavior |
| R7 | CPU-monitor post-edge sampling sensitivity | No reproducible final failure (documented) |

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

---

## ⚠️ Known Limitations

The final project is frozen for documentation and portfolio use, but the verification campaign does not claim exhaustive closure.

### Adaptive Arbitration

Weighted, rotating, dynamic and aging-related behavior is exercised to different extents. Exact long-term properties such as mathematical fairness, starvation freedom and weight-proportional service are not exhaustively demonstrated.

### Auto-Initialization

Automatic terminal-count reload behavior is outside the demonstrated verification evidence.

### Burst Operation

Burst configuration is exercised, but complete multi-transfer burst semantics are not exhaustively characterized.

### Circular Buffer

Additional combinations of buffer size, direction, occupancy, rollover boundaries and simultaneous operations require further verification.

### RAL / Byte-Pointer Abstraction

The physical byte-pointer protocol does not map naturally onto a conventional linear RAL representation. Direct byte-level sequences therefore remain necessary for protocol-sensitive operations.

### Reference Model

The reference model is not a complete executable specification of every enhanced feature.

### Coverage Closure

The reported 61.01% transaction-level and 71.28% signal-level coverage values represent the peak coverage reached by the current campaign.

### Register-Level Scoreboard

The primary scoreboard comparison is associated with DMA transfer events. Configuration-focused tests do not necessarily produce transfer-level scoreboard comparisons.

### Physical Implementation

The project focuses on RTL simulation and functional verification. It does not claim:

- post-layout timing closure
- physical area analysis
- power analysis
- CDC sign-off
- formal sign-off
- silicon validation

---

## 🚧 Future Work

- [ ] Extend adaptive arbitration reference modeling
- [ ] Add quantitative weighted/aging arbitration analysis
- [ ] Add exhaustive circular-buffer boundary scenarios
- [ ] Add complete burst-transfer verification
- [ ] Add auto-init / terminal-count reload verification
- [ ] Extend register-level independent scoreboard prediction
- [ ] Add additional constrained-random coverage crosses
- [ ] Extend assertion coverage for adaptive/aging semantics
- [ ] Perform synthesis and timing analysis
- [ ] Evaluate area and power
- [ ] Add CDC analysis
- [ ] Evaluate FPGA prototype implementation

---

## 🛠️ Tools and Technologies

| Technology / Tool | Purpose |
|---|---|
| SystemVerilog | RTL and verification language |
| UVM 1.2 | Verification methodology |
| Synopsys VCS | Primary simulation environment |
| QuestaSim | Simulation/debug compatibility |
| Verdi / DVE / EPWave | Waveform/debug analysis |
| Vivado / Quartus | Optional synthesis/FPGA analysis |
| Git | Version control |
| Make / Shell | Build and regression automation |

---

## 📚 Documentation

| Document | Description |
|---|---|
| ARCHITECTURE.md | RTL architecture, block diagrams and control flow |
| REGISTER_MAP.md | Register definitions and access behavior |
| VERIFICATION_PLAN.md | Verification strategy and test planning |
| ISSUES_LOG.md | Debug findings and issue history |
| FIX_HISTORY.md | Chronological verification corrections |
| LIMITATIONS.md | Known limitations and future work |
| COVERAGE_REPORT.md | Final coverage results |
| INTERVIEW_QA.md | Interview preparation material |  

## 🙏 Acknowledgments

- Intel 8237A DMA Controller documentation
- Accellera Systems Initiative — UVM 1.2
- IEEE SystemVerilog Standard — IEEE 1800

## 📬 Contact

- **Author:** Devansh Swaroop
- **Email:** devswa0000147@gmail.com
- **LinkedIn:** linkedin.com/in/your-actual-profile
