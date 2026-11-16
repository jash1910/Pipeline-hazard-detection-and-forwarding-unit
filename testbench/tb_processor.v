`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_processor.v  -  system-level testbench for the 5-stage pipeline.
//
// Usage (compile once per MODE):
//   iverilog -g2012 -P tb_processor.MODE=2 -o sim testbench/tb_processor.v rtl/*.v
//   vvp sim +TEST=n   [+REPORT] [+TRACE] [+VERBOSE] [+VCD=file]     directed test n (1..16)
//   vvp sim +TEST=0 +SEED=s [+LEN=l]                                  random program
//
// Every run is checked three independent ways:
//   1. GOLDEN MODEL  - an instruction-by-instruction (non-pipelined) reference
//                      model executes the same program; all 31 registers and
//                      all 256 data-memory words must match the pipeline.
//   2. TIMING MODEL  - an analytical model of the hazard policy predicts the
//                      exact number of stall cycles, forwarding events and
//                      total cycles; the DUT counters must match exactly.
//   3. MONITOR       - on every stall the PC and IF/ID must freeze and a
//                      bubble must enter ID/EX.
// Directed tests also check hand-computed register values and (MODE 2)
// hand-computed stall / forwarding counts.
// -----------------------------------------------------------------------------
module tb_processor;
    parameter MODE = 2;

    reg clk = 0, rst = 1;
    wire [31:0] cycles, retired, stalls, fwds;
    processor_top #(.MODE(MODE)) dut(.clk(clk), .rst(rst), .cycles(cycles), .retired(retired),
                                     .stalls(stalls), .fwds(fwds));
    always #5 clk = ~clk;                                  // 100 MHz, 10 ns period

    // ---------------- instruction encoding ----------------
    localparam F_ADD = 6'h20, F_SUB = 6'h22, F_AND = 6'h24, F_OR = 6'h25;
    localparam OP_ADDI = 6'h08, OP_LW = 6'h23, OP_SW = 6'h2B;
    function [31:0] R(input [5:0] f, input [4:0] rd, rs, rt);         R = {6'd0, rs, rt, rd, 5'd0, f}; endfunction
    function [31:0] I(input [5:0] op, input [4:0] rt, rs, input [15:0] imm); I = {op, rs, rt, imm};  endfunction

    // ---------------- decode helpers (shared by golden + timing model) ----------------
    function f_isR(input [31:0] w);  f_isR = (w[31:26] == 0) && (w != 0) &&
        (w[5:0] == F_ADD || w[5:0] == F_SUB || w[5:0] == F_AND || w[5:0] == F_OR); endfunction
    function f_valid(input [31:0] w); f_valid = f_isR(w) || w[31:26] == OP_ADDI || w[31:26] == OP_LW || w[31:26] == OP_SW; endfunction
    function f_writes(input [31:0] w); f_writes = f_isR(w) || w[31:26] == OP_ADDI || w[31:26] == OP_LW; endfunction
    function f_load(input [31:0] w);   f_load = (w[31:26] == OP_LW); endfunction
    function f_uses_rt(input [31:0] w); f_uses_rt = f_isR(w) || w[31:26] == OP_SW; endfunction
    function [4:0] f_dest(input [31:0] w); f_dest = f_isR(w) ? w[15:11] : w[20:16]; endfunction

    // ---------------- state ----------------
    integer TEST, SEED, LEN, plen, n_valid, last_valid, errors, mon_errors, i, k, j, timeout, t, cnt;
    integer exp_stalls, exp_fwds, have_hand, m_stalls, m_fwds, m_cycles, golden_err, shown;
    integer slot [0:255];
    integer lastw [0:31];
    reg [31:0] g_r [0:31];
    reg [31:0] g_m [0:255];
    reg [31:0] w, a, b, addr;
    reg [8*44-1:0] tname;
    reg  prev_stall, prev_ok; reg [31:0] prev_pc, prev_ifid;
    reg [1023:0] vcdname;

    task put(input integer idx, input [31:0] word); begin dut.imem[idx] = word; if (idx + 1 > plen) plen = idx + 1; end endtask
    task ck(input [4:0] r, input [31:0] v);
        if (dut.rf.r[r] !== v) begin errors = errors + 1;
            if ($test$plusargs("VERBOSE")) $display("  MISMATCH r%0d = %0d, expected %0d", r, $signed(dut.rf.r[r]), $signed(v)); end
    endtask
    task ckm(input integer idx, input [31:0] v);
        if (dut.dmem[idx] !== v) begin errors = errors + 1;
            if ($test$plusargs("VERBOSE")) $display("  MISMATCH mem[%0d] = %0d, expected %0d", idx, dut.dmem[idx], v); end
    endtask

    // ---------------- disassembler (for reports) ----------------
    task disasm(input integer idx, input [31:0] x);
        begin
            if (x == 0)                       $display("    I%-2d  NOP", idx);
            else if (f_isR(x))                $display("    I%-2d  %-4s r%0d, r%0d, r%0d", idx,
                                                 (x[5:0]==F_ADD)?"ADD":(x[5:0]==F_SUB)?"SUB":(x[5:0]==F_AND)?"AND":"OR",
                                                 x[15:11], x[25:21], x[20:16]);
            else if (x[31:26] == OP_ADDI)     $display("    I%-2d  ADDI r%0d, r%0d, %0d", idx, x[20:16], x[25:21], $signed(x[15:0]));
            else if (x[31:26] == OP_LW)       $display("    I%-2d  LW   r%0d, %0d(r%0d)", idx, x[20:16], $signed(x[15:0]), x[25:21]);
            else if (x[31:26] == OP_SW)       $display("    I%-2d  SW   r%0d, %0d(r%0d)", idx, x[20:16], $signed(x[15:0]), x[25:21]);
            else                              $display("    I%-2d  .word 0x%08h   (unsupported -> NOP)", idx, x);
        end
    endtask

    // ---------------- golden reference model (sequential ISA execution) ----------------
    task run_golden;
        begin
            for (k = 0; k < plen; k = k + 1) begin
                w = dut.imem[k];
                a = g_r[w[25:21]]; b = g_r[w[20:16]];
                addr = a + {{16{w[15]}}, w[15:0]};
                if (f_isR(w)) begin
                    case (w[5:0])
                        F_ADD: g_r[w[15:11]] = a + b;   F_SUB: g_r[w[15:11]] = a - b;
                        F_AND: g_r[w[15:11]] = a & b;   default: g_r[w[15:11]] = a | b;
                    endcase
                end
                else if (w[31:26] == OP_ADDI) g_r[w[20:16]] = addr;
                else if (w[31:26] == OP_LW)   g_r[w[20:16]] = g_m[addr[9:2]];
                else if (w[31:26] == OP_SW)   g_m[addr[9:2]] = b;
                g_r[0] = 0;
            end
        end
    endtask

    // ---------------- analytical timing model of the hazard policy ----------------
    // slot[k] = cycle in which instruction k is issued from ID to EX (relative).
    // MODE 1: consumer must be >= 3 slots after its producer (WB bypass at distance 3).
    // MODE 2: only a LOAD producer forces distance >= 2 (one bubble); all else forwards.
    task run_timing_model;
        integer need, src, s, uses;
        begin
            for (k = 0; k < 32; k = k + 1) lastw[k] = -1;
            m_fwds = 0;
            for (k = 0; k < plen; k = k + 1) begin
                w = dut.imem[k];
                need = (k == 0) ? 0 : slot[k-1] + 1;
                cnt = 0;                                       // forwarding needed by this instr?
                for (s = 0; s < 2; s = s + 1) begin
                    src  = (s == 0) ? w[25:21] : w[20:16];
                    uses = (s == 0) ? f_valid(w) : f_uses_rt(w);
                    if (uses && src != 0 && lastw[src] >= 0) begin
                        j = lastw[src];
                        if (MODE == 1 && slot[j] + 3 > need)                 need = slot[j] + 3;
                        if (MODE == 2 && f_load(dut.imem[j]) && slot[j] + 2 > need) need = slot[j] + 2;
                    end
                end
                slot[k] = need;
                for (s = 0; s < 2; s = s + 1) begin
                    src  = (s == 0) ? w[25:21] : w[20:16];
                    uses = (s == 0) ? f_valid(w) : f_uses_rt(w);
                    if (uses && src != 0 && lastw[src] >= 0 && slot[k] - slot[lastw[src]] <= 2) cnt = 1;
                end
                if (MODE == 2 && cnt) m_fwds = m_fwds + 1;
                if (f_writes(w) && f_dest(w) != 0) lastw[f_dest(w)] = k;
            end
            m_stalls = slot[last_valid] - last_valid;
            m_cycles = slot[last_valid] + 5;                     // + fill of IF, ID, EX, MEM, WB
        end
    endtask

    // ---------------- stall monitor: PC freeze, IF/ID freeze, bubble insertion ----------------
    initial begin prev_ok = 0; prev_stall = 0; mon_errors = 0; end
    always @(negedge clk) begin
        if (!rst) begin
            if (prev_ok && prev_stall) begin
                if (dut.pc !== prev_pc || dut.ifid_instr !== prev_ifid) mon_errors = mon_errors + 1;
                if (dut.idex_valid || dut.idex_regwrite || dut.idex_memread || dut.idex_memwrite) mon_errors = mon_errors + 1;
            end
            prev_stall = dut.stall; prev_pc = dut.pc; prev_ifid = dut.ifid_instr; prev_ok = 1;
        end
    end

    // ---------------- pipeline trace helper ----------------
    task stage(input v, input [31:0] p);
        if (v) $write(" I%-3d", p >> 2); else $write(" --  ");
    endtask

    initial begin
        errors = 0; have_hand = 0; exp_stalls = 0; exp_fwds = 0; plen = 0;
        if (!$value$plusargs("TEST=%d", TEST)) TEST = 1;
        if (!$value$plusargs("SEED=%d", SEED)) SEED = 1;
        if (!$value$plusargs("LEN=%d",  LEN))  LEN  = 40;
        for (i = 0; i < 256; i = i + 1) begin dut.imem[i] = 0; dut.dmem[i] = 0; end

        // ---------------- initial architectural state ----------------
        dut.rf.r[2] = 10; dut.rf.r[3] = 5; dut.rf.r[4] = 20; dut.rf.r[5] = 3; dut.rf.r[7] = 19; dut.rf.r[8] = 10;
        if (TEST == 3 || TEST == 7 || TEST == 8 || TEST == 9 || TEST == 10 || TEST == 13) begin dut.rf.r[2] = 100; dut.rf.r[4] = 5; end
        dut.dmem[25] = 20;
        if (TEST == 15 || TEST == 16) begin                 // vector add: C[i] = A[i] + B[i], sum in r9
            dut.rf.r[20] = 0; dut.rf.r[21] = 64; dut.rf.r[22] = 128;
            dut.dmem[0] = 3;  dut.dmem[1] = 7;  dut.dmem[2] = 11; dut.dmem[3] = 15;   // A
            dut.dmem[16] = 10; dut.dmem[17] = 20; dut.dmem[18] = 30; dut.dmem[19] = 40; // B
        end
        if (TEST == 0) begin
            t = SEED;
            for (i = 1; i < 8; i = i + 1)   dut.rf.r[i] = $unsigned($random(t)) % 64;
            for (i = 0; i < 256; i = i + 1) dut.dmem[i] = i * 7 + 3;
        end

        // ---------------- programs ----------------
        case (TEST)
        0: begin tname = "Random program (constrained, r0-r7)";
            for (k = 0; k < LEN; k = k + 1) begin
                cnt = $unsigned($random(t)) % 100;
                i = $unsigned($random(t)) % 8; j = $unsigned($random(t)) % 8; a = $unsigned($random(t)) % 8;
                if      (cnt < 50) put(k, R((cnt % 4 == 0) ? F_ADD : (cnt % 4 == 1) ? F_SUB : (cnt % 4 == 2) ? F_AND : F_OR, i, j, a));
                else if (cnt < 65) put(k, I(OP_ADDI, i, j, ($unsigned($random(t)) % 32) - 16));
                else if (cnt < 85) put(k, I(OP_LW,   i, j, 4 * ($unsigned($random(t)) % 32)));
                else               put(k, I(OP_SW,   i, j, 4 * ($unsigned($random(t)) % 32)));
            end
        end
        1: begin tname = "ADD -> SUB (EX/MEM forwarding)";      put(0, R(F_ADD,1,2,3)); put(1, R(F_SUB,4,1,5)); end
        2: begin tname = "ADD, AND, SUB (MEM/WB forwarding)";   put(0, R(F_ADD,1,2,3)); put(1, R(F_AND,6,7,8)); put(2, R(F_SUB,4,1,5)); end
        3: begin tname = "LW -> ADD (load-use, 1 stall)";       put(0, I(OP_LW,1,2,0)); put(1, R(F_ADD,3,1,4)); end
        4: begin tname = "Double write: newest value wins";     put(0, R(F_ADD,1,2,3)); put(1, R(F_SUB,1,4,5)); put(2, R(F_AND,6,1,7)); end
        5: begin tname = "R0 destination is never forwarded";   put(0, R(F_ADD,0,2,3)); put(1, R(F_SUB,4,0,5)); end
        6: begin tname = "Independent instructions";            put(0, R(F_ADD,1,2,3)); put(1, R(F_SUB,6,4,5)); put(2, R(F_OR,9,8,2)); end
        7: begin tname = "LW, independent, dependent";          put(0, I(OP_LW,1,2,0)); put(1, R(F_ADD,6,4,5)); put(2, R(F_SUB,9,1,5)); end
        8: begin tname = "Mixed 11-instruction program";
            put(0,  I(OP_LW,1,2,0));     put(1,  R(F_ADD,3,1,4));  put(2, I(OP_SW,3,2,4));
            put(3,  I(OP_LW,6,2,4));     put(4,  I(OP_ADDI,6,6,1)); put(5, R(F_ADD,7,6,3));
            put(6,  R(F_SUB,8,7,1));     put(7,  R(F_AND,9,8,7));   put(8, R(F_OR,10,9,8));
            put(9,  I(OP_ADDI,11,10,5)); put(10, I(OP_SW,11,2,8));
        end
        9:  begin tname = "LW -> SW (store data from load)";    put(0, I(OP_LW,1,2,0)); put(1, I(OP_SW,1,2,4)); end
        10: begin tname = "LW -> ADD -> SUB (chain)";           put(0, I(OP_LW,1,2,0)); put(1, R(F_ADD,3,1,4)); put(2, R(F_SUB,6,3,5)); end
        11: begin tname = "ADDI -> ADD";                        put(0, I(OP_ADDI,1,2,7)); put(1, R(F_ADD,6,1,3)); end
        12: begin tname = "ADD -> SW (store-data forwarding)";  put(0, R(F_ADD,1,2,3)); put(1, I(OP_SW,1,4,0)); end
        13: begin tname = "LW, independent ADD, dependent ADD"; put(0, I(OP_LW,1,2,0)); put(1, R(F_ADD,6,4,5)); put(2, R(F_ADD,9,1,6)); end
        14: begin tname = "Unsupported encodings act as NOP";   put(0, R(6'h2A,1,2,3)); put(1, R(F_ADD,4,2,3)); put(2, {6'h3F,26'd0}); end
        15: begin tname = "Vector add, naive order (21 instr)";
            for (k = 0; k < 4; k = k + 1) begin
                put(5*k+0, I(OP_LW, 1, 20, 4*k));  put(5*k+1, I(OP_LW, 2, 21, 4*k));
                put(5*k+2, R(F_ADD, 3, 1, 2));      put(5*k+3, I(OP_SW, 3, 22, 4*k));
                put(5*k+4, R(F_ADD, 9, 9, 3));
            end
            put(20, I(OP_SW, 9, 22, 16));
        end
        16: begin tname = "Vector add, scheduled (21 instr)";
            put(0,  I(OP_LW,1,20,0));  put(1,  I(OP_LW,2,21,0));  put(2,  I(OP_LW,4,20,4));  put(3,  I(OP_LW,5,21,4));
            put(4,  R(F_ADD,3,1,2));   put(5,  R(F_ADD,6,4,5));   put(6,  I(OP_SW,3,22,0));  put(7,  I(OP_SW,6,22,4));
            put(8,  I(OP_LW,1,20,8));  put(9,  I(OP_LW,2,21,8));  put(10, I(OP_LW,4,20,12)); put(11, I(OP_LW,5,21,12));
            put(12, R(F_ADD,9,9,3));   put(13, R(F_ADD,9,9,6));   put(14, R(F_ADD,7,1,2));   put(15, R(F_ADD,8,4,5));
            put(16, I(OP_SW,7,22,8));  put(17, I(OP_SW,8,22,12)); put(18, R(F_ADD,9,9,7));   put(19, R(F_ADD,9,9,8));
            put(20, I(OP_SW,9,22,16));
        end
        default: begin tname = "UNKNOWN TEST"; end
        endcase

        // hand-computed expectations for the proposed design (MODE 2)
        have_hand = 1;
        case (TEST)
        1: begin exp_stalls=0; exp_fwds=1; end    2: begin exp_stalls=0; exp_fwds=1; end
        3: begin exp_stalls=1; exp_fwds=1; end    4: begin exp_stalls=0; exp_fwds=1; end
        5: begin exp_stalls=0; exp_fwds=0; end    6: begin exp_stalls=0; exp_fwds=0; end
        7: begin exp_stalls=0; exp_fwds=1; end    8: begin exp_stalls=2; exp_fwds=9; end
        9: begin exp_stalls=1; exp_fwds=1; end    10: begin exp_stalls=1; exp_fwds=2; end
        11: begin exp_stalls=0; exp_fwds=1; end   12: begin exp_stalls=0; exp_fwds=1; end
        13: begin exp_stalls=0; exp_fwds=1; end   14: begin exp_stalls=0; exp_fwds=0; end
        15: begin exp_stalls=4; exp_fwds=13; end  16: begin exp_stalls=0; exp_fwds=8; end
        default: have_hand = 0;
        endcase

        // ---------------- reference models ----------------
        n_valid = 0; last_valid = 0;
        for (k = 0; k < plen; k = k + 1) if (f_valid(dut.imem[k])) begin n_valid = n_valid + 1; last_valid = k; end
        for (i = 0; i < 32; i = i + 1)  g_r[i] = dut.rf.r[i];
        for (i = 0; i < 256; i = i + 1) g_m[i] = dut.dmem[i];
        run_golden;
        run_timing_model;
        if (MODE == 0) begin m_stalls = 0; m_fwds = 0; m_cycles = last_valid + 5; end

        if ($test$plusargs("REPORT")) begin
            $display("");
            $display("=================================================================");
            $display(" TEST %0d : %0s", TEST, tname);
            $display(" MODE %0d : %0s", MODE, (MODE==2) ? "forwarding + load-use stall (proposed)" :
                                             (MODE==1) ? "stall-only interlock (baseline)" : "no hazard handling (broken baseline)");
            $display("=================================================================");
            $display("  Program:");
            for (k = 0; k < plen && k < 24; k = k + 1) disasm(k, dut.imem[k]);
        end

        if ($value$plusargs("VCD=%s", vcdname)) begin $dumpfile(vcdname); $dumpvars(0, tb_processor); end

        // ---------------- run ----------------
        repeat (3) @(negedge clk);
        rst = 0;
        timeout = 0;
        if ($test$plusargs("TRACE")) begin
            $display("");
            $display("  cycle | IF   ID   EX   MEM  WB   | stall fwdA fwdB");
            $display("  ------+--------------------------+----------------");
        end
        while (retired !== n_valid && timeout < 2000) begin
            if ($test$plusargs("TRACE")) begin
                $write("  %5d | I%-3d", cycles + 1, dut.pc >> 2);
                stage(dut.ifid_instr != 0, dut.ifid_pc); stage(dut.idex_valid, dut.idex_pc);
                stage(dut.exmem_valid, dut.exmem_pc);    stage(dut.memwb_valid, dut.memwb_pc);
                $display(" |   %b    %b   %b  %0s", dut.stall, dut.fwdA, dut.fwdB,
                         dut.stall ? "<- stall: bubble into EX" :
                         (dut.fwdA == 2'b10 || dut.fwdB == 2'b10) ? "<- forward EX/MEM" :
                         (dut.fwdA == 2'b01 || dut.fwdB == 2'b01) ? "<- forward MEM/WB" : "");
            end
            @(negedge clk); timeout = timeout + 1;
        end

        // ---------------- checks ----------------
        case (TEST)
        1: begin ck(1,15); ck(4,12); end
        2: begin ck(1,15); ck(6,2);  ck(4,12); end
        3: begin ck(1,20); ck(3,25); end
        4: begin ck(1,17); ck(6,17); end
        5: begin ck(0,0);  ck(4,-3); end
        6: begin ck(1,15); ck(6,17); ck(9,10); end
        7: begin ck(1,20); ck(6,8);  ck(9,17); end
        8: begin ck(1,20); ck(3,25); ck(6,26); ck(7,51); ck(8,31); ck(9,19); ck(10,31); ck(11,36); ckm(26,25); ckm(27,36); end
        9:  begin ck(1,20); ckm(26,20); end
        10: begin ck(1,20); ck(3,25); ck(6,22); end
        11: begin ck(1,17); ck(6,22); end
        12: begin ck(1,15); ckm(5,15); end
        13: begin ck(1,20); ck(6,8);  ck(9,28); end
        14: begin ck(1,0);  ck(4,15); end
        15, 16: begin ckm(32,13); ckm(33,27); ckm(34,41); ckm(35,55); ckm(36,136); ck(9,136); end
        endcase

        golden_err = 0; shown = 0;
        for (i = 1; i < 32; i = i + 1) if (dut.rf.r[i] !== g_r[i]) begin
            golden_err = golden_err + 1;
            if (shown < 4 && ($test$plusargs("VERBOSE") || $test$plusargs("REPORT"))) begin
                $display("  golden mismatch: r%0d pipeline=%0d golden=%0d", i, $signed(dut.rf.r[i]), $signed(g_r[i])); shown = shown + 1; end
        end
        for (i = 0; i < 256; i = i + 1) if (dut.dmem[i] !== g_m[i]) begin
            golden_err = golden_err + 1;
            if (shown < 4 && ($test$plusargs("VERBOSE") || $test$plusargs("REPORT"))) begin
                $display("  golden mismatch: mem[%0d] pipeline=%0d golden=%0d", i, dut.dmem[i], g_m[i]); shown = shown + 1; end
        end
        errors = errors + golden_err;
        if (stalls !== m_stalls || cycles !== m_cycles || (MODE == 2 && fwds !== m_fwds)) errors = errors + 1;
        if (MODE == 2 && have_hand && (stalls !== exp_stalls || fwds !== exp_fwds)) errors = errors + 1;
        errors = errors + mon_errors;
        if (timeout >= 2000) errors = errors + 1;

        if ($test$plusargs("REPORT")) begin
            $display("");
            $display("  Golden model (31 regs + 256 mem words) : %0s", golden_err == 0 ? "MATCH" : "MISMATCH");
            if (MODE == 2 && have_hand) begin
                $display("  Stall cycles    DUT %3d   model %3d   hand %0d", stalls, m_stalls, exp_stalls);
                $display("  Forward events  DUT %3d   model %3d   hand %0d", fwds, m_fwds, exp_fwds);
            end else begin
                $display("  Stall cycles    DUT %3d   model %3d", stalls, m_stalls);
                $display("  Forward events  DUT %3d   model %3d", fwds, m_fwds);
            end
            $display("  Total cycles    DUT %3d   model %3d   (incl. 4-cycle fill)", cycles, m_cycles);
            $display("  Instructions %0d   CPI %0d.%03d   steady-state CPI %0d.%03d", n_valid,
                     cycles / n_valid, (cycles * 1000 / n_valid) % 1000,
                     (cycles - 4) / n_valid, ((cycles - 4) * 1000 / n_valid) % 1000);
            $display("  Stall monitor (PC/IF-ID freeze, bubble) : %0s", mon_errors == 0 ? "OK" : "VIOLATION");
            $display("  >>> %0s", (errors == 0) ? "PASS" : (MODE == 0) ? "FAIL (expected: no hazard handling)" : "FAIL");
            $display("");
        end
        $display("RESULT,%0d,%0d,%0s,%0d,%0d,%0d,%0d", (TEST == 0) ? 1000 + SEED : TEST, MODE,
                 (errors == 0) ? "PASS" : "FAIL", cycles, retired, stalls, fwds);
        $finish(0);
    end
endmodule
