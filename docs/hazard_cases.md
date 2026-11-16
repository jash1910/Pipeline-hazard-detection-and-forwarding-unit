# Hazard test-case catalogue (directed tests in testbench/tb_processor.v)

Initial registers: r2=10 r3=5 r4=20 r5=3 r7=19 r8=10 (tests 3,7,8,9,10,13: r2=100 r4=5), mem[25]=20.
"dist" = how many instructions after the producer the consumer comes. Expected values are for MODE 2.

| #  | Program (MIPS-style)                    | Hazard                        | dist | Stall | Fwd | Key result checked   |
|----|-----------------------------------------|-------------------------------|------|-------|-----|----------------------|
| 1  | ADD r1,r2,r3 ; SUB r4,r1,r5             | RAW, ALU -> ALU               | 1    | 0     | 1   | r4 = 12 (EX/MEM)     |
| 2  | ADD r1,r2,r3 ; AND r6 ; SUB r4,r1,r5    | RAW, ALU -> ALU               | 2    | 0     | 1   | r4 = 12 (MEM/WB)     |
| 3  | LW r1,0(r2) ; ADD r3,r1,r4              | load-use                      | 1    | 1     | 1   | r3 = 25              |
| 4  | ADD r1 ; SUB r1 ; AND r6,r1,r7          | two producers, newest wins    | 1, 2 | 0     | 1   | r6 = 17 (not 15&19)  |
| 5  | ADD r0,r2,r3 ; SUB r4,r0,r5             | write to R0                   | 1    | 0     | 0   | r4 = -3, r0 = 0      |
| 6  | ADD ; SUB ; OR (no shared registers)    | none                          | -    | 0     | 0   | no false stalls      |
| 7  | LW r1 ; ADD r6,r4,r5 ; SUB r9,r1,r5     | load, independent, use        | 2    | 0     | 1   | r9 = 17              |
| 8  | 11-instruction mix of LW/SW/ADDI/ALU    | all of the above              | mix  | 2     | 9   | 8 regs + 2 mem words |
| 9  | LW r1,0(r2) ; SW r1,4(r2)               | load -> store data            | 1    | 1     | 1   | mem[26] = 20         |
| 10 | LW r1 ; ADD r3,r1,r4 ; SUB r6,r3,r5     | load-use, then ALU chain      | 1, 1 | 1     | 2   | r6 = 22              |
| 11 | ADDI r1,r2,7 ; ADD r6,r1,r3             | RAW, I-type -> R-type         | 1    | 0     | 1   | r6 = 22              |
| 12 | ADD r1,r2,r3 ; SW r1,0(r4)              | RAW on store data (operand B) | 1    | 0     | 1   | mem[5] = 15          |
| 13 | LW r1 ; ADD r6,r4,r5 ; ADD r9,r1,r6     | load dist 2 + ALU dist 1      | 2, 1 | 0     | 1   | r9 = 28              |
| 14 | SLT (unsupported) ; ADD ; opcode 0x3F   | illegal encodings -> NOP      | -    | 0     | 0   | r1 untouched         |
| 15 | vector add C=A+B, naive order (21 inst) | 4 load-use pairs              | 1    | 4     | 13  | C = 13,27,41,55; 136 |
| 16 | same kernel, loads scheduled early      | load-use removed by schedule  | >= 2 | 0     | 8   | identical results    |

Every test is also checked in MODE 1 (stall-only) and MODE 0 (no handling, expected to fail),
against the golden reference model, and against the analytical stall/forward/cycle model.
