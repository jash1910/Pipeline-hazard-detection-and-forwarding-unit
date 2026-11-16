# Work division - Phase I

| Member | Role | Files owned | Report section |
|---|---|---|---|
| **Jashvitha** (lead) | architecture, hazard detection, integration, verification, performance | `rtl/hazard_detection_unit.v`, `rtl/stall_flush_control.v`, `rtl/processor_top.v`, `testbench/tb_processor.v`, `testbench/tb_hazard_detection_unit.v`, `run_all.sh`, `scripts/`, `docs/figures/block_diagram.png`, `docs/report/` | Abstract, Introduction, Proposed Solution, Results, final editing |
| **Chaitanya** | forwarding path | `rtl/register_id_comparator.v`, `rtl/forwarding_unit.v`, `rtl/forwarding_mux.v`, `testbench/tb_forwarding_unit.v` | input to Proposed Solution (forwarding) |
| **Palak** | datapath blocks | `rtl/register_file.v`, `rtl/alu.v`, `testbench/tb_regfile_alu.v` | Literature Review (draft) |
| **Samarth** | hazard cases + waveforms | `docs/hazard_cases.md`, directed programs in `tb_processor.v`, `waveforms/layouts/*.gtkw` | References |

Video: Jashvitha presents the idea, architecture, demo and results; each member introduces
themselves and explains their own module in about 20-30 seconds.

## Phase II (planned)
- Jashvitha: branch (BEQ) support and control-hazard flush; final report and results.
- Chaitanya: MEM/WB -> MEM store-data forwarding (removes the LW -> SW stall).
- Palak: Yosys synthesis (area, forwarding-mux timing cost).
- Samarth: branch hazard test cases, longer random programs, waveform cases for branches.
