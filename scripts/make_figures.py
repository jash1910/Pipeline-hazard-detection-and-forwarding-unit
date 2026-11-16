#!/usr/bin/env python3
"""
make_figures.py - renders report/video figures from the REAL simulation output.

  * waveform figures  : parsed straight from simulation/waveforms/*.vcd
  * CPI comparison     : from reports/performance_comparison.csv
  * gtkw layouts       : `--gtkw` regenerates waveforms/layouts/*.gtkw

Usage:  python3 scripts/make_figures.py <output_dir>          (needs matplotlib)
        python3 scripts/make_figures.py --gtkw                 (no matplotlib needed)
"""
import csv, math, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAVES = os.path.join(ROOT, "simulation", "waveforms")
TB, DUT = "tb_processor", "tb_processor.dut"

# ----------------------------------------------------------------------------- VCD parser
def parse_vcd(path):
    """Returns (timescale_ps, {full_name: [(time, value_str), ...]}, end_time)."""
    ids, scope, changes, t, ts_ps = {}, [], {}, 0, 1
    with open(path) as f:
        tokens = f.read().split()
    i, n = 0, len(tokens)
    while i < n:
        tok = tokens[i]
        if tok == "$timescale":
            spec = ""
            i += 1
            while tokens[i] != "$end":
                spec += tokens[i]; i += 1
            num = int("".join(c for c in spec if c.isdigit()) or 1)
            unit = "".join(c for c in spec if c.isalpha())
            ts_ps = num * {"fs": 1e-3, "ps": 1, "ns": 1e3, "us": 1e6, "ms": 1e9, "s": 1e12}[unit]
        elif tok == "$scope":
            scope.append(tokens[i + 2]); i += 3
        elif tok == "$upscope":
            scope.pop(); i += 1
        elif tok == "$var":
            code, name = tokens[i + 3], tokens[i + 4]
            ids.setdefault(code, []).append(".".join(scope + [name]))
            while tokens[i] != "$end":
                i += 1
        elif tok.startswith("#"):
            t = int(tok[1:])
        elif tok[0] in "bBrR" and len(tok) > 1:
            code = tokens[i + 1]
            for name in ids.get(code, []):
                changes.setdefault(name, []).append((t, tok[1:]))
            i += 1
        elif tok[0] in "01xXzZ" and len(tok) > 1 and tok[1:] in ids:
            for name in ids[tok[1:]]:
                changes.setdefault(name, []).append((t, tok[0]))
        i += 1
    return ts_ps, changes, t

def value_at(chg, t):
    v = None
    for (tt, val) in chg:
        if tt <= t: v = val
        else: break
    return v

def to_int(v):
    try: return int(v, 2)
    except (TypeError, ValueError): return None

# ----------------------------------------------------------------------------- waveform figure
ROWS = [  # (label, kind, signal(s))
    ("clk",              "bit",   f"{TB}.clk"),
    ("IF  (fetch PC)",   "stage", (f"{DUT}.pc", None)),
    ("ID  (IF/ID)",      "stage", (f"{DUT}.ifid_pc", f"{DUT}.ifid_instr")),
    ("EX  (ID/EX)",      "stage", (f"{DUT}.idex_pc", f"{DUT}.idex_valid")),
    ("MEM (EX/MEM)",     "stage", (f"{DUT}.exmem_pc", f"{DUT}.exmem_valid")),
    ("WB  (MEM/WB)",     "stage", (f"{DUT}.memwb_pc", f"{DUT}.memwb_valid")),
    ("load_use",         "bit",   f"{DUT}.hdu.load_use"),
    ("stall",            "bit",   f"{DUT}.stall"),
    ("pc_write",         "bit",   f"{DUT}.sfc.pc_write"),
    ("idex_bubble",      "bit",   f"{DUT}.sfc.idex_bubble"),
    ("forwardA",         "fwd",   f"{DUT}.fwdA"),
    ("forwardB",         "fwd",   f"{DUT}.fwdB"),
    ("ALU operand A",    "dec",   f"{DUT}.opA"),
    ("ALU operand B",    "dec",   f"{DUT}.opB_fwd"),
    ("ALU result",       "dec",   f"{DUT}.alu_y"),
    ("stalls / fwds",    "pair",  (f"{DUT}.stalls", f"{DUT}.fwds")),
]

