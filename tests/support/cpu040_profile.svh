// Included by tb_cpu040_machine. Synthetic workloads, not Speedometer scores.
localparam PROFILE_CASES = 16;
string profile_name [0:PROFILE_CASES-1];
reg [31:0] profile_start [0:PROFILE_CASES-1], profile_end [0:PROFILE_CASES-1];
integer profile_cycles = 0;
integer profile_beats [0:4] = '{default:0};
integer profile_waits [0:4] = '{default:0};
bit profile_active = 0;
integer profile_engine [string];
integer profile_biu [string];
integer profile_dc2_hold = 0, profile_wb_hold = 0;

// Instruction, RAM read/write, VRAM read/write. Count machine-bus occupancy.
always @(posedge clk) begin : profile_count
    integer kind;
    if (nreset && $test$plusargs("PROFILE")) begin
        profile_cycles++;
        if (profile_active) begin
            profile_engine[dut.cpu.cpu.dmu.e_st.name()]++;
            profile_biu[dut.cpu.cpu.biu.st.name()]++;
            if (dut.cpu.cpu.dmu.m2.r.v && !dut.cpu.cpu.dmu.adv_dc2) profile_dc2_hold++;
            if (dut.cpu.cpu.dmu.m4.r.v && !dut.cpu.cpu.dmu.adv_wb) profile_wb_hold++;
        end
        if (dut.bus_req) begin
            kind = dut.bus_instr ? 0 :
                   dut.bus_addr[31:24] == 8'hF9 ? (dut.bus_write ? 4 : 3) :
                   (dut.bus_write ? 2 : 1);
            if (dut.bus_ack) profile_beats[kind]++;
            else profile_waits[kind]++;
        end
    end
end

// The hardware perf counters (rtl/perf_counters.sv) count from time zero and
// are never cleared here; check them against this file's own counts.
task automatic perf_check(input integer runs);
    integer m_req, m_wait, m16r, m16w;
    for (integer p = 0; p < 7; p++)
        $display("PROFILE: perf page %0d: %0d %0d %0d %0d %0d %0d", p,
                 dut.cpu.perf.cnt[p*6], dut.cpu.perf.cnt[p*6+1], dut.cpu.perf.cnt[p*6+2],
                 dut.cpu.perf.cnt[p*6+3], dut.cpu.perf.cnt[p*6+4], dut.cpu.perf.cnt[p*6+5]);
    m_req = 0; m_wait = 0;
    for (integer i = 0; i < 5; i++) begin
        m_req += profile_beats[i] + profile_waits[i];
        m_wait += profile_waits[i];
    end
    if (dut.cpu.perf.cnt[0] < profile_cycles || dut.cpu.perf.cnt[28] != m_req ||
        dut.cpu.perf.cnt[29] != m_wait || dut.cpu.perf.cnt[24] != profile_beats[3] ||
        dut.cpu.perf.cnt[26] != profile_beats[4])
        $fatal(1, "Perf counters disagree: cycles %0d/%0d, bus %0d/%0d, waits %0d/%0d, VRAM-R %0d/%0d, VRAM-W %0d/%0d",
               dut.cpu.perf.cnt[0], profile_cycles, dut.cpu.perf.cnt[28], m_req,
               dut.cpu.perf.cnt[29], m_wait, dut.cpu.perf.cnt[24], profile_beats[3],
               dut.cpu.perf.cnt[26], profile_beats[4]);
    $display("PASS: perf counters agree with the profile's bus counts");
    // the engine's own counts of frame buffer accesses: no workload here is
    // split, so a store is one beat; a read can be discarded after dispatch.
    // A MOVE16 is one access and four beats each way: a run's 256 from
    // VRAM, and the one the copy loop's exit discards (a PA_NS read, on the
    // bus before the branch resolves), read 771 beats more than accesses;
    // its 512 to VRAM write 1536 more (the counters run on across the
    // runs).  Slots 32 and 37 (the fast reads and posted stores, both gone
    // from the DMU) count RAM data line reads now: all VRAM accesses take
    // the general path.
    m16r = 771 * runs;
    m16w = 1536 * runs;
    if (dut.cpu.perf.cnt[38] + m16w != dut.cpu.perf.cnt[26] ||
        dut.cpu.perf.cnt[35] != 0 ||
        dut.cpu.perf.cnt[33] + m16r < dut.cpu.perf.cnt[24] ||
        dut.cpu.perf.cnt[33] + m16r >
            dut.cpu.perf.cnt[24] + dut.cpu.perf.cnt[24] / 50)
        $fatal(1, "VRAM path counters disagree: reads general %0d vs beats %0d, stores slow %0d vs beats %0d",
               dut.cpu.perf.cnt[33], dut.cpu.perf.cnt[24],
               dut.cpu.perf.cnt[38], dut.cpu.perf.cnt[26]);
    $display("PASS: VRAM reads general %0d vs beats %0d, stores slow %0d vs beats %0d",
             dut.cpu.perf.cnt[33], dut.cpu.perf.cnt[24],
             dut.cpu.perf.cnt[38], dut.cpu.perf.cnt[26]);
