`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// stall_flush_control.v
// Turns hazard decisions into pipeline-register control signals.
//   stall : hold PC and IF/ID (re-decode the same instruction next cycle)
//           and inject a bubble (NOP) into ID/EX.
//   flush : squash the instruction in IF/ID and ID/EX. Phase I handles data
//           hazards only, so flush is tied low in processor_top; the port is
//           the hook for branch/control-hazard handling planned for Phase II.
// -----------------------------------------------------------------------------
module stall_flush_control(
    input  stall,
    input  flush,
    output pc_write,      // 1 = PC advances
    output ifid_write,    // 1 = IF/ID loads the next instruction
    output ifid_flush,    // 1 = IF/ID is cleared to NOP
    output idex_bubble    // 1 = ID/EX control bits are cleared (bubble)
);
    assign pc_write    = !stall || flush;
    assign ifid_write  = !stall;
    assign ifid_flush  = flush;
    assign idex_bubble = stall || flush;
endmodule
