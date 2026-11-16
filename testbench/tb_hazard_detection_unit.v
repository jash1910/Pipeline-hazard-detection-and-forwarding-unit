`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_hazard_detection_unit.v  -  unit test for hazard_detection_unit (all three
// MODEs) and stall_flush_control.
//  * exhaustive over control flags and register IDs 0..3   (8192 vectors/mode)
//  * random over the full 5-bit register space              (20000 vectors/mode)
//  * full truth table of stall_flush_control
// -----------------------------------------------------------------------------
module tb_hazard_detection_unit;
    reg        idex_ld, idex_wr, exmem_wr, uses_rs, uses_rt;
    reg  [4:0] idex_rd, exmem_rd, rs, rt;
    wire       lu0, raw0, st0, lu1, raw1, st1, lu2, raw2, st2;

    hazard_detection_unit #(.MODE(0)) h0(.id_ex_memread(idex_ld), .id_ex_regwrite(idex_wr), .id_ex_dest(idex_rd),
        .ex_mem_regwrite(exmem_wr), .ex_mem_dest(exmem_rd), .if_id_rs(rs), .if_id_rt(rt),
        .uses_rs(uses_rs), .uses_rt(uses_rt), .load_use(lu0), .raw_hazard(raw0), .stall(st0));
    hazard_detection_unit #(.MODE(1)) h1(.id_ex_memread(idex_ld), .id_ex_regwrite(idex_wr), .id_ex_dest(idex_rd),
        .ex_mem_regwrite(exmem_wr), .ex_mem_dest(exmem_rd), .if_id_rs(rs), .if_id_rt(rt),
        .uses_rs(uses_rs), .uses_rt(uses_rt), .load_use(lu1), .raw_hazard(raw1), .stall(st1));
    hazard_detection_unit #(.MODE(2)) h2(.id_ex_memread(idex_ld), .id_ex_regwrite(idex_wr), .id_ex_dest(idex_rd),
        .ex_mem_regwrite(exmem_wr), .ex_mem_dest(exmem_rd), .if_id_rs(rs), .if_id_rt(rt),
        .uses_rs(uses_rs), .uses_rt(uses_rt), .load_use(lu2), .raw_hazard(raw2), .stall(st2));

    reg stall, flush; wire pcw, ifw, iflush, bub;
    stall_flush_control sfc(.stall(stall), .flush(flush), .pc_write(pcw), .ifid_write(ifw), .ifid_flush(iflush), .idex_bubble(bub));

    integer v, errors, total, seed, n_lu, n_raw;
    reg r_dep_ex, r_dep_mem, r_lu;

    task check;
        begin
            #1; total = total + 1;
            // independent reference model
            r_dep_ex  = idex_wr  && idex_rd  != 0 && ((uses_rs && idex_rd  == rs) || (uses_rt && idex_rd  == rt));
            r_dep_mem = exmem_wr && exmem_rd != 0 && ((uses_rs && exmem_rd == rs) || (uses_rt && exmem_rd == rt));
            r_lu      = idex_ld && r_dep_ex;
            if (st0 !== 1'b0)                     errors = errors + 1;   // MODE 0 never stalls
            if (st1 !== (r_dep_ex || r_dep_mem)) errors = errors + 1;   // MODE 1 stalls on any RAW
            if (st2 !== r_lu)                     errors = errors + 1;   // MODE 2 stalls on load-use only
            if (r_lu) n_lu = n_lu + 1;
            if (r_dep_ex || r_dep_mem) n_raw = n_raw + 1;
        end
    endtask

    task scenario(input [8*44-1:0] txt, input ld, input wr, input [4:0] ird, input mwr, input [4:0] mrd, input [4:0] s, input [4:0] t2, input ut);
        begin
            idex_ld = ld; idex_wr = wr; idex_rd = ird; exmem_wr = mwr; exmem_rd = mrd; rs = s; rt = t2; uses_rs = 1; uses_rt = ut; #1;
            $display("  %-44s MODE1 stall=%b  MODE2 stall=%b", txt, st1, st2);
        end
    endtask

    initial begin
        errors = 0; total = 0; seed = 7; n_lu = 0; n_raw = 0;
        $display("");
        $display("=== Hazard detection unit (MODE 0/1/2) + stall/flush control : unit test ===");
        $display("  Directed scenarios (instruction in ID reads r1, r4):");
        scenario("LW  r1 in EX   (load-use)",              1, 1, 1, 0, 0, 1, 4, 1);
        scenario("ADD r1 in EX   (distance 1)",            0, 1, 1, 0, 0, 1, 4, 1);
        scenario("ADD r1 in MEM  (distance 2)",            0, 0, 0, 1, 1, 1, 4, 1);
        scenario("LW  r4 in EX, consumer is SW r4 (data)", 1, 1, 4, 0, 0, 1, 4, 1);
        scenario("LW  r4 in EX, consumer ADDI ignores rt", 1, 1, 4, 0, 0, 1, 4, 0);
        scenario("LW  r0 in EX   (R0 never a hazard)",     1, 1, 0, 0, 0, 0, 4, 1);
        scenario("independent producers",                  1, 1, 9, 1, 8, 1, 4, 1);

        for (v = 0; v < 8192; v = v + 1) begin
            {idex_ld, idex_wr, exmem_wr, uses_rs, uses_rt} = v[12:8];
            idex_rd = v[1:0]; exmem_rd = v[3:2]; rs = v[5:4]; rt = v[7:6];
            check;
        end
        for (v = 0; v < 20000; v = v + 1) begin
            {idex_ld, idex_wr, exmem_wr, uses_rs, uses_rt} = $random(seed);
            idex_rd = $random(seed); exmem_rd = $random(seed); rs = $random(seed); rt = $random(seed);
            check;
        end
        $display("");
        $display("  stall/flush control truth table:");
        $display("    stall flush | pc_write ifid_write ifid_flush idex_bubble");
        for (v = 0; v < 4; v = v + 1) begin
            {stall, flush} = v[1:0]; #1; total = total + 1;
            $display("      %b     %b   |    %b         %b          %b          %b", stall, flush, pcw, ifw, iflush, bub);
            if (pcw !== (!stall || flush) || ifw !== !stall || iflush !== flush || bub !== (stall || flush)) errors = errors + 1;
        end
        $display("");
        $display("  Vectors checked : %0d per mode (load-use cases %0d, RAW cases %0d)", total, n_lu, n_raw);
        $display("  Errors          : %0d", errors);
        $display("  >>> %0s", errors == 0 ? "HAZARD DETECTION UNIT PASS" : "HAZARD DETECTION UNIT FAIL");
        $display("");
        $finish(0);
    end
endmodule
