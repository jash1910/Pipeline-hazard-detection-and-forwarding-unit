#!/bin/bash
# =============================================================================
# scripts/show.sh <item> - prints one piece of project evidence in the terminal,
# echoing the exact commands it runs. Used by make_phase1_screenshots.sh for the
# screenshots and handy for the live demo in the video.
#   items: tree | compile | regression | unit-fwd | unit-hdu | unit-rfalu
#          test <n> <mode> [trace] | cpi-table | catalogue | random
#          code <file>... | code-hazard-section | check
# =============================================================================
cd "$(dirname "$0")/.."
B=simulation/build_show; mkdir -p $B
BOLD=$'\033[1m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; RST=$'\033[0m'
RTL="rtl/register_id_comparator.v rtl/forwarding_unit.v rtl/forwarding_mux.v rtl/hazard_detection_unit.v rtl/stall_flush_control.v rtl/alu.v rtl/register_file.v rtl/processor_top.v"
cmd()   { printf "%s%s$ %s%s\n" "$BOLD" "$CYAN" "$*" "$RST"; eval "$@"; }
note()  { printf "%s# %s%s\n" "$DIM" "$*" "$RST"; }
build() { [ -x $B/sim_m$1 ] || iverilog -g2012 -P tb_processor.MODE=$1 -o $B/sim_m$1 testbench/tb_processor.v $RTL; }
ratio() { local m=$(( $1 * 1000 / $2 )); printf "%d.%03d" $((m / 1000)) $((m % 1000)); }
pct()   { local m=$(( ($1 * 10000 / $2 + 5) / 10 )); printf "%d.%d" $((m / 10)) $((m % 10)); }

case "$1" in
check)
    note "Screen-recording permission check - if you can read this in the screenshot, captures work."
    cmd "iverilog -V 2>/dev/null | head -1"; cmd "sw_vers" ;;
tree)
    note "Repository layout"
    if command -v tree >/dev/null; then cmd "tree -L 2 --dirsfirst -I '.venv|contributions|build_show|*.vcd|*.log'"
    else cmd "find . -maxdepth 2 -not -path '*/.*' -not -path './contributions*' -not -name '*.vcd' -not -name '*.log' | sort"; fi
    cmd "ls simulation/waveforms | wc -l | xargs echo 'VCD waveform files:'" ;;
compile)
    note "Every RTL module and testbench compiles cleanly with all warnings enabled"
    for m in 0 1 2; do cmd "iverilog -g2012 -Wall -P tb_processor.MODE=$m -o $B/sim_m$m testbench/tb_processor.v rtl/*.v 2>&1 | tee -a $B/w.log"; done
    cmd "iverilog -g2012 -Wall -o $B/tb_fwd testbench/tb_forwarding_unit.v rtl/register_id_comparator.v rtl/forwarding_unit.v rtl/forwarding_mux.v 2>&1 | tee -a $B/w.log"
    cmd "iverilog -g2012 -Wall -o $B/tb_hdu testbench/tb_hazard_detection_unit.v rtl/register_id_comparator.v rtl/hazard_detection_unit.v rtl/stall_flush_control.v 2>&1 | tee -a $B/w.log"
    cmd "iverilog -g2012 -Wall -o $B/tb_rfalu testbench/tb_regfile_alu.v rtl/alu.v rtl/register_file.v 2>&1 | tee -a $B/w.log"
    cmd "ls -1 $B"
    printf "\n%sErrors/warnings: %s%s\n" "$BOLD" "$(grep -ci -E 'warning|error' $B/w.log 2>/dev/null || true)" "$RST"; rm -f $B/w.log ;;
regression)
    cmd "./run_all.sh" ;;
unit-fwd)
    cmd "iverilog -g2012 -Wall -o $B/tb_fwd testbench/tb_forwarding_unit.v rtl/register_id_comparator.v rtl/forwarding_unit.v rtl/forwarding_mux.v"
    cmd "vvp -n $B/tb_fwd" ;;
unit-hdu)
    cmd "iverilog -g2012 -Wall -o $B/tb_hdu testbench/tb_hazard_detection_unit.v rtl/register_id_comparator.v rtl/hazard_detection_unit.v rtl/stall_flush_control.v"
    cmd "vvp -n $B/tb_hdu" ;;
