// Staged pipelined CPU adapter. Machine qualification is pending.

module cpu040
#(
	parameter AP040_HAS_FPU = 0,
	// Lean Q800 donor: a two-entry posted-write queue below the caches for
	// RAM and VRAM-window stores (wombat_store_buffer). 0 restores direct writes.
`ifdef AP040_STORE_BUFFER_OFF
	parameter AP040_STORE_BUFFER = 0
`else
	parameter AP040_STORE_BUFFER = 1
`endif
)
(
	input         clk,
	input         nreset,
	input         ce,

	input   [2:0] ipl,            // active low
	input         ipl_autovector,
	input         berr,
	input         stall_hold,
	output        dbg_stall_flt,

	input         cache_line_valid,
	input  [31:4] cache_line_tag,
	input [127:0] cache_line_data,
	input         store_buffer_ok,

	output        bus_req,
	output        bus_write,
	output        bus_instr,
	output  [1:0] bus_size,       // AP040_SZ_B/W/L
	output [31:0] bus_addr,
	output [31:0] bus_wdata,
	output  [2:0] bus_fc,
	input         bus_ack,
	input  [31:0] bus_rdata,
	output        bus_line_more,  // a line read with beats after this one

	output        walker_req,
	output        walker_we,
	output [31:0] walker_addr,
	output [31:0] walker_wdat,
	input         walker_ack,
	input  [31:0] walker_data,
	input         walker_berr,

	input         snoop_stb,
	input  [31:0] snoop_addr,

	output        nresetout,
	output        nmi_ack_toggle,
	output [31:0] cacr_out,
	output [31:0] vbr_out,
	output        debug_busy,
	output        debug_fault,
	output        debug_halted,
	output [255:0] debug_status,
	output [127:0] debug_status2,
	output [63:0] debug_test_status,
	output [31:0] debug_instruction_pc,

	// perf counters (rtl/perf_counters.sv), shown by the DAFB overlay
	input         perf_clear,
	input         perf_freeze,
	input   [2:0] perf_page,
	input  [11:0] perf_vram_ev,
	output [223:0] perf_rows,
	input   [5:0] perf_rd_idx,
	output [31:0] perf_rd_data
);

wire [31:0] c_a, c_do;
wire        c_a_oe, c_rw_n, c_ts_n, c_rsto_n, c_mi_n;
wire  [1:0] c_siz, c_tt;
wire  [2:0] c_tm;
wire [31:0] dbg_pc;
wire        dbg_halted;
wire        dbg_retire;
wire [63:0] dbg_pev;
wire [15:0] dbg_perf;
wire [255:0] dbg_trap;          // last F-line / illegal trap (perf words 23-26)
wire [31:0] c_di;
wire        c_ta_n, c_tea_n, c_tci_n, c_avec_n;
wire        c_lock_n;
// the adapter's side of the optional store buffer
wire        cpu_bus_req, cpu_bus_write, cpu_bus_instr, cpu_bus_ack, cpu_line_more;
wire  [1:0] cpu_bus_size;
wire [31:0] cpu_bus_addr, cpu_bus_wdata, cpu_bus_rdata;
wire  [2:0] cpu_bus_fc;

ap68040 #(
	.HAS_FPU(AP040_HAS_FPU), .FPU_REVISION(8'h41),
	.FPU_PIPE(0), .LOOP_PRED(0), .EARLY_RES(0), .DC1_ATC(0), .SKID(0), .DIV_STEPS(2),
	.DUAL(0), .BTIC(0),
	// only RAM ($0-$3FFFFFFF) and the ROM window ($4xxxxxxx) are cacheable:
	// everything else is a device, never read speculatively
	// (the DMU has no posted VRAM stores: the Q800 donor's posting hung the
	// core under load -- Speedometer, 100 MB / 32-bit -- for no measured
	// speed, and was removed with its direct VRAM read paths)
	.PA_IO_SERIAL(1),
	.PA_C0_MASK(32'hC000_0000), .PA_C0_MATCH(32'h0000_0000),
	.PA_C1_MASK(32'hF000_0000), .PA_C1_MATCH(32'h4000_0000),
	// ... except the frame buffer ($F9000000-$F91FFFFF): reading it has no
	// side effects, so a plain read there need not wait for older
	// instructions to complete (one clock a VRAM read)
	.PA_NS_MASK(32'hFFE0_0000), .PA_NS_MATCH(32'hF900_0000)
) cpu (
	.clk(clk),
	.bclk_en(1'b1),
	.rsti_n(nreset),
	.dbcc_floor(4'd0),

	.a_o(c_a), .a_oe(c_a_oe), .d_o(c_do), .d_oe(),
	.rw_n(c_rw_n), .siz(c_siz), .tt(c_tt), .tm(c_tm), .tln(), .upa(),
	.ciout_n(), .lock_n(c_lock_n), .locke_n(), .ts_n(c_ts_n), .tip_n(),
	.d_i(c_di), .ta_n(c_ta_n), .tea_n(c_tea_n), .tci_n(c_tci_n), .tbi_n(1'b1),
	.ipl_n(ipl), .avec_n(c_avec_n), .ipend_n(),
	// the only master: the bus is granted for good
	.br_n(), .bg_n(1'b0), .bb_n_i(1'b1), .bb_n_o(), .bb_oe(),
	// nothing else drives the bus, so nothing is snooped
	.a_i(32'd0), .ts_n_i(1'b1), .rw_n_i(1'b1), .siz_i(2'd0), .tt_i(2'd0), .sc(2'b00),
	.mi_n(c_mi_n), .ta_n_o(), .ta_oe(),
	.rsto_n(c_rsto_n), .cdis_n(1'b1), .mdis_n(1'b1), .pst(),
	.dbg_pc(dbg_pc), .dbg_retire(dbg_retire), .dbg_halted(dbg_halted),
	.dbg_pev(dbg_pev), .dbg_perf(dbg_perf), .dbg_trap(dbg_trap)
);

bus040 bus_adapter (
    .clk(clk), .nreset(nreset), .stall_hold(stall_hold),
    .c_a(c_a), .c_do(c_do), .c_a_oe(c_a_oe), .c_rw_n(c_rw_n),
    .c_ts_n(c_ts_n), .c_siz(c_siz), .c_tt(c_tt), .c_tm(c_tm),
    .c_di(c_di), .c_ta_n(c_ta_n), .c_tea_n(c_tea_n),
    .c_tci_n(c_tci_n), .c_avec_n(c_avec_n),
    .bus_req(cpu_bus_req), .bus_write(cpu_bus_write), .bus_instr(cpu_bus_instr),
    .bus_size(cpu_bus_size), .bus_addr(cpu_bus_addr), .bus_wdata(cpu_bus_wdata),
    .bus_fc(cpu_bus_fc), .bus_ack(cpu_bus_ack), .bus_rdata(cpu_bus_rdata),
    .berr(berr), .dbg_stall_flt(dbg_stall_flt), .busy(debug_busy),
    .line_more(cpu_line_more)
);

generate if (AP040_STORE_BUFFER != 0) begin : g_store_buffer
	// Only non-faulting RAM/VRAM writes are posted. The host qualifier
	// excludes the boot overlay; the queue checks the physical window.
	// Locked writes go directly. Reads and non-posted writes drain older
	// stores first (one different-line read may pass), preserving device
	// and RMW ordering.
	wombat_store_buffer #(.ENABLE(1)) store_buffer (
		.clk(clk), .nreset(nreset), .ce(ce),
		.buffer_writes(store_buffer_ok && c_lock_n),
		.s_req(cpu_bus_req), .s_posted(1'b0), .s_write(cpu_bus_write),
		.s_instr(cpu_bus_instr), .s_size(cpu_bus_size),
		.s_addr(cpu_bus_addr), .s_wdata(cpu_bus_wdata), .s_fc(cpu_bus_fc),
		.s_ack(cpu_bus_ack), .s_rdata(cpu_bus_rdata), .s_line_more(cpu_line_more),
		.s_xfer(debug_busy),
		.m_req(bus_req), .m_write(bus_write), .m_instr(bus_instr),
		.m_size(bus_size), .m_addr(bus_addr), .m_wdata(bus_wdata), .m_fc(bus_fc),
		.m_ack(bus_ack), .m_rdata(bus_rdata), .m_err(berr), .m_line_more(bus_line_more),
		.pending()
	);
end else begin : g_no_store_buffer
	assign bus_req       = cpu_bus_req;
	assign bus_write     = cpu_bus_write;
	assign bus_instr     = cpu_bus_instr;
	assign bus_size      = cpu_bus_size;
	assign bus_addr      = cpu_bus_addr;
	assign bus_wdata     = cpu_bus_wdata;
	assign bus_fc        = cpu_bus_fc;
	assign cpu_bus_ack   = bus_ack;
	assign cpu_bus_rdata = bus_rdata;
	assign bus_line_more = cpu_bus_req && !cpu_bus_write && cpu_line_more;
end endgenerate

//----------------------------------------------------------------------------
// the rest of wombat_cpu's ports
//----------------------------------------------------------------------------
perf_counters perf (
	.clk(clk), .clear(perf_clear), .freeze(perf_freeze), .page(perf_page),
	.retire(dbg_pev[56]), .retire2(dbg_pev[57]), .core(dbg_perf),
	.c_req(cpu_bus_req), .c_ack(cpu_bus_ack), .c_write(cpu_bus_write),
	.c_instr(cpu_bus_instr), .c_line(c_siz == 2'b11), .c_addr(cpu_bus_addr),
	.m_req(bus_req), .m_ack(bus_ack), .vram_ev(perf_vram_ev),
	.trap(dbg_trap),
	.row1(perf_rows[223:160]), .row2(perf_rows[159:128]),
	.row3(perf_rows[127:64]), .row4(perf_rows[63:0]),
	.rd_idx(perf_rd_idx), .rd_data(perf_rd_data)
);

assign walker_req     = 1'b0;
assign walker_we      = 1'b0;
assign walker_addr    = 32'd0;
assign walker_wdat    = 32'd0;
assign nresetout      = c_rsto_n;
assign nmi_ack_toggle = 1'b0;
assign cacr_out       = 32'd0;
assign vbr_out        = 32'd0;
assign debug_fault    = 1'b0;
assign debug_halted   = dbg_halted;
// the PC of the last instruction to retire.  dbg_retire is registered (set on
// the edge the last uop commits) while dbg_pc is the uop in WB now: by the
// time dbg_retire is seen, WB may hold the next uop -- on a discarded path as
// often as not -- so the PC is the one WB held a clock earlier.
reg  [31:0] retired_pc, wb_pc_d;
always @(posedge clk) begin
    if (!nreset) begin
        wb_pc_d <= 0;
        retired_pc <= 0;
    end
    else begin
        wb_pc_d <= dbg_pc;
        if (dbg_retire) retired_pc <= wb_pc_d;
    end
end
assign debug_status   = {224'd0, retired_pc};
assign debug_status2  = 128'd0;
assign debug_test_status = 64'd0;
assign debug_instruction_pc = retired_pc;

// synthesis translate_off
always @(posedge clk) if (nreset) begin
    if (!ce || snoop_stb || !ipl_autovector)
        $fatal(1, "Unsupported staged CPU interface mode");
end
// synthesis translate_on

endmodule
