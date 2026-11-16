`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_regfile_alu.v  -  unit test for alu and register_file.
//  ALU: corner values + 10000 random vectors per operation.
//  Register file: R0 hard-wired to 0, write/read of all 31 registers on both
//  ports, write-before-read bypass, write-enable respected.
// -----------------------------------------------------------------------------
module tb_regfile_alu;
    reg  [31:0] a, b; reg [1:0] op; wire [31:0] y;
    alu u_alu(.a(a), .b(b), .op(op), .y(y));

    reg clk = 0, we; reg [4:0] ra1, ra2, wa; reg [31:0] wd; wire [31:0] rd1, rd2;
    register_file rf(.clk(clk), .we(we), .ra1(ra1), .ra2(ra2), .wa(wa), .wd(wd), .rd1(rd1), .rd2(rd2));
    always #5 clk = ~clk;

    integer i, k, errors, alu_total, rf_total, seed;
    reg [31:0] exp_y, shadow [0:31];

    task alu_check;
        begin
            #1; alu_total = alu_total + 1;
            case (op) 2'b00: exp_y = a + b; 2'b01: exp_y = a - b; 2'b10: exp_y = a & b; default: exp_y = a | b; endcase
            if (y !== exp_y) begin errors = errors + 1;
                if (errors < 5) $display("  ALU ERROR op=%b a=%h b=%h y=%h exp=%h", op, a, b, y, exp_y); end
        end
    endtask

    initial begin
        errors = 0; alu_total = 0; rf_total = 0; seed = 99;
        $display("");
        $display("=== ALU + register file : unit test ===");
        // ---- ALU ----
        $display("  ALU examples:");
        a = 15; b = 5;
        for (k = 0; k < 4; k = k + 1) begin op = k; alu_check;
            $display("    %-3s 15, 5   = %0d", (k==0)?"ADD":(k==1)?"SUB":(k==2)?"AND":"OR", $signed(y)); end
        a = 5; b = 8; op = 2'b01; alu_check; $display("    SUB 5, 8    = %0d   (two's complement)", $signed(y));
        a = 32'hFFFF_FFFF; b = 1; op = 2'b00; alu_check; $display("    ADD max, 1  = %0d   (wrap-around)", y);
        for (k = 0; k < 4; k = k + 1) for (i = 0; i < 10000; i = i + 1) begin
            op = k; a = $random(seed); b = $random(seed); alu_check;
        end
        // ---- register file ----
        we = 0; wa = 0; wd = 0; ra1 = 0; ra2 = 0;
        for (i = 0; i < 32; i = i + 1) shadow[i] = 0;
        @(negedge clk);
        for (i = 0; i < 32; i = i + 1) begin                   // write every register (incl. attempt on r0)
            we = 1; wa = i; wd = $random(seed); if (i != 0) shadow[i] = wd;
            ra1 = i; ra2 = i; #1; rf_total = rf_total + 1;     // bypass: value visible in the same cycle
            if (i != 0 && (rd1 !== wd || rd2 !== wd)) errors = errors + 1;
            if (i == 0 && (rd1 !== 0 || rd2 !== 0)) errors = errors + 1;
            @(negedge clk);
        end
        we = 0;
        for (i = 0; i < 32; i = i + 1) begin                   // read back on both ports
            ra1 = i; ra2 = 31 - i; #1; rf_total = rf_total + 1;
            if (rd1 !== shadow[i] || rd2 !== shadow[31 - i]) errors = errors + 1;
        end
        we = 0; wa = 7; wd = 32'hDEAD_BEEF; ra1 = 7; #1; rf_total = rf_total + 1;   // we = 0 -> no bypass
        if (rd1 !== shadow[7]) errors = errors + 1;
        @(negedge clk); #1; if (rd1 !== shadow[7]) errors = errors + 1;            // and no write
        $display("");
        $display("  ALU vectors checked           : %0d", alu_total);
        $display("  Register-file checks          : %0d  (R0 = 0, 31 regs x 2 ports, bypass, write-enable)", rf_total);
        $display("  Errors                        : %0d", errors);
        $display("  >>> %0s", errors == 0 ? "ALU + REGISTER FILE PASS" : "ALU + REGISTER FILE FAIL");
        $display("");
        $finish(0);
    end
endmodule
