`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// processor_top.v
// 5-stage MIPS-style pipeline  IF -> ID -> EX -> MEM -> WB
// Instructions: ADD SUB AND OR (R-type), ADDI, LW, SW, NOP (= 32'h0000_0000).
// Any other opcode / funct is treated as a NOP.
// PC is a byte address (+4 per instruction); instruction and data memories are
// 256-word arrays indexed by address[9:2].
//
// MODE (passed down to the hazard detection unit):
//   0 = no hazard handling (intentionally incorrect baseline)
//   1 = stall-only interlock (correct baseline)
//   2 = EX/MEM + MEM/WB forwarding with load-use stall (proposed design)
//
// Performance counters: cycles, retired instructions, stall cycles and
// forwarding events (cycles in which at least one operand was forwarded).
// -----------------------------------------------------------------------------
module processor_top #(parameter MODE = 2)(
    input             clk, rst,
    output reg [31:0] cycles, retired, stalls, fwds
);
    reg [31:0] imem [0:255];
    reg [31:0] dmem [0:255];
    reg [31:0] pc;

    // ================= IF/ID =================
    reg [31:0] ifid_instr;

    // Debug only: PC of the instruction held in each pipeline register, so the
    // testbench trace and the waveforms show which instruction is in which stage.
    reg [31:0] ifid_pc, idex_pc, exmem_pc, memwb_pc;

    // ================= ID: decode =================
    wire [5:0]  op    = ifid_instr[31:26];
    wire [4:0]  rs    = ifid_instr[25:21];
    wire [4:0]  rt    = ifid_instr[20:16];
    wire [4:0]  rd    = ifid_instr[15:11];
    wire [5:0]  funct = ifid_instr[5:0];
    wire [31:0] imm   = {{16{ifid_instr[15]}}, ifid_instr[15:0]};

    wire isnop  = (ifid_instr == 32'd0);
    wire isR    = (op == 6'd0) && !isnop &&
                  (funct == 6'h20 || funct == 6'h22 || funct == 6'h24 || funct == 6'h25);
    wire isADDI = (op == 6'h08);
    wire isLW   = (op == 6'h23);
    wire isSW   = (op == 6'h2B);
    wire valid_instr = isR | isADDI | isLW | isSW;

    wire       d_regwrite = isR | isADDI | isLW;
    wire       d_alusrc   = isADDI | isLW | isSW;      // second ALU operand = immediate
    wire [4:0] d_dest     = isR ? rd : rt;
    wire       uses_rs    = valid_instr;               // every supported instruction reads rs
    wire       uses_rt    = isR | isSW;                // SW reads rt as store data
    reg  [1:0] d_aluop;
    always @* begin
        d_aluop = 2'b00;                               // ADD (also ADDI / LW / SW address)
        if (isR) case (funct)
            6'h22:   d_aluop = 2'b01;                  // SUB
            6'h24:   d_aluop = 2'b10;                  // AND
            6'h25:   d_aluop = 2'b11;                  // OR
            default: d_aluop = 2'b00;                  // ADD
        endcase
    end

    wire [31:0] rf_rd1, rf_rd2, wb_data;
    wire        wb_we;

    // ================= ID/EX =================
    reg        idex_valid, idex_regwrite, idex_memread, idex_memwrite, idex_alusrc;
    reg        idex_uses_rs, idex_uses_rt;
    reg [1:0]  idex_aluop;
    reg [4:0]  idex_rs, idex_rt, idex_dest;
    reg [31:0] idex_rv1, idex_rv2, idex_imm;

    // ================= EX/MEM =================
    reg        exmem_valid, exmem_regwrite, exmem_memread, exmem_memwrite;
    reg [4:0]  exmem_dest;
    reg [31:0] exmem_alu, exmem_store;

    // ================= MEM/WB =================
    reg        memwb_valid, memwb_regwrite, memwb_memtoreg;
    reg [4:0]  memwb_dest;
    reg [31:0] memwb_alu, memwb_mem;

    // ================= Hazard detection + stall/flush control =================
    wire load_use, raw_hazard, stall;
    hazard_detection_unit #(.MODE(MODE)) hdu(
        .id_ex_memread(idex_memread), .id_ex_regwrite(idex_regwrite), .id_ex_dest(idex_dest),
        .ex_mem_regwrite(exmem_regwrite), .ex_mem_dest(exmem_dest),
        .if_id_rs(rs), .if_id_rt(rt), .uses_rs(uses_rs), .uses_rt(uses_rt),
        .load_use(load_use), .raw_hazard(raw_hazard), .stall(stall));

    wire flush = 1'b0;                 // no control hazards in Phase I (no branches yet)
    wire pc_write, ifid_write, ifid_flush, idex_bubble;
    stall_flush_control sfc(.stall(stall), .flush(flush), .pc_write(pc_write),
        .ifid_write(ifid_write), .ifid_flush(ifid_flush), .idex_bubble(idex_bubble));

    // ================= Forwarding =================
    wire [1:0] fwdA_raw, fwdB_raw;
    forwarding_unit fu(
        .id_ex_rs(idex_rs), .id_ex_rt(idex_rt),
        .id_ex_uses_rs(idex_uses_rs), .id_ex_uses_rt(idex_uses_rt),
        .ex_mem_rd(exmem_dest), .mem_wb_rd(memwb_dest),
        .ex_mem_regwrite(exmem_regwrite), .ex_mem_memread(exmem_memread),
        .mem_wb_regwrite(memwb_regwrite),
        .forwardA(fwdA_raw), .forwardB(fwdB_raw));
    wire [1:0] fwdA = (MODE == 2) ? fwdA_raw : 2'b00;   // forwarding exists only in MODE 2
    wire [1:0] fwdB = (MODE == 2) ? fwdB_raw : 2'b00;

    // ================= EX =================
    wire [31:0] opA, opB_fwd, alu_b, alu_y;
    forwarding_mux muxA(.sel(fwdA), .reg_val(idex_rv1), .exmem_val(exmem_alu), .memwb_val(wb_data), .y(opA));
    forwarding_mux muxB(.sel(fwdB), .reg_val(idex_rv2), .exmem_val(exmem_alu), .memwb_val(wb_data), .y(opB_fwd));
    assign alu_b = idex_alusrc ? idex_imm : opB_fwd;
    alu u_alu(.a(opA), .b(alu_b), .op(idex_aluop), .y(alu_y));

    // ================= MEM / WB =================
    wire [31:0] mem_rdata = dmem[exmem_alu[9:2]];
    assign wb_data = memwb_memtoreg ? memwb_mem : memwb_alu;
    assign wb_we   = memwb_valid && memwb_regwrite;
    register_file rf(.clk(clk), .we(wb_we), .ra1(rs), .ra2(rt),
                     .wa(memwb_dest), .wd(wb_data), .rd1(rf_rd1), .rd2(rf_rd2));

    // ================= Sequential logic =================
    always @(posedge clk) begin
        if (rst) begin
            pc <= 0; ifid_instr <= 0;
            ifid_pc <= 0; idex_pc <= 0; exmem_pc <= 0; memwb_pc <= 0;
            idex_valid <= 0; idex_regwrite <= 0; idex_memread <= 0; idex_memwrite <= 0; idex_alusrc <= 0;
            idex_uses_rs <= 0; idex_uses_rt <= 0; idex_aluop <= 0;
            idex_rs <= 0; idex_rt <= 0; idex_dest <= 0; idex_rv1 <= 0; idex_rv2 <= 0; idex_imm <= 0;
            exmem_valid <= 0; exmem_regwrite <= 0; exmem_memread <= 0; exmem_memwrite <= 0;
            exmem_dest <= 0; exmem_alu <= 0; exmem_store <= 0;
            memwb_valid <= 0; memwb_regwrite <= 0; memwb_memtoreg <= 0;
            memwb_dest <= 0; memwb_alu <= 0; memwb_mem <= 0;
            cycles <= 0; retired <= 0; stalls <= 0; fwds <= 0;
        end else begin
            // ---- performance counters ----
            cycles <= cycles + 1;
            if (stall)                                   stalls  <= stalls + 1;
            if (memwb_valid)                             retired <= retired + 1;
            if (idex_valid && (fwdA != 2'b00 || fwdB != 2'b00)) fwds <= fwds + 1;

            // ---- IF ----
            if (pc_write)   pc <= pc + 32'd4;
            if (ifid_flush) ifid_instr <= 32'd0;
            else if (ifid_write) begin ifid_instr <= imem[pc[9:2]]; ifid_pc <= pc; end
            idex_pc <= ifid_pc; exmem_pc <= idex_pc; memwb_pc <= exmem_pc;   // debug only

            // ---- ID -> EX (bubble clears every control bit) ----
            if (idex_bubble) begin
                idex_valid <= 0; idex_regwrite <= 0; idex_memread <= 0; idex_memwrite <= 0;
                idex_uses_rs <= 0; idex_uses_rt <= 0;
            end else begin
                idex_valid <= valid_instr;  idex_regwrite <= d_regwrite;
                idex_memread <= isLW;       idex_memwrite <= isSW;
                idex_uses_rs <= uses_rs;    idex_uses_rt <= uses_rt;
            end
            idex_alusrc <= d_alusrc; idex_aluop <= d_aluop;
            idex_rs <= rs; idex_rt <= rt; idex_dest <= d_dest;
            idex_rv1 <= rf_rd1; idex_rv2 <= rf_rd2; idex_imm <= imm;

            // ---- EX -> MEM ----
            exmem_valid <= idex_valid;       exmem_regwrite <= idex_regwrite;
            exmem_memread <= idex_memread;   exmem_memwrite <= idex_memwrite;
            exmem_dest <= idex_dest;         exmem_alu <= alu_y;   exmem_store <= opB_fwd;

            // ---- MEM ----
            if (exmem_valid && exmem_memwrite) dmem[exmem_alu[9:2]] <= exmem_store;

            // ---- MEM -> WB ----
            memwb_valid <= exmem_valid;      memwb_regwrite <= exmem_regwrite;
            memwb_memtoreg <= exmem_memread; memwb_dest <= exmem_dest;
            memwb_alu <= exmem_alu;          memwb_mem <= mem_rdata;
        end
    end
endmodule