`ifdef VRAM_DDR3
    // every VRAM read beat is a hit, a fill, or acked by a prefetch's fill
    // beat (page 5; prefetches are no longer counted, so allow 2% for them)
    if (dut.cpu.perf.cnt[30] + dut.cpu.perf.cnt[31] >
            dut.cpu.perf.cnt[24] + dut.cpu.perf.cnt[24] / 50 ||
        dut.cpu.perf.cnt[30] + dut.cpu.perf.cnt[31] +
            dut.cpu.perf.cnt[24] / 50 < dut.cpu.perf.cnt[24])
        $fatal(1, "VRAM perf events disagree: hits %0d + fills %0d vs read beats %0d",
               dut.cpu.perf.cnt[30], dut.cpu.perf.cnt[31], dut.cpu.perf.cnt[24]);
    $display("PASS: VRAM hits %0d + fills %0d vs read beats %0d",
             dut.cpu.perf.cnt[30], dut.cpu.perf.cnt[31], dut.cpu.perf.cnt[24]);
`endif
endtask

// +TRACE_VRAM_RD: one line per clock through a few iterations of one case
// (+TRACE_CASE=n, default 7, the masked update; first run only)
integer trace_left = 0, trace_case = 7;
initial void'($value$plusargs("TRACE_CASE=%d", trace_case));
always @(posedge clk) begin
    if ($test$plusargs("TRACE_VRAM_RD") && profile_active && profile_name[trace_case] != "" &&
        dut.cpu_instruction_pc >= profile_start[trace_case] - 12 &&
        dut.cpu_instruction_pc <= profile_end[trace_case] &&
        trace_left < 120) begin
        trace_left++;
        $display("TRACE %0d pc=%h e=%s biu=%s ts=%b ta=%b breq=%b back=%b bw=%b ba=%h svc=%0d mreq=%b mack=%b vwp=%b",
                 profile_cycles, dut.cpu_instruction_pc, dut.cpu.cpu.dmu.e_st.name(),
                 dut.cpu.cpu.biu.st.name(), dut.cpu.c_ts_n, dut.cpu.c_ta_n,
                 dut.bus_req, dut.bus_ack, dut.bus_write, dut.bus_addr, dut.svc,
                 mem_req, mem_ack, mem_vram_wp);
        $display("TRACEP %0d v=%b%b%b%b mem2=%0d mem4=%0d adv=%b%b%b%b d2done=%b gnt=%b done=%b older=%b slow=%b hold1=%b kill=%b",
                 profile_cycles, dut.cpu.cpu.dmu.m1.v, dut.cpu.cpu.dmu.m2.r.v, dut.cpu.cpu.dmu.m3.r.v,
                 dut.cpu.cpu.dmu.m4.r.v, dut.cpu.cpu.dmu.m2.r.mem, dut.cpu.cpu.dmu.m4.r.mem,
                 dut.cpu.cpu.dmu.adv_dc1, dut.cpu.cpu.dmu.adv_dc2, dut.cpu.cpu.dmu.adv_ex,
                 dut.cpu.cpu.dmu.adv_wb, dut.cpu.cpu.dmu.e_dc2_done, dut.cpu.cpu.dmu.b_gnt,
                 dut.cpu.cpu.dmu.b_done, dut.cpu.cpu.dmu.dm_older,
                 dut.cpu.cpu.dmu.dc2_slow, dut.cpu.cpu.dmu.dm_hold1,
                 dut.cpu.cpu.dmu.kill_now);
    end
