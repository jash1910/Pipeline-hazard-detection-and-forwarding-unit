#!/bin/bash
# =============================================================================
# run_all.sh - full regression for the Pipeline Hazard Detection & Forwarding
# Unit. Works with the bash 3.2 that ships with macOS (no awk, no bash 4).
#   1. compile everything with -Wall
#   2. unit tests (forwarding unit, hazard detection unit, ALU + register file)
#   3. 16 directed tests x 3 modes   -> reports/performance_comparison.csv
#   4. random programs vs golden model -> reports/random_regression.csv
#   5. VCD waveforms + pipeline traces + performance summary
# Exits non-zero if anything that must pass fails.
# Usage: ./run_all.sh [number_of_random_seeds]   (default 100)
# =============================================================================
cd "$(dirname "$0")"
NTESTS=16
NSEEDS=${1:-100}
NAMES=("" "ADD->SUB EX/MEM fwd" "ADD AND SUB MEM/WB fwd" "LW->ADD load-use" "double write" "R0 dependency"
       "independent" "LW indep dep" "mixed 11-instr" "LW->SW" "LW->ADD->SUB" "ADDI->ADD" "ADD->SW data fwd"
       "LW indepADD depADD" "unsupported=NOP" "vector add naive" "vector add sched")
RTL="rtl/register_id_comparator.v rtl/forwarding_unit.v rtl/forwarding_mux.v rtl/hazard_detection_unit.v rtl/stall_flush_control.v rtl/alu.v rtl/register_file.v rtl/processor_top.v"
BUILD=simulation/build; LOGS=simulation/logs; WAVES=simulation/waveforms
mkdir -p $BUILD $LOGS $WAVES simulation/results reports
fail=0

ratio() {   # ratio a b -> "a/b" with 3 decimals, integer arithmetic only
    local m=$(( $1 * 1000 / $2 ))
    printf "%d.%03d" $((m / 1000)) $((m % 1000))
}
pct() {     # pct a b -> 100*a/b, rounded to 1 decimal
    local m=$(( ($1 * 10000 / $2 + 5) / 10 ))
    printf "%d.%d" $((m / 10)) $((m % 10))
}

echo "=================================================================="
echo " Pipeline Hazard Detection & Forwarding Unit - full regression"
echo "=================================================================="

# ---------------------------------------------------------------- 1. compile
echo "[1/5] Compiling all RTL and testbenches (iverilog -g2012 -Wall)"
: > $LOGS/compile.log
for m in 0 1 2; do
    iverilog -g2012 -Wall -P tb_processor.MODE=$m -o $BUILD/sim_m$m testbench/tb_processor.v $RTL >> $LOGS/compile.log 2>&1 || { echo "  COMPILE FAILED (mode $m), see $LOGS/compile.log"; exit 1; }
done
iverilog -g2012 -Wall -o $BUILD/tb_fwd testbench/tb_forwarding_unit.v rtl/register_id_comparator.v rtl/forwarding_unit.v rtl/forwarding_mux.v >> $LOGS/compile.log 2>&1 || { echo "  COMPILE FAILED (tb_forwarding_unit)"; exit 1; }
iverilog -g2012 -Wall -o $BUILD/tb_hdu testbench/tb_hazard_detection_unit.v rtl/register_id_comparator.v rtl/hazard_detection_unit.v rtl/stall_flush_control.v >> $LOGS/compile.log 2>&1 || { echo "  COMPILE FAILED (tb_hazard_detection_unit)"; exit 1; }
iverilog -g2012 -Wall -o $BUILD/tb_rfalu testbench/tb_regfile_alu.v rtl/alu.v rtl/register_file.v >> $LOGS/compile.log 2>&1 || { echo "  COMPILE FAILED (tb_regfile_alu)"; exit 1; }
nwarn=$(grep -c -i "warning" $LOGS/compile.log)
echo "      6 simulation images built, $nwarn warnings"

