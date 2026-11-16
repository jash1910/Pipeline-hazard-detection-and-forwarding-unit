`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// register_id_comparator.v
// Basic building block of every hazard check in the design.
// match = 1 when a PRODUCER instruction (later in the pipe) will write a
// non-zero destination register that a CONSUMER instruction actually reads.
// R0 is hard-wired to zero, so it never creates a dependency.
// -----------------------------------------------------------------------------
module register_id_comparator(
    input        producer_writes,   // producer will write a register
    input  [4:0] producer_rd,       // producer destination register
    input        consumer_uses,     // consumer really reads this source operand
    input  [4:0] consumer_rs,       // consumer source register
    output       match
);
    assign match = producer_writes && consumer_uses &&
                   (producer_rd != 5'd0) && (producer_rd == consumer_rs);
endmodule