end

task automatic profile_loop(input integer which);
    integer loop_pc;
    // cases 11-15: RAM in copyback mode (DTT0 over the low 16 MB, as Mac OS
    // runs it on an 040); the others keep the default write-through mode
    if (which >= 11) begin
        emit16('h203C); emit32('h0000C020); // MOVE.L #DTT0,D0
        emit16('h4E7B); emit16('h0006); // MOVEC D0,DTT0
    end
    emit16('h207C); emit32(which == 15 ? 'h18000 : which == 14 ? 'h10000 : which == 13 ? 'h3100 : which >= 11 ? 'h3000 : which == 10 ? 'h4000 : which < 3 ? (which == 2 ? 'h4000 : 'h2000) :
                          (which == 9 ? 'hF9006000 : which == 8 ? 'hF9005000 : which == 7 ? 'hF9004000 :
                           which == 5 ? 'hF9002000 : which == 4 ? 'hF9001000 : 'hF9000000)); // MOVEA.L #a,A0
    if (which == 7) begin
        emit16('h243C); emit32('hFFFF0000); // MOVE.L #mask,D2
        emit16('h263C); emit32('h0000ABCD); // MOVE.L #pattern,D3
    end
    emit16('h227C); emit32(which == 15 ? 'h1C000 : which == 14 ? 'h14000 : which == 10 ? 'hF9008000 : which == 9 ? 'hF9007000 : 'hF9003000); // MOVEA.L #a,A1
    emit16('h7000); // MOVEQ #0,D0
    emit16('h323C); emit16(255); // MOVE.W #255,D1
    loop_pc = pc;
    case (which)
        0: begin
            profile_name[which] = "cached integer (four ADDQ)";
            repeat (4) emit16('h5280); // ADDQ.L #1,D0
        end
        1,5: begin
            profile_name[which] = which == 1 ? "cached RAM read/modify/write" : "VRAM read/modify/write";
            emit16('h2010); // MOVE.L (A0),D0
            emit16('h5280); // ADDQ.L #1,D0
            emit16('h2080); // MOVE.L D0,(A0)
        end
        2,3: begin
            profile_name[which] = which == 2 ? "RAM sequential read" : "VRAM sequential read";
            emit16('h2018); // MOVE.L (A0)+,D0
        end
        4: begin
            profile_name[which] = "VRAM sequential write";
            emit16('h20C0); // MOVE.L D0,(A0)+
            emit16('h5280); // ADDQ.L #1,D0
        end
        6: begin
            profile_name[which] = "VRAM sequential copy";
            emit16('h22D8); // MOVE.L (A0)+,(A1)+
        end
        7: begin
            // QuickDraw-shaped: a masked pixel update along a row
            profile_name[which] = "VRAM masked read/modify/write";
            emit16('h2010); // MOVE.L (A0),D0
            emit16('hC082); // AND.L D2,D0
            emit16('h8083); // OR.L D3,D0
            emit16('h20C0); // MOVE.L D0,(A0)+
        end
        8: begin
            // one instruction that reads and writes its operand (QuickDraw's
            // invert, OR and XOR transfer loops)
            profile_name[which] = "VRAM read-modify-write instruction";
            emit16('h4698); // NOT.L (A0)+
        end
        9: begin
            // 16-byte line transfers (the block copy the Speedometer
            // graphics test spends its copy phase in)
            profile_name[which] = "VRAM MOVE16 copy";
            emit16('hF620); emit16('h9000); // MOVE16 (A0)+,(A1)+
        end
        10: begin
            // the same from RAM: the first 64 source lines are in the data
            // cache (case 2 read them), the rest come from the bus
            profile_name[which] = "RAM to VRAM MOVE16 copy";
            emit16('hF620); emit16('h9000); // MOVE16 (A0)+,(A1)+
        end
        11: begin
            profile_name[which] = "copyback RAM read/modify/write";
            emit16('h2010); // MOVE.L (A0),D0
            emit16('h5280); // ADDQ.L #1,D0
            emit16('h2080); // MOVE.L D0,(A0)
        end
        12: begin
            // stack push and pop (SP is the reset SSP, 0x7000); pops into
            // D0, not D1, which is the loop counter
            profile_name[which] = "copyback stack push/pop";
            emit16('h2F00); // MOVE.L D0,-(SP)
            emit16('h201F); // MOVE.L (SP)+,D0
            emit16('h5280); // ADDQ.L #1,D0
        end
        13: begin
            // a load behind a store to another longword of the same line
            profile_name[which] = "copyback load after store, same line";
            emit16('h2080); // MOVE.L D0,(A0)
            emit16('h2428); emit16(4); // MOVE.L 4(A0),D2
            emit16('h5280); // ADDQ.L #1,D0
        end
        14: begin
            // BlockMove's copy: RAM to RAM by lines, 8 KB (twice the data
            // cache), so the source comes from the bus
            profile_name[which] = "copyback RAM to RAM MOVE16 copy, 8 KB";
            repeat (2) begin
                emit16('hF620); emit16('h9000); // MOVE16 (A0)+,(A1)+
            end
        end
        15: begin
            // the same 8 KB by longwords (BlockMove without MOVE16)
            profile_name[which] = "copyback RAM to RAM MOVE.L copy, 8 KB";
            repeat (8) emit16('h22D8); // MOVE.L (A0)+,(A1)+
        end
    endcase
    profile_start[which] = 'h40800000 + pc;
    emit16('h51C9); emit16(16'(loop_pc - pc)); // DBRA D1,loop
    profile_end[which] = 'h40800000 + pc;
    emit16('h4E71); // NOP: end marker
    if (which >= 11) begin
        // push the dirty lines, then back to write-through so the
        // signature store reaches the bus
        emit16('hF478); // CPUSHA DC
        emit16('h7400); // MOVEQ #0,D2
        emit16('h4E7B); emit16('h2006); // MOVEC D2,DTT0
    end
    emit16('h23C0); emit32('h100 + which*4); // result signature
    case (which)
        0: expected[which] = 1024;
        1,4,5,11,12,13: expected[which] = 256;
        2,3: expected[which] = 'h12345678;
        6,8,9,10,14,15: expected[which] = 0;
        7: expected[which] = 'h0000ABCD;
    endcase
endtask

function automatic [29:0] mapped_of(input integer a);
    reg [30:0] m;
    m = dut.ram_map(30'(a >> 2));
    return m[29:0];
endfunction

task automatic run_profile;
    integer first_cycle, engine_total, biu_total;
    reg [30:0] mapped, rmw_mapped;
    integer backing_addr;
    integer first_beats [0:4], first_waits [0:4];
    integer first_vq_full, first_vd_rd, first_vd_wr;
    integer run_vram_w;
    pc = 0; emit32('h7000); emit32('h40800400);
    pc = 'h400;
    emit16('hF4D8); // CINVA BC
    store('h5000E07C, 'h10); // MEMCjr holding latch: bank mode bit
    store('h5000E004, 0); // bank 0 mode 1: four-megabyte soldered RAM mapping
    emit16('h203C); emit32('h80008000);
    emit16('h4E7B); emit16('h0002); // enable instruction/data caches
    for (integer k = 0; k < PROFILE_CASES; k++) profile_loop(k);
    done_pc = 'h40800000 + pc;
    emit16('h4E72); emit16('h2700);
    expected_count = PROFILE_CASES;

    for (integer run = 0; run < 2; run++) begin
        nreset = 0;
        repeat (8) @(negedge clk);
        for (integer i = 0; i < 4194304; i++) ram[i] = 0;
        for (integer i = 0; i < 65536; i++) vram[i] = 0;
        for (integer i = 0; i < 1024; i += 4) begin
            vram[i] = 'h12; vram[i+1] = 'h34; vram[i+2] = 'h56; vram[i+3] = 'h78;
        end
        // MOVE16 source: every byte differs from its neighbours and from
        // the byte one line (16 bytes) on
        for (integer i = 0; i < 4096; i++) vram['h6000+i] = 8'(i*7 + (i >> 8));
        signatures = 0; transfers = 0; posts = 0;
        retain = 1; delay_cycles = run*3;
        $display("PROFILE: %s, 25 MHz, retained RAM/ROM, modeled RAM/ROM reply delay=%0d; production VRAM port timing",
`ifdef VRAM_DDR3
                 $sformatf("DDR3 VRAM rd_lat=%0d line=%0d stride=%0d", ddr_rd_lat, line_clks, vid_stride_bytes),
`else
                 "BRAM VRAM",
`endif
                 delay_cycles);
        run_vram_w = profile_beats[4];
        nreset = 1;
        wait (dut.memc_bank_mode[0]);
        @(negedge clk);
        // The fixture array uses SDRAM backing addresses, not CPU addresses.
        rmw_mapped = dut.ram_map(30'('h2000 >> 2));
        if (!rmw_mapped[30]) $fatal(1, "Profile RAM update region is unpopulated");
        for (integer i = 0; i < 1024; i += 4) begin
            mapped = dut.ram_map(30'(('h4000+i) >> 2));
            backing_addr = {mapped[29:0], 2'b00};
            if (!mapped[30] || backing_addr < 0 || backing_addr > 4194300 ||
                mapped == rmw_mapped)
                $fatal(1, "Profile RAM read/update regions overlap or exceed backing");
            ram[backing_addr] = 'h12; ram[backing_addr+1] = 'h34;
            ram[backing_addr+2] = 'h56; ram[backing_addr+3] = 'h78;
        end
        // the rest of the RAM MOVE16 source (case 10), past case 2's data
        for (integer i = 1024; i < 4096; i += 4) begin
            mapped = dut.ram_map(30'(('h4000+i) >> 2));
            backing_addr = {mapped[29:0], 2'b00};
            if (!mapped[30] || backing_addr < 0 || backing_addr > 4194300 ||
                mapped == rmw_mapped)
                $fatal(1, "Profile RAM MOVE16 source overlaps or exceeds backing");
            for (integer j = 0; j < 4; j++)
                ram[backing_addr+j] = 8'((i+j)*5 + ((i+j) >> 8) + 1);
        end
        // the copyback copy sources (cases 14 and 15), 8 KB each
        for (integer i = 0; i < 'h2000; i += 4)
            for (integer s = 0; s < 2; s++) begin
                mapped = dut.ram_map(30'(((s ? 'h18000 : 'h10000)+i) >> 2));
                backing_addr = {mapped[29:0], 2'b00};
                if (!mapped[30] || backing_addr < 0 || backing_addr > 4194300)
                    $fatal(1, "Profile RAM copy source exceeds backing");
                for (integer j = 0; j < 4; j++)
                    ram[backing_addr+j] = 8'((i+j)*3 + ((i+j) >> 8) + s*11 + 2);
            end
        if (read32(0, {rmw_mapped[29:0], 2'b00}) !== 32'd0)
            $fatal(1, "Profile RAM update region was not initialized to zero");
        for (integer k = 0; k < PROFILE_CASES; k++) begin
            // First DBRA retirement to the end marker: 255 warm iterations + NOP.
            do @(negedge clk); while (dut.cpu_instruction_pc != profile_start[k]);
            profile_engine.delete(); profile_biu.delete();
            profile_dc2_hold = 0; profile_wb_hold = 0;
            profile_active = 1;
            first_cycle = profile_cycles;
`ifdef VRAM_DDR3
            first_vq_full = vq_full; first_vd_rd = vd_busy_rd; first_vd_wr = vd_busy_wr;
`endif
            for (integer b = 0; b < 5; b++) begin
                first_beats[b] = profile_beats[b]; first_waits[b] = profile_waits[b];
            end
            do @(negedge clk); while (dut.cpu_instruction_pc != profile_end[k]);
            profile_active = 0;
            $display("PROFILE: %s: %0d cycles / (255 warm iterations + NOP), %0.3f interval cycles/iteration",
                     profile_name[k], profile_cycles-first_cycle, real'(profile_cycles-first_cycle)/255.0);
            $display("PROFILE:   beats I/RAM-R/RAM-W/VRAM-R/VRAM-W=%0d/%0d/%0d/%0d/%0d; waits=%0d/%0d/%0d/%0d/%0d",
                     profile_beats[0]-first_beats[0], profile_beats[1]-first_beats[1],
                     profile_beats[2]-first_beats[2], profile_beats[3]-first_beats[3], profile_beats[4]-first_beats[4],
                     profile_waits[0]-first_waits[0], profile_waits[1]-first_waits[1],
                     profile_waits[2]-first_waits[2], profile_waits[3]-first_waits[3], profile_waits[4]-first_waits[4]);
`ifdef VRAM_DDR3
            $display("PROFILE:   DDR3 VRAM: write queue full %0d clocks; DDR3 busy reading %0d, writing %0d",
                     vq_full-first_vq_full, vd_busy_rd-first_vd_rd, vd_busy_wr-first_vd_wr);
`endif
            engine_total = 0; biu_total = 0;
            $write("PROFILE:   DMU cycles:");
            foreach (profile_engine[state_name]) begin
                $write(" %s=%0d", state_name, profile_engine[state_name]);
                engine_total += profile_engine[state_name];
            end
            $display("");
            $write("PROFILE:   BIU cycles:");
            foreach (profile_biu[state_name]) begin
                $write(" %s=%0d", state_name, profile_biu[state_name]);
                biu_total += profile_biu[state_name];
            end
            $display("; overlapping pipeline holds DC2=%0d WB=%0d", profile_dc2_hold, profile_wb_hold);
            if (engine_total != profile_cycles-first_cycle || biu_total != engine_total)
                $fatal(1, "Profile state census does not cover the measured interval");
            if (k >= 3 && k <= 10) begin : beat_check
                // a MOVE16 moves a line: four beats each way
                integer per;
                per = k >= 9 ? 4 : 1;
                // a store from the untimed first iteration can reach the
                // bus inside the window: one extra write beat; the run's
                // exact total is checked at the end.  A read behind the
                // loop's last DBRA can reach the bus and be discarded
                if ((k == 4 || k == 10 ? profile_beats[3]-first_beats[3] != 0 :
                     (profile_beats[3]-first_beats[3] < 255*per ||
                      profile_beats[3]-first_beats[3] > 256*per)) ||
                    (k == 3 ? profile_beats[4]-first_beats[4] != 0 :
                     (profile_beats[4]-first_beats[4] < 255*per ||
                      profile_beats[4]-first_beats[4] > 256*per)))
                    $fatal(1, "Profile VRAM workload lost or duplicated a bus beat");
            end
        end
        wait (dut.cpu_instruction_pc == done_pc);
        repeat (40) @(negedge clk);
`ifdef VRAM_DDR3
        // the checks below read the DDR3 model: let the write FIFO drain
        // first (a normal drain waits behind a scanline fetch's bursts)
        wait (vram_inst.fifo_count == 0 && vram_inst.state == 0);
        @(negedge clk);
`endif
        // five VRAM-writing loops (cases 4-8), 256 stores each, and twice
        // 256 MOVE16 line stores of four beats (cases 9 and 10)
        if (profile_beats[4] - run_vram_w != 3328)
            $fatal(1, "Profile VRAM write beats %0d, expected 3328", profile_beats[4] - run_vram_w);
        if (signatures != expected_count || overlay || dut.cpu.cpu.cacr != 'h80008000)
            $fatal(1, "Profile completion/cache checks failed");
        for (integer i = 0; i < 256; i++) begin
            if ({vram['h1000+i*4], vram['h1001+i*4], vram['h1002+i*4], vram['h1003+i*4]} !== 32'(i))
                $fatal(1, "VRAM write result %0d", i);
            if ({vram['h3000+i*4], vram['h3001+i*4], vram['h3002+i*4], vram['h3003+i*4]} !== 32'h12345678)
                $fatal(1, "VRAM copy result %0d", i);
            if ({vram['h4000+i*4], vram['h4001+i*4], vram['h4002+i*4], vram['h4003+i*4]} !== 32'h0000ABCD)
                $fatal(1, "VRAM masked update result %0d", i);
            if ({vram['h5000+i*4], vram['h5001+i*4], vram['h5002+i*4], vram['h5003+i*4]} !== 32'hFFFFFFFF)
                $fatal(1, "VRAM read-modify-write instruction result %0d", i);
        end
        if ({vram['h2000], vram['h2001], vram['h2002], vram['h2003]} !== 32'd256)
            $fatal(1, "VRAM read/modify/write result");
        for (integer i = 0; i < 4096; i++)
            if (vram['h7000+i] !== 8'(i*7 + (i >> 8)) || vram['h6000+i] !== 8'(i*7 + (i >> 8)))
                $fatal(1, "VRAM MOVE16 copy result %0d", i);
        for (integer i = 0; i < 4096; i++)
            if (vram['h8000+i] !== (i < 1024 ? 8'(32'h12345678 >> (24 - 8*(i % 4))) :
                                               8'(i*5 + (i >> 8) + 1)))
                $fatal(1, "RAM to VRAM MOVE16 copy result %0d", i);
        // the copyback cases' data, pushed by CPUSHA: case 11's count
        // (0x3000), case 12's last push and case 13's last store (255)
        if (read32(0, {mapped_of('h3000), 2'b00}) !== 32'd256 ||
            read32(0, {mapped_of('h6FFC), 2'b00}) !== 32'd255 ||
            read32(0, {mapped_of('h3100), 2'b00}) !== 32'd255)
            $fatal(1, "Profile copyback RAM results %h %h %h",
                   read32(0, {mapped_of('h3000), 2'b00}), read32(0, {mapped_of('h6FFC), 2'b00}),
                   read32(0, {mapped_of('h3100), 2'b00}));
        for (integer i = 0; i < 'h2000; i += 4)
            for (integer s = 0; s < 2; s++)
                if (read32(0, {mapped_of((s ? 'h1C000 : 'h14000) + i), 2'b00}) !==
                    {8'(i*3 + (i >> 8) + s*11 + 2), 8'((i+1)*3 + ((i+1) >> 8) + s*11 + 2),
                     8'((i+2)*3 + ((i+2) >> 8) + s*11 + 2), 8'((i+3)*3 + ((i+3) >> 8) + s*11 + 2)})
                    $fatal(1, "Profile copyback RAM copy result: case %0d offset %h: %h",
                           14 + s, i, read32(0, {mapped_of((s ? 'h1C000 : 'h14000) + i), 2'b00}));
        $display("PASS: CPU040 cycle profile run %0d: %0d workload signatures and VRAM contents", run, PROFILE_CASES);
        perf_check(run + 1);
    end
endtask