unit-rfalu)
    cmd "iverilog -g2012 -Wall -o $B/tb_rfalu testbench/tb_regfile_alu.v rtl/alu.v rtl/register_file.v"
    cmd "vvp -n $B/tb_rfalu" ;;
test)
    t=$2; m=${3:-2}; extra=""; [ "$4" = "trace" ] && extra="+TRACE"
    build $m
    note "compiled with: iverilog -g2012 -P tb_processor.MODE=$m -o $B/sim_m$m testbench/tb_processor.v rtl/*.v"
    cmd "vvp -n $B/sim_m$m +TEST=$t +REPORT $extra" ;;
cpi-table)
    note "Directed tests: MODE 1 (stall-only interlock) vs MODE 2 (forwarding + load-use stall)"
    cmd "./run_all.sh >/dev/null && echo 'reports/performance_comparison.csv refreshed'"
    printf "\n%s %-3s %-24s | %-22s | %-27s | %s%s\n" "$BOLD" "#" "test" "MODE 1 cyc stall CPI" "MODE 2 cyc stall fwd CPI" "saved" "$RST"
    echo "-----+--------------------------+------------------------+-----------------------------+------"
    tc1=0; tc2=0
    for t in $(seq 1 16); do
        l1=$(grep "^$t,[^,]*,1," reports/performance_comparison.csv); l2=$(grep "^$t,[^,]*,2," reports/performance_comparison.csv)
        name=$(echo "$l2" | cut -d, -f2)
        c1=$(echo "$l1" | cut -d, -f5); s1=$(echo "$l1" | cut -d, -f7); p1=$(echo "$l1" | cut -d, -f9)
        c2=$(echo "$l2" | cut -d, -f5); s2=$(echo "$l2" | cut -d, -f7); f2=$(echo "$l2" | cut -d, -f8); p2=$(echo "$l2" | cut -d, -f9)
        tc1=$((tc1 + c1)); tc2=$((tc2 + c2))
        printf " %-3s %-24s | %4s %5s %8s   | %4s %5s %4s %8s   | %3s\n" "$t" "$name" "$c1" "$s1" "$p1" "$c2" "$s2" "$f2" "$p2" "$((c1 - c2))"
    done
    echo "-----+--------------------------+------------------------+-----------------------------+------"
    printf "%s total cycles: MODE 1 = %d, MODE 2 = %d  ->  %s%% fewer cycles, speed-up %sx%s\n" "$BOLD" $tc1 $tc2 "$(pct $((tc1 - tc2)) $tc1)" "$(ratio $tc1 $tc2)" "$RST"
    note "CPI includes the 4-cycle pipeline fill; steady-state CPI is in the CSV." ;;
catalogue)
    cmd "cat docs/hazard_cases.md" ;;
random)
    build 1; build 2
    note "Random 40-instruction programs (registers r0-r7, so hazards are frequent) checked against the golden model"
    printf "\n%s seed | MODE 1 cycles stalls golden | MODE 2 cycles stalls fwds golden%s\n" "$BOLD" "$RST"
    echo "------+----------------------------+--------------------------------"
    for s in $(seq 1 15); do
        a=$(vvp -n $B/sim_m1 +TEST=0 +SEED=$s | grep RESULT); b=$(vvp -n $B/sim_m2 +TEST=0 +SEED=$s | grep RESULT)
        printf "  %3d |   %5s %6s   %-5s   |   %5s %6s %4s   %-5s\n" $s "$(echo $a | cut -d, -f5)" "$(echo $a | cut -d, -f7)" "$(echo $a | cut -d, -f4)" \
            "$(echo $b | cut -d, -f5)" "$(echo $b | cut -d, -f7)" "$(echo $b | cut -d, -f8)" "$(echo $b | cut -d, -f4)"
    done
    echo ""
    cmd "vvp -n $B/sim_m2 +TEST=0 +SEED=7 +REPORT | tail -11" ;;
code)
    shift
    for f in "$@"; do cmd "cat -n $f"; echo; done ;;
code-hazard-section)
    s=$(grep -n "Hazard detection + stall/flush control" rtl/processor_top.v | cut -d: -f1)
    e=$(grep -n "alu u_alu" rtl/processor_top.v | cut -d: -f1)
    note "processor_top.v - integration of hazard detection, stall/flush control and forwarding"
    cmd "sed -n '${s},${e}p' rtl/processor_top.v | nl -ba -v $s" ;;
*)
    echo "unknown item '$1'"; exit 1 ;;
esac
