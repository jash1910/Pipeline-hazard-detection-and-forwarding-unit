# Pipeline Hazard Detection and Forwarding Unit

Verilog implementation of a 5-stage MIPS-style pipeline (IF, ID, EX, MEM, WB) with
register-ID comparators, an EX/MEM + MEM/WB forwarding unit, a load-use hazard
detection unit and stall/flush control, plus a verification environment that compares
the design against a stall-only baseline.

**Team:** Jashvitha (lead), Chaitanya, Palak, Samarth. Newton School of Technology, Rishihood University.
**Phase I report:** [`docs/IEEE_Phase1_Report.pdf`](docs/IEEE_Phase1_Report.pdf) · **Demo video:** _add link here_

![block diagram](docs/figures/block_diagram.png)

## Repository layout
| Path | Contents |
|---|---|
| `rtl/register_id_comparator.v` | producer/consumer register comparison used by every hazard check |
| `rtl/forwarding_unit.v`, `rtl/forwarding_mux.v` | forwardA/forwardB select (10 EX/MEM, 01 MEM/WB, 00 register file) and 3:1 operand muxes |
| `rtl/hazard_detection_unit.v` | MODE 0 none / MODE 1 stall-only / MODE 2 load-use stall |
| `rtl/stall_flush_control.v` | PCWrite, IF/IDWrite, ID/EX bubble, flush hook (Phase II branches) |
| `rtl/register_file.v`, `rtl/alu.v` | 32x32 register file (R0 = 0, write-before-read), ADD/SUB/AND/OR ALU |
| `rtl/processor_top.v` | 5-stage datapath, pipeline registers, decode, performance counters |
| `testbench/tb_processor.v` | 16 directed tests + random programs, golden model, analytical timing model, stall monitor, pipeline trace |
| `testbench/tb_forwarding_unit.v`, `tb_hazard_detection_unit.v`, `tb_regfile_alu.v` | unit tests |
| `docs/hazard_cases.md` | catalogue of the directed hazard cases |
| `waveforms/layouts/*.gtkw` | GTKWave views |
| `run_all.sh` | full regression, CSV reports, VCD waveforms, traces |
| `make_phase1_screenshots.sh` | macOS: regression + figures + screenshots into `contributions/<member>/` |
| `contributions/<member>/` | each member's assigned work and screenshots |

## Run
```bash
brew install icarus-verilog tree          # macOS (Linux: apt install iverilog)
./run_all.sh                              # everything; exits non-zero on any failure
./scripts/show.sh test 3 2 trace          # one test, MODE 2, with a cycle-by-cycle pipeline trace
./scripts/show.sh cpi-table               # MODE 1 vs MODE 2 comparison
gtkwave simulation/waveforms/test03_mode2.vcd waveforms/layouts/test03_mode2.gtkw
```
Single run by hand: `iverilog -g2012 -P tb_processor.MODE=2 -o sim testbench/tb_processor.v rtl/*.v && vvp sim +TEST=3 +REPORT +TRACE`

## Hazard policies (`MODE` parameter)
- **MODE 0** – no hazard handling. Intentionally wrong; shows that the hazards are real.
- **MODE 1** – stall-only interlock. Correct baseline.
- **MODE 2** – forwarding + one-cycle load-use stall. Proposed design.

## Results (Phase I)
| | stall-only (MODE 1) | forwarding (MODE 2) |
|---|---|---|
| 16 directed tests, total cycles | 214 | 158 (26.2% fewer, 1.35x) |
| Test 8 mixed program: cycles / stalls | 33 / 18 | 17 / 2 |
| 100 random 40-instruction programs, avg CPI | 1.462 | 1.136 (1.29x) |

Every run is checked against an instruction-level golden model, an analytical stall/forward/cycle
model and a stall monitor. 9 of 9 deliberately injected RTL faults were detected.

## Contributions
See [`docs/WORK_DIVISION.md`](docs/WORK_DIVISION.md) and `contributions/<member>/README.md`.
