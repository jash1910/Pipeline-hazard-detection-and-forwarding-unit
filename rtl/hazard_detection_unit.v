`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hazard_detection_unit.v
// Looks at the instruction in ID (IF/ID register) and decides whether it must
// wait. MODE selects the hazard-handling policy of the whole processor:
//   MODE 0 : no hazard handling          (baseline, intentionally INCORRECT)
//   MODE 1 : stall-only interlock         (baseline, correct, no forwarding)
//   MODE 2 : forwarding + load-use stall  (proposed design)
// In MODE 1 the ID instruction waits until every producer in EX or MEM has
// reached WB (the register file has a write-before-read bypass, so a producer
// in WB needs no stall). In MODE 2 only a LOAD in EX followed by a dependent
// instruction in ID must wait one cycle; everything else is forwarded.
// -----------------------------------------------------------------------------
module hazard_detection_unit #(parameter MODE = 2)(
    input        id_ex_memread, id_ex_regwrite,
    input  [4:0] id_ex_dest,
    input        ex_mem_regwrite,
    input  [4:0] ex_mem_dest,
    input  [4:0] if_id_rs, if_id_rt,
    input        uses_rs, uses_rt,
    output       load_use,      // load-use hazard detected
    output       raw_hazard,    // any RAW hazard with EX or MEM (used by MODE 1)
    output       stall
);
    wire idex_rs, idex_rt, exmem_rs, exmem_rt;
    register_id_comparator c_idex_rs (.producer_writes(id_ex_regwrite),  .producer_rd(id_ex_dest),
                                      .consumer_uses(uses_rs), .consumer_rs(if_id_rs), .match(idex_rs));
    register_id_comparator c_idex_rt (.producer_writes(id_ex_regwrite),  .producer_rd(id_ex_dest),
                                      .consumer_uses(uses_rt), .consumer_rs(if_id_rt), .match(idex_rt));
    register_id_comparator c_exmem_rs(.producer_writes(ex_mem_regwrite), .producer_rd(ex_mem_dest),
                                      .consumer_uses(uses_rs), .consumer_rs(if_id_rs), .match(exmem_rs));
    register_id_comparator c_exmem_rt(.producer_writes(ex_mem_regwrite), .producer_rd(ex_mem_dest),
                                      .consumer_uses(uses_rt), .consumer_rs(if_id_rt), .match(exmem_rt));

    assign load_use   = id_ex_memread && (idex_rs || idex_rt);
    assign raw_hazard = idex_rs || idex_rt || exmem_rs || exmem_rt;

    assign stall = (MODE == 2) ? load_use :
                   (MODE == 1) ? raw_hazard : 1'b0;
endmodule