# ---------------------------------------------------------------- 2. unit tests
echo "[2/5] Unit tests"
for u in fwd:"forwarding unit + comparator + mux" hdu:"hazard detection + stall/flush" rfalu:"ALU + register file"; do
    key=${u%%:*}; label=${u#*:}
    vvp -n $BUILD/tb_$key > $LOGS/unit_$key.log
    if grep -q ">>> .* PASS" $LOGS/unit_$key.log; then res=PASS; else res=FAIL; fail=1; fi
    printf "      %-38s %s\n" "$label" "$res"
done

# ---------------------------------------------------------------- 3. directed tests
echo "[3/5] Directed tests ($NTESTS tests x 3 modes)"
CSV=reports/performance_comparison.csv
echo "test,name,mode,result,cycles,instructions,stalls,forwards,cpi,steady_state_cpi" > $CSV
for m in 0 1 2; do
    pass=0
    for t in $(seq 1 $NTESTS); do
        extra=""
        tt=$(printf "%02d" $t)
        if [ $m -eq 2 ] || { [ $m -eq 1 ] && { [ $t -eq 3 ] || [ $t -eq 8 ] || [ $t -eq 15 ]; }; }; then
            extra="+VCD=$WAVES/test${tt}_mode$m.vcd"
        fi
        out=$(vvp -n $BUILD/sim_m$m +TEST=$t +REPORT $extra)
        echo "$out" > $LOGS/test${tt}_mode$m.log
        line=$(echo "$out" | grep '^RESULT')
        [[ "$line" =~ ^RESULT,$t,$m,(PASS|FAIL),[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] || { echo "  BAD/MISSING RESULT: test $t mode $m"; exit 1; }
        res=$(echo "$line" | cut -d, -f4); cyc=$(echo "$line" | cut -d, -f5); ins=$(echo "$line" | cut -d, -f6)
        stl=$(echo "$line" | cut -d, -f7); fwd=$(echo "$line" | cut -d, -f8)
        [ "$res" = "PASS" ] && pass=$((pass + 1))
        [ "$res" = "FAIL" ] && [ $m -ne 0 ] && fail=1
        echo "$t,${NAMES[$t]},$m,$res,$cyc,$ins,$stl,$fwd,$(ratio $cyc $ins),$(ratio $((cyc - 4)) $ins)" >> $CSV
    done
    case $m in 0) label="MODE 0 no hazard handling";; 1) label="MODE 1 stall-only interlock";; 2) label="MODE 2 forwarding + LU stall";; esac
    note=""; [ $m -eq 0 ] && note="   (expected to fail: proves the hazards are real)"
    printf "      %-30s %2d/%d pass%s\n" "$label" $pass $NTESTS "$note"
done
cp $CSV simulation/results/summary.csv

# ---------------------------------------------------------------- 4. random programs
echo "[4/5] Random programs vs golden model ($NSEEDS seeds x 40 instructions)"
RCSV=reports/random_regression.csv
echo "seed,mode,result,cycles,instructions,stalls,forwards" > $RCSV
for m in 0 1 2; do
    pass=0; cyc_sum=0; ins_sum=0; n=$NSEEDS; [ $m -eq 0 ] && n=$(( NSEEDS < 20 ? NSEEDS : 20 ))
    for s in $(seq 1 $n); do
        line=$(vvp -n $BUILD/sim_m$m +TEST=0 +SEED=$s | grep '^RESULT')
        res=$(echo "$line" | cut -d, -f4); cyc=$(echo "$line" | cut -d, -f5); ins=$(echo "$line" | cut -d, -f6)
        [ "$res" = "PASS" ] && pass=$((pass + 1))
        [ "$res" != "PASS" ] && [ $m -ne 0 ] && { fail=1; echo "      FAIL seed $s mode $m"; }
        cyc_sum=$((cyc_sum + cyc)); ins_sum=$((ins_sum + ins))
        echo "$s,$m,$res,$cyc,$ins,$(echo "$line" | cut -d, -f7),$(echo "$line" | cut -d, -f8)" >> $RCSV
    done
    eval "RC$m=$cyc_sum; RI$m=$ins_sum"
    case $m in 0) label="MODE 0 no hazard handling";; 1) label="MODE 1 stall-only interlock";; 2) label="MODE 2 forwarding + LU stall";; esac
    note=""; [ $m -eq 0 ] && note="   (expected to fail)"
    printf "      %-30s %3d/%d match golden model, avg CPI %s%s\n" "$label" $pass $n "$(ratio $cyc_sum $ins_sum)" "$note"
done

# ---------------------------------------------------------------- 5. traces + performance
echo "[5/5] Pipeline traces and performance summary"
vvp -n $BUILD/sim_m2 +TEST=3 +REPORT +TRACE > simulation/results/trace_test03_loaduse_mode2.txt
vvp -n $BUILD/sim_m1 +TEST=3 +REPORT +TRACE > simulation/results/trace_test03_loaduse_mode1.txt
vvp -n $BUILD/sim_m2 +TEST=1 +REPORT +TRACE > simulation/results/trace_test01_exmem_mode2.txt
vvp -n $BUILD/sim_m2 +TEST=8 +REPORT +TRACE > simulation/results/trace_test08_mixed_mode2.txt
c1=0; c2=0
while IFS=, read -r t name m res cyc ins stl fwd cpi scpi; do
    [ "$m" = "1" ] && c1=$((c1 + cyc)); [ "$m" = "2" ] && c2=$((c2 + cyc))
done < <(tail -n +2 $CSV)
echo "      directed tests: stall-only $c1 cycles, forwarding $c2 cycles -> $(pct $((c1 - c2)) $c1)% fewer cycles"
echo "      random programs: CPI $(ratio $RC1 $RI1) (stall-only) -> $(ratio $RC2 $RI2) (forwarding), speed-up $(ratio $RC1 $RC2)x"
rm -rf $BUILD
echo "------------------------------------------------------------------"
if [ $fail -eq 0 ]; then
    echo "ALL CHECKS PASSED  (unit tests, MODE 1 + MODE 2 directed and random)"
else
    echo "FAILURE: see simulation/logs/"; exit 1
fi
