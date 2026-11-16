`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// register_file.v  -  32 x 32-bit, 2 read ports, 1 write port, R0 = 0.
// Write-before-read bypass: a value being written in WB is visible to the
// instruction reading in ID during the same cycle (the classic "write in the
// first half, read in the second half" behaviour), which removes the
// distance-3 hazard without any stall or forwarding path.
// -----------------------------------------------------------------------------
module register_file(
    input         clk,
    input         we,
    input  [4:0]  ra1, ra2, wa,
    input  [31:0] wd,
    output [31:0] rd1, rd2
);
    reg [31:0] r [0:31];
    integer i;
    initial for (i = 0; i < 32; i = i + 1) r[i] = 32'd0;

    always @(posedge clk)
        if (we && wa != 5'd0) r[wa] <= wd;

    assign rd1 = (ra1 == 5'd0) ? 32'd0 : (we && wa == ra1) ? wd : r[ra1];
    assign rd2 = (ra2 == 5'd0) ? 32'd0 : (we && wa == ra2) ? wd : r[ra2];
endmodule
