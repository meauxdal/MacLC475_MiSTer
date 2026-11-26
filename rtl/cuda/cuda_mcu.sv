module cuda_mcu #(
    parameter integer CLK_HZ = 25_000_000,
    parameter HOST_STORAGE = 0,
    parameter ROM_FILE = "local/software/cuda341s0788.hex"
) (
    input clk,
    input nreset,
    input ce,
    input [32:0] timestamp,
    input pram_h_we,
    input [6:0] pram_h_addr,
    input [15:0] pram_h_wdata,
    output [15:0] pram_h_rdata,
    output pram_wr_stb,
    output storage_ready,
    input [7:0] pa_in,
    input [7:0] pb_in,
    input [3:0] pc_in,
    input irq_n,
    output [7:0] pa_out,
    output [7:0] pb_out,
    output [3:0] pc_out,
    output reg [7:0] pa_ddr,
    output reg [7:0] pb_ddr,
    output reg [3:0] pc_ddr,
    output cpu_tick,
    output [12:0] cpu_addr,
    output [3:0] cpu_state,
    output stopped,
    output waiting
);

reg [7:0] pa_latch, pb_latch;
reg [3:0] pc_latch;
reg [7:0] pll_ctrl, timer_ctrl, cpi_ctrl;
reg [16:0] timer_count;
reg [14:0] cpi_count;
// At or above the maximum CUDA rate, phase stays below CLK_HZ.
localparam integer CLOCK_PHASE_WIDTH = (CLK_HZ >= 4_194_304) ? $clog2(CLK_HZ) : 32;
localparam integer CLOCK_SUM_WIDTH = (CLOCK_PHASE_WIDTH < 32) ? CLOCK_PHASE_WIDTH + 1 : 32;
reg [CLOCK_PHASE_WIDTH-1:0] clock_phase;
reg restore_active = 0;
wire crystal_tick;
wire [31:0] clock_rate = !pll_ctrl[6] ? 32'd16384 :
    !pll_ctrl[3] ? 32'd0 : (32'd524288 << pll_ctrl[1:0]);
wire [CLOCK_SUM_WIDTH-1:0] clock_sum = CLOCK_SUM_WIDTH'(clock_phase) + CLOCK_SUM_WIDTH'(clock_rate);
wire [CLOCK_PHASE_WIDTH:0] clock_remainder = {1'b0, clock_sum} - (CLOCK_PHASE_WIDTH+1)'(CLK_HZ);
assign cpu_tick = nreset && ce && !restore_active && !clock_remainder[CLOCK_PHASE_WIDTH];
always @(posedge clk) begin
    if (!nreset) clock_phase <= 0;
    else if (ce && !restore_active)
        clock_phase <= cpu_tick ? clock_remainder[CLOCK_PHASE_WIDTH-1:0] : clock_sum[CLOCK_PHASE_WIDTH-1:0];
end

rate_enable #(.CLK_HZ(CLK_HZ), .RATE_HZ(32768)) crystal (
    .clk(clk), .nreset(nreset), .ce(ce), .tick(crystal_tick)
);

wire [15:0] cpu_addr_full;
wire cpu_read;
wire [7:0] cpu_wdata;
reg [7:0] cpu_rdata;
wire timer_irq_n = !((timer_ctrl[7] && timer_ctrl[5]) || (timer_ctrl[6] && timer_ctrl[4]));
wire cpi_irq_n = !(cpi_ctrl[6] && cpi_ctrl[4]);
assign cpu_addr = cpu_addr_full[12:0];
m68hc05_core cpu (
    .clk(clk), .cen(cpu_tick), .rst(nreset), .irq(irq_n),
    .timer_irq(timer_irq_n), .onesec_irq(cpi_irq_n),
    .addr(cpu_addr_full), .wr(cpu_read), .datain(cpu_rdata),
    .dataout(cpu_wdata), .state(cpu_state), .stopped(stopped), .waiting(waiting)
);

(* ramstyle = "M10K" *) reg [7:0] rom [0:4351];
reg [7:0] rom_data;
initial $readmemh(ROM_FILE, rom);
always @(posedge clk) begin
    if (cpu_addr >= 13'h0F00) rom_data <= rom[cpu_addr - 13'h0F00];
end
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] ram [0:367];
wire ram_sel = cpu_addr >= 13'h0090 && cpu_addr < 13'h0200;
wire [8:0] ram_addr = cpu_addr[8:0] - 9'h090;
// 341S0788: PRAM $100-$1ff, big-endian seconds $ab-$ae.
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] pram_lo [0:127];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] pram_hi [0:127];
integer image_index;
initial begin
    for (image_index = 0; image_index < 128; image_index = image_index + 1) begin
        pram_lo[image_index] = 0;
        pram_hi[image_index] = 0;
    end
end
reg storage_initialized = 0;
reg time_initialized = 0;
reg [1:0] seed_addr;
reg [31:0] seed_seconds;
// hps_io fills TIMESTAMP[31:0] one 16-bit word at a time, low word first, and
// toggles TIMESTAMP[32] only once the whole command has been received.  A
// seed taken while [31:0] first turns nonzero would catch a half-written
// value (the high word still 0, so a date in 1970), so wait for the toggle.
reg timestamp_msb_d = 0;
reg timestamp_complete = 0;
always @(posedge clk) begin
    timestamp_msb_d <= timestamp[32];
    if (timestamp[32] != timestamp_msb_d) timestamp_complete <= 1;
end
wire startup_release = cpu_tick && !cpu_read && cpu_addr == 13'h0002 &&
    cpu_wdata[3] && !pc_latch[3];
