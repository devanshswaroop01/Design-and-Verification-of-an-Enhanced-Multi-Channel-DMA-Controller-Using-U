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
                         │              DMA TOP                 │
                         │                                     │
                         │  ┌──────────────┐ ┌──────────────┐ │
CPU / Software ─────────►│  │ Command /    │ │ DMA Register │ │
                         │  │ Register     │►│ File         │ │
                         │  │ Decoder      │ │ 26 Registers │ │
                         │  └──────────────┘ └──────┬───────┘ │
                         │                          │         │
                         │              ┌───────────▼────────┐│
                         │              │ Channel / Priority ││
                         │              │ Control             ││
                         │              └───────────┬────────┘│
                         │                          │         │
DREQ0 ──────────────────►│                          ▼         │
DREQ1 ──────────────────►│                 ┌────────────────┐│
DREQ2 ──────────────────►│                 │ Arbitration /  ││
DREQ3 ──────────────────►│                 │ Priority Logic ││
                         │                 └───────┬────────┘│
                         │                         │         │
                         │                         ▼         │
                         │                 ┌────────────────┐│
                         │                 │ DMA Control    ││
                         │                 │ FSM            ││
                         │                 └───────┬────────┘│
                         │                         │         │
                         │                         ▼         │
                         │                 ┌────────────────┐│
                         │                 │ DMA Datapath / ││
                         │                 │ Address Logic  ││
                         │                 └───────┬────────┘│
                         │                         │         │
                         │                         ▼         │
                         │                 ┌────────────────┐│
                         │                 │ Circular Buffer││
                         │                 │ / Status Logic ││
                         │                 └────────────────┘│
                         └─────────────────────────────────────┘
