`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// forwarding_mux.v  -  3:1 operand multiplexer driven by the forwarding unit.
// sel: 00 register file, 10 EX/MEM result, 01 MEM/WB write-back data.
// (2'b11 never occurs; it falls back to the register-file value.)
// -----------------------------------------------------------------------------
module forwarding_mux(
    input  [1:0]  sel,
    input  [31:0] reg_val, exmem_val, memwb_val,
    output [31:0] y
);
    assign y = (sel == 2'b10) ? exmem_val :
               (sel == 2'b01) ? memwb_val : reg_val;
endmodule
