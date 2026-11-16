`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// alu.v  -  32-bit ALU.   op: 00 ADD, 01 SUB, 10 AND, 11 OR
// -----------------------------------------------------------------------------
module alu(
    input  [31:0] a, b,
    input  [1:0]  op,
    output reg [31:0] y
);
    always @* begin
        case (op)
            2'b00: y = a + b;
            2'b01: y = a - b;
            2'b10: y = a & b;
            default: y = a | b;
        endcase
    end
endmodule