def row_label(kind, sig, chg, t):
    if kind == "stage":
        pc_s, valid_s = sig
        pc = to_int(value_at(chg[pc_s], t))
        if valid_s is None:
            return f"I{pc // 4}" if pc is not None else "?"
        v = to_int(value_at(chg[valid_s], t))
        return f"I{pc // 4}" if (v and pc is not None) else "--"
    if kind == "fwd":
        v = value_at(chg[sig], t) or "0"
        v = v.zfill(2)
        return {"00": "00 RF", "10": "10 EX/MEM", "01": "01 MEM/WB"}.get(v, v)
    if kind == "dec":
        v = to_int(value_at(chg[sig], t))
        if v is None: return "x"
        return str(v - (1 << 32) if v >= 1 << 31 else v)
    if kind == "pair":
        a, b = (to_int(value_at(chg[s], t)) for s in sig)
        return f"{a}/{b}"
    return value_at(chg[sig], t)

def render_wave(vcd, out_png, title):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ts, chg, end = parse_vcd(vcd)
    per_ns = 1000.0 / ts                      # vcd units per ns
    t0, t1 = int(20 * per_ns), end            # show from just before reset release
    period = int(10 * per_ns)
    rows = [r for r in ROWS if all((s is None) or (s in chg) for s in (r[2] if isinstance(r[2], tuple) else (r[2],)))]
    fig_h = 0.42 * len(rows) + 1.3
    fig, ax = plt.subplots(figsize=(15, fig_h), dpi=130)
    ax.set_xlim(t0, t1); ax.set_ylim(-0.95, len(rows) - 0.4)
    ax.invert_yaxis(); ax.set_yticks(range(len(rows))); ax.set_yticklabels([r[0] for r in rows], fontsize=9, family="monospace")
    first_pos = int(35 * per_ns)              # first rising edge after reset release
    edges = list(range(first_pos, t1 + 1, period))
    for k, e in enumerate(edges):
        ax.axvline(e, color="#d0d0d0", lw=0.6, zorder=0)
        if e - period // 2 >= t0:   # cycle k = the clock period that ends at the k-th rising edge after reset
            ax.text(e - period / 2, -0.75, f"c{k + 1}", ha="center", va="center", fontsize=8, color="#555")
    for y, (label, kind, sig) in enumerate(rows):
        if kind == "bit":
            pts = [(t, v) for (t, v) in chg[sig]]
            xs, ys = [t0], []
            cur = value_at(chg[sig], t0)
            ys.append(1 if cur == "1" else 0)
            for (t, v) in pts:
                if t0 < t <= t1:
                    xs += [t, t]; ys += [ys[-1], 1 if v == "1" else 0]
            xs.append(t1); ys.append(ys[-1])
            col = "#c0392b" if label in ("stall", "load_use", "idex_bubble") else "#1f5fa8"
            ax.plot(xs, [y + 0.3 - 0.6 * v for v in ys], color=col, lw=1.4)
        else:
            sigs = sig if isinstance(sig, tuple) else (sig,)
            times = sorted({t for s in sigs if s for (t, _) in chg[s] if t0 < t < t1} | {t0})
            # merge segments with identical labels
            segs = []
            for idx, t in enumerate(times):
                lab = row_label(kind, sig, chg, t)
                if segs and segs[-1][2] == lab: continue
                segs.append([t, None, lab])
            for k in range(len(segs)):
                segs[k][1] = segs[k + 1][0] if k + 1 < len(segs) else t1
            for (a, b, lab) in segs:
                face = "#fde2c8" if (kind == "fwd" and not lab.startswith("00")) else ("#f2f2f2" if lab == "--" else "#e3eefb")
                d = min(per_ns * 0.8, (b - a) * 0.2)
                xs = [a, a + d, b - d, b, b - d, a + d, a]
                ys = [y, y - 0.3, y - 0.3, y, y + 0.3, y + 0.3, y]
                edge = "#d35400" if (kind == "fwd" and not lab.startswith("00")) else ("#9a9a9a" if lab == "--" else "#1f5fa8")
                ax.fill(xs, ys, facecolor=face, edgecolor=edge, lw=0.9)
                if (b - a) > period * 0.35:
                    ax.text((a + b) / 2, y, lab, ha="center", va="center", fontsize=7.5, family="monospace")
    ax.set_xticks([]); ax.tick_params(axis="y", length=0)
    for s in ("top", "right", "bottom"): ax.spines[s].set_visible(False)
    ax.set_title(title, fontsize=11, loc="left")
    ax.text(1.0, -0.06, f"rendered from {os.path.relpath(vcd, ROOT)}  |  10 ns clock, c<n> = cycle after reset",
            transform=ax.transAxes, ha="right", fontsize=7.5, color="#666")
    fig.tight_layout()
    fig.savefig(out_png); plt.close(fig)

