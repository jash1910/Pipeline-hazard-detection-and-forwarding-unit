# Prototype video script (target 4:30, limit 5:00)

Record the screen with QuickTime (File > New Screen Recording). Run the commands live;
the screenshots in `contributions/Jashvitha/screenshots/` are the backup if a command is slow.

| Time | Speaker | On screen | What to say |
|---|---|---|---|
| 0:00-0:40 | each member, 10 s each | title slide / README | "Hi, I'm Jashvitha, team lead..." then Chaitanya, Palak, Samarth: name + the module you built. (The circular expects 5 members; if a fifth member is added, they introduce themselves here.) |
| 0:40-1:20 | Jashvitha | `docs/figures/block_diagram.png` | Project idea: RAW hazards in a 5-stage pipeline. ADD->SUB needs r1 before it is written back. Forwarding sends the result from EX/MEM or MEM/WB straight to the ALU; a load's data is ready only after MEM, so LW followed by a use needs exactly one stall. Point to the forwarding unit, hazard unit, stall/flush control. |
| 1:20-1:50 | Chaitanya | `rtl/forwarding_unit.v`, then `./scripts/show.sh unit-fwd` | Comparator + forwarding unit: EX/MEM priority, R0 never forwarded, load in EX/MEM is not a source. 32k vectors, 0 errors. |
| 1:50-2:10 | Palak | `./scripts/show.sh unit-rfalu` | Register file with R0 = 0 and write-before-read bypass (removes the distance-3 hazard); ALU. |
| 2:10-2:30 | Samarth | `docs/hazard_cases.md` | The 16 hazard cases and what each one proves. |
| 2:30-3:40 | Jashvitha | `./scripts/show.sh test 3 2 trace`, then GTKWave or `wave_test03` figure | Load-use: ADD held in ID one cycle, bubble in EX, value forwarded from MEM/WB. Show the same test in MODE 1 (2 stalls). Then `./run_all.sh`: all unit, directed and 100 random tests pass against the golden model; MODE 0 fails as expected. |
| 3:40-4:20 | Jashvitha | `./scripts/show.sh cpi-table`, CPI chart | 214 -> 158 cycles (26.2% fewer); random CPI 1.462 -> 1.136; Test 16 shows scheduling removes load-use stalls. |
| 4:20-4:40 | Jashvitha | README | Phase II: branches + flush, store-data forwarding, synthesis. Repo link. |