wire live_pram = HOST_STORAGE && storage_initialized &&
    cpu_addr >= 13'h0100 && cpu_addr < 13'h0200;
wire guest_pram_write = live_pram && cpu_tick && !cpu_read;
assign storage_ready = !HOST_STORAGE || (storage_initialized && time_initialized);
assign pram_h_rdata = {pram_hi[pram_h_addr], pram_lo[pram_h_addr]};
assign pram_wr_stb = guest_pram_write;
always @(posedge clk) begin
    if (!nreset) begin
        restore_active <= 0;
        storage_initialized <= 0;
        time_initialized <= 0;
    end else begin
        // Firmware startup clears volatile PRAM; expose the image after it finishes.
        if (HOST_STORAGE && !storage_initialized && startup_release)
            storage_initialized <= 1;
        if (HOST_STORAGE && storage_initialized && !time_initialized &&
            !restore_active && timestamp_complete && timestamp[31:0] != 0) begin
            seed_seconds <= timestamp[31:0] + 32'd2082844800;
            seed_addr <= 0;
            restore_active <= 1;
        end
        if (restore_active) begin
            ram[9'h01b + {7'd0, seed_addr}] <= seed_seconds[31:24];
            seed_seconds <= {seed_seconds[23:0], 8'd0};
            seed_addr <= seed_addr + 1'b1;
            if (seed_addr == 3) begin
                restore_active <= 0;
                time_initialized <= 1;
            end
        end else if (cpu_tick && !cpu_read && ram_sel && !live_pram)
            ram[ram_addr] <= cpu_wdata;
    end
    if (HOST_STORAGE && pram_h_we) begin
        pram_lo[pram_h_addr] <= pram_h_wdata[7:0];
        pram_hi[pram_h_addr] <= pram_h_wdata[15:8];
    end else if (guest_pram_write) begin
        if (cpu_addr[0]) pram_hi[cpu_addr[7:1]] <= cpu_wdata;
        else pram_lo[cpu_addr[7:1]] <= cpu_wdata;
    end
end

assign pa_out = (pa_latch & pa_ddr) | (pa_in & ~pa_ddr);
assign pb_out = (pb_latch & pb_ddr) | (pb_in & ~pb_ddr);
assign pc_out = (pc_latch & pc_ddr) | (pc_in & ~pc_ddr);
always @* begin
    cpu_rdata = 0;
    if (live_pram) cpu_rdata = cpu_addr[0] ? pram_hi[cpu_addr[7:1]] : pram_lo[cpu_addr[7:1]];
    else if (ram_sel) cpu_rdata = ram[ram_addr];
    else if (cpu_addr >= 13'h0F00) cpu_rdata = rom_data;
    else begin
        case (cpu_addr)
            13'h0000: cpu_rdata = pa_out;
            13'h0001: cpu_rdata = pb_out;
            13'h0002: cpu_rdata = {4'd0, pc_out};
            13'h0004: cpu_rdata = pa_ddr;
            13'h0005: cpu_rdata = pb_ddr;
            13'h0006: cpu_rdata = {4'd0, pc_ddr};
            13'h0007: cpu_rdata = pll_ctrl;
            13'h0008: cpu_rdata = timer_ctrl;
            13'h0009: cpu_rdata = timer_count[9:2];
            13'h0012: cpu_rdata = cpi_ctrl;
            default: ;
        endcase
    end
end

wire [16:0] rti_mask = (17'h04000 << timer_ctrl[1:0]) - 1'b1;
always @(posedge clk) begin
    if (!nreset) begin
        pa_latch <= 0; pb_latch <= 0; pc_latch <= 0;
        pa_ddr <= 0; pb_ddr <= 0; pc_ddr <= 0;
        pll_ctrl <= 8'h2D;
        timer_ctrl <= 8'h03;
        cpi_ctrl <= 0;
        timer_count <= 0;
        cpi_count <= 0;
    end else begin
        if (stopped) begin
            timer_count <= 0;
            timer_ctrl[7:6] <= 0;
        end else if (cpu_tick) begin
            timer_count <= timer_count + 1'b1;
            if (timer_count[9:0] == 10'h3FF) timer_ctrl[7] <= 1;
            if ((timer_count & rti_mask) == rti_mask) timer_ctrl[6] <= 1;
        end
        if (!cpi_ctrl[4]) cpi_count <= 0;
        else if (!stopped && crystal_tick) begin
            cpi_count <= cpi_count + 1'b1;
            if (cpi_count == 15'h7FFF) cpi_ctrl[6] <= 1;
        end
        if (cpu_tick && !cpu_read) begin
            case (cpu_addr)
                13'h0000: pa_latch <= cpu_wdata;
                13'h0001: pb_latch <= cpu_wdata;
                13'h0002: pc_latch <= cpu_wdata[3:0];
                // CUDA PFW on PA0 remains an input regardless of DDRA writes.
                13'h0004: pa_ddr <= cpu_wdata & 8'hFE;
                13'h0005: pb_ddr <= cpu_wdata;
                13'h0006: pc_ddr <= cpu_wdata[3:0];
                13'h0007: pll_ctrl <= cpu_wdata & 8'h7F;
                13'h0008: timer_ctrl <= {timer_ctrl[7:6] & cpu_wdata[7:6], cpu_wdata[5:4], 2'd0, cpu_wdata[1:0]};
                13'h0012: cpi_ctrl <= {1'b0, cpi_ctrl[6] & cpu_wdata[6], 1'b0, cpu_wdata[4], 4'd0};
                default: ;
            endcase
        end
    end
end

endmodule