# ----------------------------------------------------------------------------- CPI chart
def render_cpi(out_png):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    rows = list(csv.DictReader(open(os.path.join(ROOT, "reports", "performance_comparison.csv"))))
    tests = sorted({int(r["test"]) for r in rows})
    get = lambda t, m, k: float(next(r[k] for r in rows if int(r["test"]) == t and r["mode"] == str(m)))
    c1 = [get(t, 1, "cycles") for t in tests]; c2 = [get(t, 2, "cycles") for t in tests]
    s1 = [get(t, 1, "steady_state_cpi") for t in tests]; s2 = [get(t, 2, "steady_state_cpi") for t in tests]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(15, 5), dpi=130)
    w = 0.38; x = range(len(tests))
    a1.bar([i - w / 2 for i in x], c1, w, label="MODE 1 stall-only", color="#9aa9bd")
    a1.bar([i + w / 2 for i in x], c2, w, label="MODE 2 forwarding + load-use stall", color="#1f5fa8")
    a1.set_xticks(list(x)); a1.set_xticklabels([str(t) for t in tests]); a1.set_xlabel("directed test")
    a1.set_ylabel("total clock cycles (incl. 4-cycle fill)"); a1.legend(fontsize=8); a1.set_title("Execution time per test", loc="left")
    a2.bar([i - w / 2 for i in x], s1, w, label="MODE 1", color="#9aa9bd")
    a2.bar([i + w / 2 for i in x], s2, w, label="MODE 2", color="#1f5fa8")
    a2.axhline(1.0, color="#c0392b", lw=0.8, ls="--", label="ideal pipeline CPI = 1")
    a2.set_xticks(list(x)); a2.set_xticklabels([str(t) for t in tests]); a2.set_xlabel("directed test")
    a2.set_ylabel("steady-state CPI = (cycles - 4) / instructions"); a2.legend(fontsize=8); a2.set_title("Steady-state CPI", loc="left")
    tot1, tot2 = sum(c1), sum(c2)
    fig.suptitle(f"Stall-only vs forwarding: {int(tot1)} -> {int(tot2)} cycles over all directed tests "
                 f"({100 * (tot1 - tot2) / tot1:.1f}% fewer)", fontsize=11, x=0.01, ha="left")
    fig.tight_layout(); fig.savefig(out_png); plt.close(fig)

# ----------------------------------------------------------------------------- GTKWave layouts
GTKW_SIGNALS = [
    ("-Clock / reset", None), ("@28", f"{TB}.clk"), ("@28", f"{TB}.rst"),
    ("-Pipeline: byte PC of the instruction in each stage", None),
    ("@24", f"{DUT}.pc[31:0]"), ("@24", f"{DUT}.ifid_pc[31:0]"), ("@22", f"{DUT}.ifid_instr[31:0]"),
    ("@28", f"{DUT}.idex_valid"), ("@24", f"{DUT}.idex_pc[31:0]"),
    ("@28", f"{DUT}.exmem_valid"), ("@24", f"{DUT}.exmem_pc[31:0]"),
    ("@28", f"{DUT}.memwb_valid"), ("@24", f"{DUT}.memwb_pc[31:0]"),
    ("-Hazard detection + stall/flush control", None),
    ("@28", f"{DUT}.hdu.load_use"), ("@28", f"{DUT}.hdu.raw_hazard"), ("@28", f"{DUT}.stall"),
    ("@28", f"{DUT}.sfc.pc_write"), ("@28", f"{DUT}.sfc.ifid_write"), ("@28", f"{DUT}.sfc.idex_bubble"),
    ("-Register-ID comparison + forwarding", None),
    ("@24", f"{DUT}.idex_rs[4:0]"), ("@24", f"{DUT}.idex_rt[4:0]"),
    ("@24", f"{DUT}.exmem_dest[4:0]"), ("@24", f"{DUT}.memwb_dest[4:0]"),
    ("@28", f"{DUT}.fwdA[1:0]"), ("@28", f"{DUT}.fwdB[1:0]"),
    ("@24", f"{DUT}.opA[31:0]"), ("@24", f"{DUT}.opB_fwd[31:0]"), ("@24", f"{DUT}.alu_y[31:0]"),
    ("-Performance counters", None),
    ("@24", f"{DUT}.cycles[31:0]"), ("@24", f"{DUT}.stalls[31:0]"), ("@24", f"{DUT}.fwds[31:0]"), ("@24", f"{DUT}.retired[31:0]"),
]

