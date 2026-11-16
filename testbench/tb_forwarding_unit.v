`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_forwarding_unit.v  -  unit test for register_id_comparator,
// forwarding_unit and forwarding_mux.
//  * exhaustive: every combination of 5 control flags x register IDs 0..3
//    (rs, rt, EX/MEM rd, MEM/WB rd)  -> 8192 vectors
//  * random: 20000 vectors over the full 5-bit register space
//  * mux: every select value with random data
// The reference model below is written independently of the RTL.
// -----------------------------------------------------------------------------
module tb_forwarding_unit;
    reg  [4:0] rs, rt, exmem_rd, memwb_rd;
    reg        uses_rs, uses_rt, exmem_wr, exmem_ld, memwb_wr;
    wire [1:0] fA, fB;
    forwarding_unit dut(.id_ex_rs(rs), .id_ex_rt(rt), .id_ex_uses_rs(uses_rs), .id_ex_uses_rt(uses_rt),
                        .ex_mem_rd(exmem_rd), .mem_wb_rd(memwb_rd), .ex_mem_regwrite(exmem_wr),
                        .ex_mem_memread(exmem_ld), .mem_wb_regwrite(memwb_wr), .forwardA(fA), .forwardB(fB));

    reg  [1:0]  sel; reg [31:0] rv, ev, mv; wire [31:0] y;
    forwarding_mux mux(.sel(sel), .reg_val(rv), .exmem_val(ev), .memwb_val(mv), .y(y));

    integer v, errors, total, n10, n01, seed;

    function [1:0] ref_fwd(input uses, input [4:0] src);
        begin
            if      (uses && src != 0 && exmem_wr && !exmem_ld && exmem_rd == src) ref_fwd = 2'b10;  // newest value
            else if (uses && src != 0 && memwb_wr && memwb_rd == src)               ref_fwd = 2'b01;
            else                                                                      ref_fwd = 2'b00;
        end
    endfunction

    task check;
        begin
            #1; total = total + 1;
            if (fA !== ref_fwd(uses_rs, rs) || fB !== ref_fwd(uses_rt, rt)) begin
                errors = errors + 1;
                if (errors <= 5) $display("  ERROR rs=%0d rt=%0d exmem_rd=%0d memwb_rd=%0d -> fA=%b fB=%b", rs, rt, exmem_rd, memwb_rd, fA, fB);
            end
            if (fA == 2'b10) n10 = n10 + 1;
            if (fA == 2'b01) n01 = n01 + 1;
        end
    endtask

    task scenario(input [8*44-1:0] txt, input [4:0] s, input [4:0] e, input ew, input el, input [4:0] m, input mw);
        begin
            rs = s; rt = 5'd31; uses_rs = 1; uses_rt = 0; exmem_rd = e; exmem_wr = ew; exmem_ld = el; memwb_rd = m; memwb_wr = mw;
            #1; $display("  %-44s forwardA=%b  (expected %b) %0s", txt, fA, ref_fwd(1, s), (fA === ref_fwd(1, s)) ? "OK" : "WRONG");
        end
    endtask

    initial begin
        errors = 0; total = 0; n10 = 0; n01 = 0; seed = 2026;
        $display("");
        $display("=== Forwarding unit + register-ID comparator + forwarding mux : unit test ===");
        $display("  Directed scenarios (consumer reads r5 as operand A):");
        scenario("ADD r5 in EX/MEM          -> EX/MEM",      5, 5, 1, 0, 0, 0);
        scenario("ADD r5 in MEM/WB          -> MEM/WB",      5, 0, 0, 0, 5, 1);
        scenario("r5 in both stages         -> EX/MEM wins", 5, 5, 1, 0, 5, 1);
        scenario("LW r5 in EX/MEM (address) -> not a source",5, 5, 1, 1, 0, 0);
        scenario("LW r5 in MEM/WB (data)    -> MEM/WB",      5, 0, 0, 0, 5, 1);
        scenario("producer writes r0        -> never",       0, 0, 1, 0, 0, 1);
        scenario("SW in EX/MEM (no regwrite)-> no forward",  5, 5, 0, 0, 0, 0);
        scenario("different register r6     -> register file",5, 6, 1, 0, 6, 1);

        for (v = 0; v < 8192; v = v + 1) begin
            {uses_rs, uses_rt, exmem_wr, exmem_ld, memwb_wr} = v[12:8];
            rs = v[1:0]; rt = v[3:2]; exmem_rd = v[5:4]; memwb_rd = v[7:6];
            check;
        end
        for (v = 0; v < 20000; v = v + 1) begin
            {uses_rs, uses_rt, exmem_wr, exmem_ld, memwb_wr} = $random(seed);
            rs = $random(seed); rt = $random(seed); exmem_rd = $random(seed); memwb_rd = $random(seed);
            check;
        end
        for (v = 0; v < 4000; v = v + 1) begin
            sel = v % 4; rv = $random(seed); ev = $random(seed); mv = $random(seed); #1;
            total = total + 1;
            if (y !== ((sel == 2'b10) ? ev : (sel == 2'b01) ? mv : rv)) errors = errors + 1;
        end
        $display("");
        $display("  Vectors checked : %0d  (8192 exhaustive + 20000 random + 4000 mux)", total);
        $display("  forwardA = 10 (EX/MEM) seen %0d times, 01 (MEM/WB) seen %0d times", n10, n01);
        $display("  Errors          : %0d", errors);
        $display("  >>> %0s", errors == 0 ? "FORWARDING UNIT PASS" : "FORWARDING UNIT FAIL");
        $display("");
        $finish(0);
    end
endmodule
