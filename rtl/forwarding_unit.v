`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// forwarding_unit.v
// Selects where each ALU operand of the instruction in EX comes from.
//   2'b00 : register file value latched in ID/EX (no hazard)
//   2'b10 : EX/MEM ALU result   (dependency distance 1)
//   2'b01 : MEM/WB write-back   (dependency distance 2)
// EX/MEM has priority because it holds the NEWEST value of the register.
// A load sitting in EX/MEM only holds an ADDRESS, never data, so it is not a
// forwarding source; that case is a load-use hazard handled by a 1-cycle stall,
// after which the loaded data is forwarded from MEM/WB.
// -----------------------------------------------------------------------------
module forwarding_unit(
    input  [4:0] id_ex_rs, id_ex_rt,
    input        id_ex_uses_rs, id_ex_uses_rt,
    input  [4:0] ex_mem_rd, mem_wb_rd,
    input        ex_mem_regwrite, ex_mem_memread, mem_wb_regwrite,
    output reg [1:0] forwardA, forwardB
);
    wire exmem_src = ex_mem_regwrite && !ex_mem_memread;
    wire exmem_rs, exmem_rt, memwb_rs, memwb_rt;

    register_id_comparator c_exmem_rs(.producer_writes(exmem_src),       .producer_rd(ex_mem_rd),
                                      .consumer_uses(id_ex_uses_rs),     .consumer_rs(id_ex_rs), .match(exmem_rs));
    register_id_comparator c_exmem_rt(.producer_writes(exmem_src),       .producer_rd(ex_mem_rd),
                                      .consumer_uses(id_ex_uses_rt),     .consumer_rs(id_ex_rt), .match(exmem_rt));
    register_id_comparator c_memwb_rs(.producer_writes(mem_wb_regwrite), .producer_rd(mem_wb_rd),
                                      .consumer_uses(id_ex_uses_rs),     .consumer_rs(id_ex_rs), .match(memwb_rs));
    register_id_comparator c_memwb_rt(.producer_writes(mem_wb_regwrite), .producer_rd(mem_wb_rd),
                                      .consumer_uses(id_ex_uses_rt),     .consumer_rs(id_ex_rt), .match(memwb_rt));

    always @* begin
        forwardA = exmem_rs ? 2'b10 : memwb_rs ? 2'b01 : 2'b00;
        forwardB = exmem_rt ? 2'b10 : memwb_rt ? 2'b01 : 2'b00;
    end
endmodule