def write_gtkw(vcd_name, out):
    ts, _, end = parse_vcd(os.path.join(WAVES, vcd_name))
    zoom = -math.ceil(math.log2(end / 950.0))           # fit the whole run into ~950 px
    lines = ["[*] GTKWave save file - Pipeline Hazard Detection & Forwarding Unit",
             f'[dumpfile] "../../simulation/waveforms/{vcd_name}"', "[timestart] 0", "[size] 1500 900", "[pos] -1 -1",
             f"*{zoom:.6f} 0 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1",
             "[treeopen] tb_processor.", "[treeopen] tb_processor.dut.", "[sst_width] 220", "[signals_width] 230",
             "[sst_expanded] 1", "[sst_vpaned_height] 260"]
    for fmt, name in GTKW_SIGNALS:
        if name is None:
            lines += ["@200", fmt]
        else:
            lines += [fmt, name]
    lines.append("[pattern_trace] 1\n[pattern_trace] 0")
    open(out, "w").write("\n".join(lines) + "\n")

# ----------------------------------------------------------------------------- main
WAVE_FIGS = [  # (vcd, png, title)
    ("test01_mode2.vcd", "wave_test01_exmem_forwarding.png", "Test 1  ADD r1 -> SUB r4,r1  : EX/MEM forwarding (forwardA = 10), no stall"),
    ("test02_mode2.vcd", "wave_test02_memwb_forwarding.png", "Test 2  ADD r1, AND, SUB r4,r1 : MEM/WB forwarding (forwardA = 01)"),
    ("test03_mode2.vcd", "wave_test03_loaduse_mode2.png",    "Test 3  LW r1 -> ADD r3,r1 (MODE 2): 1 load-use stall, then MEM/WB forwarding"),
    ("test03_mode1.vcd", "wave_test03_loaduse_mode1.png",    "Test 3  LW r1 -> ADD r3,r1 (MODE 1 stall-only baseline): 2 stall cycles"),
    ("test05_mode2.vcd", "wave_test05_r0_not_forwarded.png", "Test 5  ADD r0 -> SUB r4,r0 : R0 is never forwarded"),
    ("test06_mode2.vcd", "wave_test06_independent.png",      "Test 6  independent instructions : register-file operands only"),
    ("test08_mode2.vcd", "wave_test08_mixed_program.png",    "Test 8  mixed 11-instruction program (MODE 2): 2 stalls, 9 forwarding events"),
    ("test10_mode2.vcd", "wave_test10_lw_add_sub_chain.png", "Test 10 LW -> ADD -> SUB chain : stall + MEM/WB + EX/MEM forwarding"),
    ("test12_mode2.vcd", "wave_test12_store_data_fwd.png",   "Test 12 ADD r1 -> SW r1 : store data forwarded on operand B"),
    ("test13_mode2.vcd", "wave_test13_lw_indep_dep.png",     "Test 13 LW, independent ADD, dependent ADD : no stall needed"),
    ("test15_mode2.vcd", "wave_test15_vector_add_naive.png", "Test 15 vector add, naive order (MODE 2): 4 load-use stalls"),
    ("test16_mode2.vcd", "wave_test16_vector_add_sched.png", "Test 16 vector add, scheduled order (MODE 2): 0 stalls"),
]

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--gtkw":
        os.makedirs(os.path.join(ROOT, "waveforms", "layouts"), exist_ok=True)
        for vcd, png, _ in WAVE_FIGS:
            out = os.path.join(ROOT, "waveforms", "layouts", vcd.replace(".vcd", ".gtkw"))
            write_gtkw(vcd, out); print("wrote", os.path.relpath(out, ROOT))
        sys.exit(0)
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "figures")
    os.makedirs(out_dir, exist_ok=True)
    render_cpi(os.path.join(out_dir, "cpi_comparison_chart.png")); print("  figure: cpi_comparison_chart.png")
    for vcd, png, title in WAVE_FIGS:
        path = os.path.join(WAVES, vcd)
        if os.path.exists(path):
            render_wave(path, os.path.join(out_dir, png), title); print("  figure:", png)
