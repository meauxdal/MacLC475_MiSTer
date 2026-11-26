// MC68040 pins to the machine's right-aligned transaction bus, one clock.
module bus040 #(
    parameter STALL_BITS = 24
) (
    input clk, nreset, stall_hold,
    input [31:0] c_a, c_do,
    input c_a_oe, c_rw_n, c_ts_n,
    input [1:0] c_siz, c_tt,
    input [2:0] c_tm,
    output [31:0] c_di,
    output c_ta_n, c_tea_n, c_tci_n, c_avec_n,
    output bus_req, bus_write, bus_instr,
    output [1:0] bus_size,
    output [31:0] bus_addr, bus_wdata,
    output [2:0] bus_fc,
    input bus_ack,
    input [31:0] bus_rdata,
    input berr,
    output dbg_stall_flt, busy,
    output line_more            // a line transfer with beats after this one
);

wire ts = c_a_oe && !c_ts_n;
wire is_ack = (c_tt == 2'b11);
wire is_line = (c_siz == 2'b11);
reg xfer, iack;
reg [1:0] beat;
wire req = (ts && !is_ack) || xfer;
wire last = !is_line || (beat == 2'd3);
wire stall_flt;

always @(posedge clk) begin
    if (!nreset) begin
        xfer <= 0;
        beat <= 0;
        iack <= 0;
    end
    else begin
        iack <= ts && is_ack;
        if (req && (berr || stall_flt)) begin
            xfer <= 0;
            beat <= 0;
        end
        else if (req && bus_ack) begin
            xfer <= !last;
            beat <= last ? 2'd0 : beat + 2'd1;
        end
        else if (ts && !is_ack)
            xfer <= 1;
    end
end

assign bus_req = req;
assign line_more = is_line && (beat != 2'd3);
assign bus_write = !c_rw_n;
assign bus_instr = (c_tm == 3'd2) || (c_tm == 3'd6);
assign bus_fc = c_tm;
assign bus_size = (c_siz == 2'b01) ? 2'd0 :
                  (c_siz == 2'b10) ? 2'd1 : 2'd2;
assign bus_addr = is_line ? {c_a[31:4], c_a[3:2] + beat, 2'b00} : c_a;
assign bus_wdata = (c_siz == 2'b01) ? (c_do >> {~c_a[1:0], 3'd0}) :
                   (c_siz == 2'b10) ? (c_a[1] ? {16'd0, c_do[15:0]} :
                                               {16'd0, c_do[31:16]}) : c_do;
assign c_di = (c_siz == 2'b01) ? {4{bus_rdata[7:0]}} :
              (c_siz == 2'b10) ? {2{bus_rdata[15:0]}} : bus_rdata;

// Only RAM and ROM are cacheable. All device transfers are inhibited.
assign c_tci_n = (c_a[31:30] == 2'b00) || (c_a[31:28] == 4'h4);
assign c_ta_n = !((req && bus_ack && !berr && !stall_flt) || iack);
assign c_tea_n = !((req && berr) || stall_flt);
assign c_avec_n = !iack;

reg [STALL_BITS-1:0] stall_cnt;
reg stall_r;
always @(posedge clk) begin
    stall_r <= 0;
    if (!nreset || !req || bus_ack || berr || stall_hold)
        stall_cnt <= 0;
    else if (&stall_cnt)
        stall_r <= 1;
    else
        stall_cnt <= stall_cnt + 1'd1;
end
assign stall_flt = stall_r;
assign dbg_stall_flt = stall_r;
assign busy = xfer;

endmodule
