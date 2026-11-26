//============================================================================
//  MacLC475 - Macintosh LC 475 / Quadra 605.
//  TODO: Qualify MEMCjr/PrimeTime timing and the optional SWIM II path.
//  Platform memory contract (see rtl/lc475.sv):
//  one ack-based beat port with mem_memsel (0 RAM, 1 ROM, 2 VRAM) plus a
//  registered 1-cycle video scanout port.  Here:
//   - RAM (4-36 MB) lives in SDRAM; ROM (1 MB) lives in DDR3.
//     ROM writes are acknowledged and discarded.
//   - VRAM is 1 MB in DDR3 (rtl/vram_ddr3.sv, from the lean Q800 DDR3
//     branch): CPU beats through its read cache and write queue, the DAFB
//     scanout from a ping-pong scanline cache filled by line DMA.
//     VERILOG_MACRO "VRAM_BRAM=1" restores the old on-chip VRAM (320 KB
//     physical, advertised as 512 KB, row-pitch compaction).
//   - ROM reads go through a 128 KB on-chip cache in front of DDR3
//     (rtl/rom_cache_128k.sv); "ROM_CACHE_OFF=1" removes it.
//   - The ROM uploads as boot0.rom (ioctl index 0) into the DDR3 ROM
//     region; the machine is held in reset until it lands.
//   - The SCSI disk is hps_io block device 0 (mount a .hda in the OSD);
//     the 53C96 speaks the 16-bit sd_buff interface natively.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// User-port MIDI and optional MT32-pi are wired below with the SCC UART.

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;                        // ASC samples are signed
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar;
// VIDEO_ARX/ARY and VGA_DE come from the framework's video_freak below
// (aspect ratio plus the OSD's integer-scaling choice, status[13:12]).

`include "build_id.v"
localparam CONF_STR = {
	// UART modes for PPP, MidiLink and the SCC's MIDI clock path.
	"MacLC475;UART57600:115200,MIDI;",
	"-;",
	// SC remembers mounts; S leaves the floppy unmounted at the next start.
	// CUE/BIN/CHD require Main's Mac CD layer.
	"SC0,HDAVHD,Pri. disk (ID 0);",
	"SC1,HDAVHD,Disk (ID 1);",
	"SC4,ISOTO*CUEBINCHD,CD-ROM (ID 3);",
`ifdef SWIM2
	"S6,DSKIMGIMA,Floppy disk;",
	"O[18],Floppy Write Protect,Off,On;",
`endif
	"F0,ROM,Load ROM;",
	"-;",
	"O[52:49],Memory,4MB,5MB,6MB,8MB,12MB,20MB,36MB,68MB,100MB;",
`ifndef ETHERNET_OFF
	"O[8:7],Network interface,eth0,eth1,wlan0,tap0;",
`endif
	"-;",
`ifndef ETHERNET_OFF
	"P1,Machine;",
`endif
	"P2,Video;",
`ifndef MT32PI_OFF
	"P4,Audio;",
`endif
	"P5,Advanced;",
`ifdef MACLC475_DEBUG
	"P9,Debug;",
`endif
	"-;",
	"h1-,Changes pending;",
	"R[0],Apply and reset;",

`ifndef ETHERNET_OFF
	"P1O[6],Ethernet,Off,On;",
`endif

`ifndef VIDEO_512_OFF
	"P2O[5],Monitor,13-inch 640x480,12-inch 512x384;",
`endif
	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[13:12],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",

`ifndef MT32PI_OFF
	"P4O[35],Use MT32-pi,Yes,No;",
	"P4O[36],Synth,Munt,FluidSynth;",
	"P4O[38:37],Munt ROM,MT-32 v1,MT-32 v2,CM-32L;",
	"P4O[41:39],SoundFont,0,1,2,3,4,5,6,7;",
	"P4O[43:42],Show Info,No,Yes,LCD-On,LCD-Auto;",
`endif

	"P5SC2,NVR,PRAM image;",
	"P5-;",
	"P5O[17],Swap Alt/Win keys,No,Yes;",
`ifdef SWIM2
	"D0P5T[16],Retry floppy I/O;",
`endif
`ifdef MACLC475_DEBUG
	"P9O[14],Video diagnostics,Off,On;",
	"P9O[15],ADB diagnostics,Off,On;",
	"P9-;",
	"P9O[46:44],Perf counters,Off,Page 0,Page 1,Page 2,Page 3,Page 4,Page 5,Page 6;",
	"P9O[47],Perf counting,Run,Freeze;",
	"P9T[48],Clear perf counters;",
`endif

`ifndef MT32PI_OFF
	// "Show Info = Yes" popup strings, indexed 1-based by mt32_info_disp
	"I,",
	"MT32-pi: SoundFont #0,",
	"MT32-pi: SoundFont #1,",
	"MT32-pi: SoundFont #2,",
	"MT32-pi: SoundFont #3,",
	"MT32-pi: SoundFont #4,",
	"MT32-pi: SoundFont #5,",
	"MT32-pi: SoundFont #6,",
	"MT32-pi: SoundFont #7,",
	"MT32-pi: MT-32 v1,",
	"MT32-pi: MT-32 v2,",
	"MT32-pi: CM-32L,",
	"MT32-pi: Unknown mode,",
`else
	"I,",
`endif
	"Video: nonblack RGB - HDMI path suspect,",
	"Video: pixel clock stopped,",
	"Video: pixel PLL unlocked,",
	"Video: clock settling held,",
	"Video: scanout held in reset,",
	"Video: no active-video pulses,",
	"Video: active - machine held in reset,",
	"Video: active - CPU halted,",
	"Video: core RGB is black;",
	"v,0;",
	"J,Trigger,Thumb,Button 3,Button 4,Button 5,Base 1,Base 2,Base 3;",
	"jn,A,B,X,Y,L,R,Select,Start;",
	"jp,B,A,Y,X,L,R,Select,Start;",
	"V,v",`BUILD_DATE
};

wire  [1:0] buttons;
wire [127:0] status;
wire settings_pending;
`ifdef MACLC475_DEBUG
wire video_diagnostic = status[14] | status[15];
wire adb_diagnostic = status[15];
// Perf counters (rtl/perf_counters.sv): a page replaces the overlay rows.
wire perf_show = status[46:44] != 3'd0;
wire [2:0] perf_page = status[46:44] - 3'd1;
wire perf_freeze = status[47];
wire perf_clear = status[48];
`else
wire video_diagnostic = 1'b0;
wire adb_diagnostic = 1'b0;
wire perf_show = 1'b0;
wire [2:0] perf_page = 3'd0;
wire perf_freeze = 1'b1;
wire perf_clear = 1'b0;
`endif
wire video_diagnostic_v;
wire [1:0] scale_v, mt32_info_v;
`ifdef MT32PI_OFF
localparam [7:0] VIDEO_INFO_BASE = 8'd1;
wire [1:0] mt32_info_control = 2'd0;
`else
localparam [7:0] VIDEO_INFO_BASE = 8'd13;
wire [1:0] mt32_info_control = status[43:42];
`endif
video_control video_control (
	.clk_sys(clk_sys), .clk_vid(clk_vid),
	.control({status[122:121], status[13:12], mt32_info_control, video_diagnostic}),
	.control_v({ar, scale_v, mt32_info_v, video_diagnostic_v})
);
wire [10:0] ps2_key;
// "Swap Alt/Win keys": Alt gives Option and the Windows keys Command
// (Mac labelling) instead of the positional PlusToo default.
wire [8:0]  key_sc = ps2_key[8:0];
wire [10:0] ps2_key_m = {ps2_key[10:9], !status[17] ? key_sc :
                         key_sc == 9'h011 ? 9'h11F : key_sc == 9'h111 ? 9'h127 :
                         key_sc == 9'h11F ? 9'h011 : key_sc == 9'h127 ? 9'h111 : key_sc};
wire [24:0] ps2_mouse;
wire [31:0] joystick_0;                    // [3:0] R L D U, [11:4] the J buttons
wire [15:0] joystick_l_analog_0;           // {Y, X}, signed, up and left negative
wire [15:0] joystick_r_analog_0;           // Y [15:8] is the Firebird throttle

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
reg         ioctl_wait;

// hps_io virtual drives.  The slot numbers follow the Main fork's Mac SCSI
// family layout (support/mac/mac.cpp) so its Toolbox / CD handlers apply:
//   0 SCSI disk 0   1 SCSI disk 1   2 PRAM image (.nvr, as in MacLC)
//   3 BlueSCSI Toolbox control   4 CD-ROM image   5 CD changer control
`ifdef SWIM2
localparam VDNUM      = 7;
localparam VD_FLOPPY = 6;
wire [35:0] floppy_ext_bus;
wire [15:0] sdram_sz;
wire floppy_fault;
wire floppy_sel, floppy_write;
wire [2:0] floppy_addr;
wire [7:0] floppy_wdata, floppy_rdata;
`else
localparam VDNUM      = 6;
`endif
localparam VD_DISK0   = 0, VD_DISK1 = 1, VD_PRAM = 2, VD_TOOLBOX = 3, VD_CDROM = 4, VD_CDTB = 5;
wire [31:0] sd_lba[VDNUM];
wire  [VDNUM-1:0] sd_rd, sd_wr;
wire  [VDNUM-1:0] sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[VDNUM];
wire        sd_buff_wr;
wire [32:0] TIMESTAMP;                     // Unix seconds from the HPS, for the RTC
wire  [VDNUM-1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

// ncr53c96's three targets map onto slots 0, 1 and 4
wire [31:0] scsi_lba;
wire  [2:0] scsi_rd, scsi_wr;
wire [15:0] scsi_buff_din;
wire  [5:0] scsi_blk_cnt;               // blocks - 1 of the machine's current transaction (one at a time)
assign sd_lba[VD_DISK0] = scsi_lba;  assign sd_lba[VD_DISK1] = scsi_lba;  assign sd_lba[VD_CDROM] = scsi_lba;
// Per-slot assigns, not a concatenation: a packed literal put the CD strobe
// at bit 5 (the CD-changer control slot) once, so every CD read -- the TOC
// fetch on mount, the ROM's block 0 -- was answered on slot 5 while the core
// waited on slot 4, and the machine hung with io_busy stuck (2026-09-03).
assign sd_rd[VD_DISK0]   = scsi_rd[0];
assign sd_rd[VD_DISK1]   = scsi_rd[1];
assign sd_rd[VD_CDROM]   = scsi_rd[2];
assign sd_rd[VD_PRAM]    = pram_rd;
assign sd_rd[VD_TOOLBOX] = 1'b0;
assign sd_rd[VD_CDTB]    = 1'b0;
assign sd_wr[VD_DISK0]   = scsi_wr[0];
assign sd_wr[VD_DISK1]   = scsi_wr[1];
assign sd_wr[VD_PRAM]    = pram_wr;
assign sd_wr[VD_TOOLBOX] = 1'b0;
assign sd_wr[VD_CDROM]   = scsi_wr[2];                            // only the command block (LBA $7D......) is ever written
assign sd_wr[VD_CDTB]    = 1'b0;
assign sd_buff_din[VD_DISK0] = scsi_buff_din;
assign sd_buff_din[VD_DISK1] = scsi_buff_din;
assign sd_buff_din[VD_CDROM] = scsi_buff_din;
// the PRAM image: words 0..127 are the 256 bytes, the rest of the sector pads with zeros
assign sd_lba[VD_PRAM] = 32'd0;
assign sd_buff_din[VD_PRAM] = (sd_buff_addr[12:7] == 6'd0) ? pram_h_rdata : 16'h0000;
assign sd_lba[VD_TOOLBOX] = 0; assign sd_lba[VD_CDTB] = 0;
assign sd_buff_din[VD_TOOLBOX] = 0; assign sd_buff_din[VD_CDTB] = 0;
wire  [2:0] scsi_ack = {sd_ack[VD_CDROM], sd_ack[VD_DISK1], sd_ack[VD_DISK0]};

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(VDNUM), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
`ifdef SWIM2
	.EXT_BUS(floppy_ext_bus),
	.sdram_sz(sdram_sz),
	.status_menumask({14'd0, settings_pending, !floppy_fault}),
`else
	.EXT_BUS(),
	.status_menumask({14'd0, settings_pending, 1'b0}),
`endif
	.gamma_bus(),

	.buttons(buttons),
	.status(status),

`ifdef MT32PI_OFF
	.info_req(video_probe_request),
	.info(VIDEO_INFO_BASE + {4'd0, video_probe_result}),
`else
	// MT32-pi "Show Info = Yes" OSD popup (CONF_STR "I," strings, 1-based)
	.info_req(video_probe_request | mt32_info_req),
	.info(video_probe_request ? (VIDEO_INFO_BASE + {4'd0, video_probe_result}) : {4'd0, mt32_info_disp}),
`endif

	// OSD "UART mode" as the Main reports it: 0=None, 1=PPP (the Main maps
	// its modem modes to 1 before sending), 2=Console, 3=MIDI.  Gates the
	// user-port MIDI-in merge at the serialIn assign above.
	.uart_mode(uart_mode),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.joystick_0(joystick_0),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_r_analog_0(joystick_r_analog_0),

	.TIMESTAMP(TIMESTAMP),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.sd_lba(sd_lba),
`ifdef SWIM2
	.sd_blk_cnt('{scsi_blk_cnt, scsi_blk_cnt, 6'd0, 6'd0, scsi_blk_cnt, 6'd0, 6'd0}),
`else
	.sd_blk_cnt('{scsi_blk_cnt, scsi_blk_cnt, 6'd0, 6'd0, scsi_blk_cnt, 6'd0}),
`endif
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size)
);

///////////////////////   CLOCKS   ///////////////////////////////

localparam integer SYS_CLK_HZ = 25_000_000;
localparam integer RAM_CLK_HZ = 75_000_000;

wire clk_sys;
wire clk_ram;                              // 75 MHz = 3x clk_sys, SDRAM domain
wire pll_locked;

// Dedicated dot clock for the DAFB scanout.  The video used to run on clk_sys,
// which made 640x480 in an 800x525 frame refresh at 78.6 Hz with a 33 MHz dot
// clock -- far enough off spec that Main_MiSTer's vsync_adjust synthesised a
// broken HDMI mode from it (the reported screen showing the frame four times
// across the width).  25.175 MHz gives exactly VGA 640x480 @ 59.94 Hz, which
// is what the Mac LC core does; see rtl/pll_video.v.
//
// The 12" RGB monitor wants 15.664 MHz for its 640x407 frame.  That is a
// runtime RECONFIG of the one output counter (sys/pll_cfg, the ao486 /
// MacLC pattern): CLK_VIDEO has to be a raw PLL output, so a clock mux is
// not an option (Fitter Error 15836).  Only C0 changes, the VCO stays put.
// The static config is the 13" divider, so a 13" boot performs no reconfig
// at all -- MacLC's boot-time retarget glitched CLK_VIDEO while the HPS was
// mounting images and wedged the SCSI path.
wire clk_vid, pll_video_locked;
wire [63:0] reconfig_to_pll, reconfig_from_pll;
pll_video pllv
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_vid),
	.locked(pll_video_locked),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

`ifdef VIDEO_512_OFF
// VIDEO_512_OFF=1 (qsf): no runtime PLL reconfiguration -- the 13" 640x480
// divider is the static config and stays.  Saves the pll_cfg block (~360
// ALMs), the area lever for CPU builds that keep the CD-ROM target.
assign reconfig_to_pll = 64'd0;
wire   pix_quiet = 1'b0;
wire   mon_12in  = 1'b0;
`else
wire        pixcfg_waitrequest;
reg         pixcfg_write = 0;
reg   [5:0] pixcfg_address = 0;
reg  [31:0] pixcfg_data = 0;
// The framework's trimmed reconfiguration core (sys/pll_cfg/pll_cfg_hdmi.v,
// Altera's altera_pll_reconfig_core with the unused features cut out) has
// the same management interface and the MODE / C-counter / START registers
// this path writes, at ~300 logic cells instead of the generic IP's 715.
pll_cfg_hdmi pll_video_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(pixcfg_waitrequest),
	.mgmt_write(pixcfg_write),
	.mgmt_address(pixcfg_address),
	.mgmt_writedata(pixcfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// C0 counter word per monitor: {[22:18] counter#=0, [17] odd-div, [16]
// bypass, [15:8] high count, [7:0] low count} (sys/pll_cfg/
// altera_pll_reconfig_core.v).  VCO 704.9 MHz: /28 = 25.175 MHz, /45 =
// 15.664 MHz.
// The monitor is latched under reset like the RAM size (ram_cfg below):
// the ROM reads the DAFB sense lines once at boot.
reg mon_12in = 1'b0;
always @(posedge clk_sys) if (reset) mon_12in <= status[5];
wire [31:0] pix_c0 = mon_12in ? 32'h00021716 : 32'h00000E0E;

// The retarget never drops PLL lock (the VCO is untouched), so the scanout
// would step to the new rate mid-frame and Main's vsync_adjust would
// measure one chimera frame and latch an out-of-spec HDMI mode (MacLC,
// 2026-08-08).  pix_quiet holds the video reset from retarget-pending
// until ~84 ms after the FSM has consumed it, so a monitor change presents
// as a clean blank-and-return.
reg pix_quiet = 1'b0;
always @(posedge CLK_50M) begin : pix_reconfig
	reg [21:0] settle = 22'd0;
	reg [31:0] c0_cur = 32'h00000E0E;    // = the static 13" config
	reg [31:0] c0_s1, c0_s2;
	reg [2:0]  state = 0;
	c0_s1 <= pix_c0;                     // settle across clk_sys -> CLK_50M
	c0_s2 <= c0_s1;
	if (c0_s2 == c0_s1 && c0_s2 != c0_cur) begin
		settle    <= 22'h3FFFFF;
		pix_quiet <= 1'b1;
	end else if (settle != 0) begin
		settle    <= settle - 1'd1;
	end else begin
		pix_quiet <= 1'b0;
	end
	if (!pixcfg_waitrequest) begin
		pixcfg_write <= 0;
		if (pll_video_locked) begin
			if (state) state <= state + 1'd1;
			case (state)
				0: if (c0_s2 == c0_s1 && c0_s2 != c0_cur) begin
						c0_cur <= c0_s2;
						state  <= 1;
					end
				1: begin pixcfg_address <= 0; pixcfg_data <= 0;      pixcfg_write <= 1; end // polled mode
				3: begin pixcfg_address <= 5; pixcfg_data <= c0_cur; pixcfg_write <= 1; end // C0 counter
				5: begin pixcfg_address <= 2; pixcfg_data <= 0;      pixcfg_write <= 1; end // start
				default: ;
			endcase
		end
	end
end
`endif

// video-domain reset: released only once the pixel clock is locked AND the
// machine is out of reset (or diagnostics enabled) AND no retarget is settling, 2FF-synced into
// clk_vid (pix_quiet is a multi-ms CLK_50M level; the 2FF is its sync)
reg vidrst_meta, vidrst_s;
always @(posedge clk_vid) begin
	vidrst_meta <= (reset && !video_diagnostic) | ~pll_video_locked | pix_quiet;
	vidrst_s    <= vidrst_meta;
end
wire nreset_vid = ~vidrst_s;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_1(clk_ram),
	.outclk_0(clk_sys),                    // 25 MHz machine clock
	.locked(pll_locked)
);

// hold the machine until the PLL locks and boot0.rom has landed in DDR3
wire rom_index = (ioctl_index[5:0] == 0);
reg  rom_loaded = 0;
reg  dl_d = 0;
always @(posedge clk_sys) begin
	dl_d <= ioctl_download;
	if (dl_d && !ioctl_download && rom_index) rom_loaded <= 1;
end

// ... and, at core start, until the PRAM image has been loaded (below)
wire host_reset = RESET | status[0] | buttons[1] | ioctl_download |
                  ~rom_loaded | ~pll_locked | pram_force_reset;
wire cuda_reset_n, cuda_storage_ready;
wire reset = host_reset | ~pram_ready | ~cuda_storage_ready | ~cuda_reset_n;

//////////////////////////////////////////////////////////////////
// PRAM persistence: the 512-byte .nvr image on hps_io slot 2 (MacLC's
// scheme, without the Egret's staging copy: CUDA PRAM is the only
// copy and the host port writes and reads it in place).
//   load  : when the image mounts (img_mounted[2], size != 0) -- one
//           sd_rd of LBA 0, the 128 words landing straight in the CUDA PRAM
//   flush : when the OSD opens, or ~2 s after the guest's last PRAM
//           write, if the guest has written PRAM since the last save
//           (the settle timer restarts on every write, so the ROM's and
//           System's bursts coalesce into one sector save)
// The machine is held in reset until the FIRST load has landed, the slot
// reports no image, or a ~3 s backstop expires, so a missing or slow
// image never hangs the boot.  A load that lands after that (a slow HPS,
// or a manual re-mount from the OSD) writes the CUDA PRAM under the running
// ROM and then pulses a machine reset, so the machine comes up on the
// loaded PRAM.  The request handshake is the SCSI one: drop rd/wr when
// sd_ack rises, the sector is done when it falls.  The read is watchdogged
// (the HPS is busiest at core start, with the ROM download and every slot
// mounting) and re-issued up to three times before the boot goes ahead
// on defaults.
//////////////////////////////////////////////////////////////////
wire pram_rd, pram_wr, pram_h_we, pram_wr_stb, pram_ready, pram_force_reset;
wire [6:0] pram_h_addr;
wire [15:0] pram_h_rdata;
cuda_pram_host #(.SYS_CLK_HZ(SYS_CLK_HZ)) pram_host (
	.clk(clk_sys), .power_reset_n(pll_locked),
	.img_mounted(img_mounted[VD_PRAM]), .img_size(img_size), .OSD_STATUS(OSD_STATUS),
	.pram_ack(sd_ack[VD_PRAM]), .sd_buff_addr(sd_buff_addr), .sd_buff_wr(sd_buff_wr),
	.pram_wr_stb(pram_wr_stb), .pram_rd(pram_rd), .pram_wr(pram_wr),
	.pram_h_we(pram_h_we), .pram_h_addr(pram_h_addr),
	.pram_ready(pram_ready), .pram_force_reset(pram_force_reset)
);

// Re-announce the mounted image to the machine after EVERY reset.
//
// ncr53c96 latches `mounted`/`disk_blocks` only on the img_mounted pulse, and
// its always block is reset-gated, so a machine reset throws the mount away.
// The Main sends that pulse exactly twice in a core's life -- once at core
// start (SC0 restoring the saved mount) and again if you pick a file in the
// OSD -- so after any reset the target believed no disk was present and the ROM
// dropped to the flashing-? screen. That is why the disk had to be re-assigned
// by hand after every reboot.
//
// Two distinct problems are handled here:
//   1. The core-start mount lands INSIDE the reset window, because `reset`
//      spans the whole boot0.rom ioctl upload -- so the pulse would be dropped
//      even on the first boot. Symptom: the Main holds the file open (fd
//      present, pos stuck at 0) while the machine shows flashing-?.
//   2. Every LATER reset clears the target's copy with no new pulse coming.
//
// So the mount is remembered here, outside the machine reset, and replayed on
// each reset release as well as when it first arrives. Size is captured a cycle
// ahead of the pulse so it is stable when the target samples it.
// Three targets, one memory each.  A Main pulse for slot 0/1/4 records the
// size and schedules a replay; a reset release schedules a replay of every
// remembered slot.  Replays go out one target per clock pair so the machine
// sees a single pulse with its own size each time.
reg  [2:0] mount_valid  = 0;      // an image is mounted (survives machine reset)
reg [63:0] mount_size [0:2];
reg  [2:0] mount_replay = 0;
reg        reset_d      = 1;
reg  [2:0] mach_img_mounted = 0;
reg [63:0] mach_img_size = 0;
wire [2:0] main_mount = {img_mounted[VD_CDROM], img_mounted[VD_DISK1], img_mounted[VD_DISK0]};
integer mi;
always @(posedge clk_sys) begin
	mach_img_mounted <= 0;
	reset_d          <= reset;

	for (mi = 0; mi < 3; mi = mi + 1)
		if (main_mount[mi]) begin
			mount_size[mi]   <= img_size;
			mount_valid[mi]  <= (img_size != 0);   // size 0 = eject, replay that too
			mount_replay[mi] <= 1;
		end
	if (reset_d && !reset) mount_replay <= mount_replay | mount_valid;   // reset just released

	if (!reset && mach_img_mounted == 3'b000) begin
		if (mount_replay[0]) begin
			mount_replay[0] <= 0; mach_img_size <= mount_size[0]; mach_img_mounted <= 3'b001;
		end
		else if (mount_replay[1]) begin
			mount_replay[1] <= 0; mach_img_size <= mount_size[1]; mach_img_mounted <= 3'b010;
		end
		else if (mount_replay[2]) begin
			mount_replay[2] <= 0; mach_img_size <= mount_size[2]; mach_img_mounted <= 3'b100;
		end
	end
end

///////////////////////   MACHINE   //////////////////////////////

wire        mem_req, mem_write;
wire [31:2] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata;
wire  [1:0] mem_memsel;
wire [31:0] mem_rdata;                     // VRAM/ROM reg, or the SDRAM bridge
wire        mem_ack;
wire        mem_vram_wp;                   // direct VRAM write (mem_req low)
reg  [31:0] mem_rdata_r;
reg         mem_ack_r;

wire        mem_is_ram  = (mem_memsel == 2'd0);
wire        mem_is_rom  = (mem_memsel == 2'd1);
wire        mem_is_vram = !mem_is_ram && !mem_is_rom;

wire [21:2] vid_addr;
`ifdef VRAM_BRAM
reg  [31:0] vid_rdata;
`else
wire [31:0] vid_rdata;
`endif
wire [13:0] vid_stride;
wire  [9:0] vid_col_word;                  // DDR3 VRAM scanline handshake
wire        vid_line_req;
wire [20:0] vid_line_addr;
wire        vid_line_swap;
wire        vram_wq_room;
wire [11:0] vram_perf_ev;                  // rtl/perf_counters.sv pages 5-6
wire  [5:0] perf_rd_idx;                   // DDR3 perf snapshot (perf_ddr_*)
wire [31:0] perf_rd_data;
wire [31:2] vram_fast_addr;                // vram_ddr3's fast read-hit port
wire        vram_fast_take;
wire        vram_fast_hit;
wire [31:0] vram_fast_data;

wire [255:0] m_debug_status;
wire [127:0] m_debug_status2;

localparam RAM_ADDR_BITS = 27;             // address ceiling: 128 MB

// Stock soldered RAM plus SIMM geometry, applied at reset.  68 MB (value 7)
// and 100 MB (value 8) put a 64 MB rank at SDRAM 64-128 MB, so they need a
// 128 MB module; smaller modules fall back to 36 MB.  Values past 8 also
// fall back to 36 MB.
wire sdram_128 = sdram_sz[15] && sdram_sz[1:0] == 2'd3;
wire [3:0] ram_cfg_osd = (status[52:49] > 4'd8 ||
                          (status[52:49] >= 4'd7 && !sdram_128)) ?
                         4'd6 : status[52:49];

// A menu change takes effect at the next reset.
reg [3:0] ram_cfg = 4'd0;
always @(posedge clk_sys) if (reset) ram_cfg <= ram_cfg_osd;

wire        sdr_line_valid;
wire        sdr_wq_room;
wire        mem_wp_valid;
wire [31:2] mem_wp_addr;
wire  [3:0] mem_wp_be;
wire [31:0] mem_wp_data;
wire [26:4] sdr_line_tag;
wire [127:0] sdr_line_data;
wire        sdr_line_pending;
wire [26:4] sdr_line_pending_tag;

// CDROM_OFF removes the CD-ROM target and audio engine.
`ifdef CDROM_OFF
localparam CDROM_EN = 0;
`else
localparam CDROM_EN = 1;
`endif

// Built-in Ethernet.  The build switch is
//   set_global_assignment -name VERILOG_MACRO "ETHERNET_OFF=1"
// (no SONIC front-end, no DMA master, no DDR3 window port, no OSD lines); the
// runtime switch is OSD [6], latched under reset like the RAM size because the
// guest must never see the chip appear or vanish under it.
`ifdef ETHERNET_OFF
localparam SONIC_EN = 0;
`else
localparam SONIC_EN = 1;
`endif
reg         eth_ena = 1'b0;
// The machine's three fast-path switches (store buffer, SDRAM line, DMA
// snoop) were OSD "Dbg" options during the Ethernet bring-up; the paths
// have been on in every release since, so the OSD lines are gone and the
// switches are tied to their normal state.
wire  [2:0] dbg_sw  = 3'd0;
always @(posedge clk_sys) if (reset) begin
	eth_ena <= (SONIC_EN != 0) && status[6];
end

// Only settings latched under reset need the pending indicator.
assign settings_pending = (ram_cfg != ram_cfg_osd)
`ifndef VIDEO_512_OFF
	|| (mon_12in != status[5])
`endif
`ifndef ETHERNET_OFF
	|| (eth_ena != status[6])
`endif
	;

wire [11:0] eth_mem_addr;
wire        eth_mem_rd, eth_mem_we;
wire [63:0] eth_mem_wdata;
reg         eth_mem_accept = 1'b0;
wire        eth_mem_rvalid;

lc475 #(.AP040_HAS_FPU(0), .CLK_HZ(SYS_CLK_HZ), .RAM_ADDR_BITS(RAM_ADDR_BITS), .CDROM(CDROM_EN), .SONIC(SONIC_EN)) machine (
`ifdef SWIM2
	.floppy_sel(floppy_sel), .floppy_write(floppy_write), .floppy_addr(floppy_addr),
	.floppy_wdata(floppy_wdata), .floppy_rdata(floppy_rdata),
`endif
	.clk(clk_sys),
	.nreset(~reset),
	.cuda_power_reset_n(pll_locked),
	.cuda_host_reset_n(~host_reset),
	.cuda_reset_n(cuda_reset_n),
	.cuda_storage_ready(cuda_storage_ready),
	.ce(1'b1),
	.clk_vid(clk_vid),
	.nreset_vid(nreset_vid),
	.ram_cfg(ram_cfg),
	.mon_sel({1'b0, mon_12in}),

	.mem_req(mem_req),
	.mem_write(mem_write),
	.mem_addr(mem_addr),
	.mem_be(mem_be),
	.mem_wdata(mem_wdata),
	.mem_memsel(mem_memsel),
	.mem_rdata(mem_rdata),
	.mem_ack(mem_ack),
	.mem_wp_valid(mem_wp_valid),
	.mem_wp_addr(mem_wp_addr),
	.mem_wp_be(mem_wp_be),
	.mem_wp_data(mem_wp_data),
	.mem_wq_room(sdr_wq_room),
	.mem_vram_wq_room(vram_wq_room),
	.mem_vram_wp(mem_vram_wp),
	.mem_vram_fast_addr(vram_fast_addr),
	.mem_vram_fast_take(vram_fast_take),
	.mem_vram_fast_hit(vram_fast_hit),
	.mem_vram_fast_data(vram_fast_data),
	.mem_line_valid(sdr_line_valid),
	.mem_line_tag(sdr_line_tag),
	.mem_line_data(sdr_line_data),
	.mem_rom_line_valid(rom_line_valid),
	.mem_rom_line_tag(rom_line_tag),
	.mem_rom_line_data(rom_line),
	.mem_line_pending(sdr_line_pending),
	.mem_line_pending_tag(sdr_line_pending_tag),

	.vid_addr(vid_addr),
	.vid_rdata(vid_rdata),
	.vid_stride(vid_stride),
	.vid_col_word(vid_col_word),
	.vid_line_req(vid_line_req),
	.vid_line_addr(vid_line_addr),
	.vid_line_swap(vid_line_swap),
	.VGA_R(mac_vga_r),
	.VGA_G(mac_vga_g),
	.VGA_B(mac_vga_b),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_HB(m_hblank),
	.VGA_VB(m_vblank),
	.CE_PIXEL(CE_PIXEL),

	.AUDIO_L(mac_audio_l),
	.cd_snd_l(cd_snd_l),
	.cd_snd_r(cd_snd_r),
	.AUDIO_R(mac_audio_r),

	.ps2_key(ps2_key_m),
	.ps2_mouse(ps2_mouse),
	.timestamp(TIMESTAMP),
	.pram_h_we(pram_h_we),
	.pram_h_addr(pram_h_addr),
	.pram_h_wdata(sd_buff_dout),
	.pram_h_rdata(pram_h_rdata),
	.pram_wr_stb(pram_wr_stb),

	.scc_rxd_a(serialIn),
	.scc_txd_a(serialOut),
	.scc_cts_a(serialCTS),
	.scc_rts_a(serialRTS),
	.scc_rxd_b(1'b1),          // printer port RX idles high (no LocalTalk yet)
	.scc_txd_b(serialOutB),

	.img_mounted(mach_img_mounted),
	.img_size(mach_img_size),
	.io_lba(scsi_lba),
	.io_blk_cnt(scsi_blk_cnt),
	.io_rd(scsi_rd),
	.io_wr(scsi_wr),
	.io_ack(scsi_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(scsi_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.dbg_berr(),
	.dbg_berr_addr(),
	.dbg_overlay(),
	.debug_status(m_debug_status),
	.debug_status2(m_debug_status2),
	.debug_fault(),
	.debug_halted(m_debug_halted),
	.video_diagnostic(video_diagnostic), .adb_diagnostic(adb_diagnostic),
	.perf_show(perf_show), .perf_page(perf_page),
	.perf_clear(perf_clear), .perf_freeze(perf_freeze),
	.perf_vram_ev(vram_perf_ev),
	.perf_rd_idx(perf_rd_idx), .perf_rd_data(perf_rd_data),
	.video_platform_status({8'h60, rom_loaded, pll_locked, pll_video_locked, pix_quiet,
	                       pram_ready, cuda_storage_ready, cuda_reset_n, reset}),

	.eth_ena(eth_ena),
	.dbg_sw(dbg_sw),
	.eth_mem_addr(eth_mem_addr),
	.eth_mem_rd(eth_mem_rd),
	.eth_mem_we(eth_mem_we),
	.eth_mem_wdata(eth_mem_wdata),
	.eth_mem_accept(eth_mem_accept),
	.eth_mem_rvalid(eth_mem_rvalid),
	.eth_mem_rdata(DDRAM_DOUT)
);

wire m_hblank, m_vblank;
assign CLK_VIDEO = clk_vid;
wire mac_de = ~(m_hblank | m_vblank);
wire m_debug_halted, video_probe_request;
wire [3:0] video_probe_result;
video_probe video_probe (
	.clk(clk_sys), .clk_vid(clk_vid), .de(VGA_DE), .enable(video_diagnostic),
	.osd_open(OSD_STATUS),
	.rgb({VGA_R, VGA_G, VGA_B}),
	.pll_locked(pll_video_locked), .settling(pix_quiet), .video_reset_n(nreset_vid),
	.machine_reset(reset), .halted(m_debug_halted),
	.request(video_probe_request), .result(video_probe_result)
);

// Aspect ratio and integer scaling are the framework's: video_freak turns
// the OSD's Scale choice into the VIDEO_ARX/ARY scaled-size form the
// scaler understands (V-Integer keeps every Mac line an integer number of
// output lines).  No crop.
video_freak video_freak
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(mac_de),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, scale_v})
);

//////////////////////////////////////////////////////////////////
// SCC serial — MidiLink / PPP / console on channel A, MT32-pi on the user port
//
// Channel A TX fans out to BOTH the HPS UART (UART_TXD -> MidiLink, PPP,
// console) and the MT32-pi's MIDI-in on the user port.  RX sources:
//   - ALWAYS the HPS UART (UART_RXD) — MidiLink / console / PPP.
//   - In OSD UART mode = MIDI ONLY, the user-port MIDI-in line (mt32_midi_rx:
//     the Pi's TX pin when an MT32-pi is detected, USER_IN[0] otherwise) is
//     AND-merged in.  Both lines idle high, so the merge is inert until a
//     source actually transmits and a start bit from either reaches the SCC.
//
// The uart_mode gate is load-bearing, and is the one piece here that was paid
// for in hardware debugging on the LC: an unconditional
// `mt32_available ? mt32_midi_rx : UART_RXD` mux repointed guest RX at the
// Pi's MIDI-return line whenever a Pi was detected, so EVERY guest-receive
// path died with a Pi plugged in while TX kept working (which made it look
// one-directional).  PPP was what exposed it — LCP hung because the guest
// never saw pppd's ConfAck.  Outside MIDI mode serialIn is UART_RXD alone, so
// the user port can never hijack guest receive; PPP/console are unaffected.
//////////////////////////////////////////////////////////////////
wire serialOut, serialRTS;
wire serialOutB;                           // printer port TX — unused for now
// The HPS UART's RTS, as the framework presents it (active low): a printer
// daemon or pppd opened with RTS/CTS asserts it (low) when it can take data.
// It reaches RR0's CTS bit uninverted, which is the polarity the Mac's
// drivers want (hardware-settled, docs/perf/p262_trial_hw_20260929): 0 =
// clear to send, and a daemon that is not running or drops RTS holds the
// Mac off.  It used to be a constant 1 (never reaching RR0, which read 0).
wire serialCTS = UART_CTS;
wire [7:0] uart_mode;                      // from hps_io; 3 = MIDI

`ifdef MT32PI_OFF
wire userport_midi_in = (uart_mode == 8'd3) ? USER_IN[0] : 1'b1;
`else
wire userport_midi_in = (uart_mode == 8'd3) ? mt32_midi_rx : 1'b1;
`endif
wire serialIn = UART_RXD & userport_midi_in;
`ifdef SWIM2_TRACE
wire floppy_trace_tx;
assign UART_TXD = floppy_trace_tx;
`else
assign UART_TXD = serialOut;
`endif
assign UART_RTS = serialRTS;
assign UART_DTR = UART_DSR;

wire mt32_lcd, mt32_lcd_pix;
wire signed [17:0] synth_audio_l, synth_audio_r;
`ifndef MT32PI_OFF
// MT32-pi on the user port (framework module sys/mt32pi.sv): serial MIDI out
// on USER_OUT[1] at the SCC's programmed rate, I2S synth audio back on
// USER_IN[2/4/5], I2C detection/control on USER_IN[0]/[3].  The synth path
// runs in the fixed 24.576 MHz CLK_AUDIO domain; the LCD-overlay raster
// tracker runs on clk_vid and its box is composited into VGA_R/G/B below.
wire [15:0] mt32_i2s_l, mt32_i2s_r;
wire        mt32_available;
wire        mt32_midi_rx;
wire        mt32_disable = status[35];              // "Use MT32-pi" = No
wire        mt32_mute    = mt32_available & mt32_disable;
wire        mt32_use     = mt32_available & ~mt32_disable;
wire  [1:0] mt32_info    = status[43:42];           // No/Yes/LCD-On/LCD-Auto
wire  [7:0] mt32_mode, mt32_rom, mt32_sf;
wire        mt32_newmode;
wire        mt32_lcd_en, mt32_lcd_update;

mt32pi mt32pi
(
	.CLK_AUDIO(CLK_AUDIO),
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.USER_IN(USER_IN),
	.USER_OUT(USER_OUT),
	.reset(reset),
	.midi_tx(serialOut | mt32_mute),        // idle the Pi's MIDI-in when off
	.midi_rx(mt32_midi_rx),
	.mt32_i2s_r(mt32_i2s_r),
	.mt32_i2s_l(mt32_i2s_l),
	.mt32_available(mt32_available),
	.mt32_mode_req(status[36]),             // Synth: 0=Munt, 1=FluidSynth
	.mt32_rom_req(status[38:37]),           // Munt ROM: MT-32 v1/v2/CM-32L
	.mt32_sf_req({5'd0, status[41:39]}),    // SoundFont 0-7
	.mt32_mode(mt32_mode),
	.mt32_rom(mt32_rom),
	.mt32_sf(mt32_sf),
	.mt32_newmode(mt32_newmode),
	.mt32_lcd_en(mt32_lcd_en),
	.mt32_lcd_pix(mt32_lcd_pix),
	.mt32_lcd_update(mt32_lcd_update)
);

// "Show Info = Yes": on a Pi-acknowledged mode change (mt32_newmode toggles),
// flash the mode name via the framework info popup (hps_io info_req/info ->
// the CONF_STR "I," strings, 1-based).  Block is ao486-verbatim.
reg       mt32_info_req;
reg [3:0] mt32_info_disp;
always @(posedge clk_sys) begin
	reg old_mode;

	old_mode <= mt32_newmode;
	mt32_info_req <= (old_mode ^ mt32_newmode) && (mt32_info == 1);

	mt32_info_disp <= (mt32_mode == 'hA2) ? (4'd1 + mt32_sf[2:0]) :
	                  (mt32_mode == 'hA1 && mt32_rom == 0) ?  4'd9 :
	                  (mt32_mode == 'hA1 && mt32_rom == 1) ?  4'd10 :
	                  (mt32_mode == 'hA1 && mt32_rom == 2) ?  4'd11 : 4'd12;
end

// LCD overlay visibility (ao486 pattern): "LCD-On" pins it up, "LCD-Auto"
// shows it while the Pi pushes LCD updates and drops it after a timeout.
// clk_vid is the 25.175 MHz dot clock here, so 50M ticks is ~2.0 s.
reg mt32_lcd_on;
always @(posedge clk_vid) begin
	int to;
	reg old_update;

	old_update <= mt32_lcd_update;
	if(to) to <= to - 1;

	if(mt32_info_v == 2) mt32_lcd_on <= 1;
	else if(mt32_info_v != 3) mt32_lcd_on <= 0;
	else begin
		if(!to) mt32_lcd_on <= 0;
		if(old_update ^ mt32_lcd_update) begin
			mt32_lcd_on <= 1;
			to <= 50_000_000;
		end
	end
end

assign mt32_lcd = mt32_lcd_en & mt32_lcd_on;
assign synth_audio_l = mt32_use ? {{2{mt32_i2s_l[15]}}, mt32_i2s_l} : 18'sd0;
assign synth_audio_r = mt32_use ? {{2{mt32_i2s_r[15]}}, mt32_i2s_r} : 18'sd0;
`else
// Plain user-port MIDI remains available without the synth interface.
assign USER_OUT = {5'b11111, serialOut, 1'b1};
assign mt32_lcd = 1'b0;
assign mt32_lcd_pix = 1'b0;
assign synth_audio_l = 18'sd0;
assign synth_audio_r = 18'sd0;
`endif

// Video: inside the overlay box the picture is dimmed to its low 6 bits and
// the LCD text pixel is OR'd into the top 2 (ao486's compositing, verbatim).
wire [7:0] mac_vga_r, mac_vga_g, mac_vga_b;
assign VGA_R = video_diagnostic_v ? (mac_vga_r | 8'h40) :
               mt32_lcd ? {{2{mt32_lcd_pix}}, mac_vga_r[7:2]} : mac_vga_r;
assign VGA_G = video_diagnostic_v ? (mac_vga_g | 8'h40) :
               mt32_lcd ? {{2{mt32_lcd_pix}}, mac_vga_g[7:2]} : mac_vga_g;
assign VGA_B = video_diagnostic_v ? (mac_vga_b | 8'h40) :
               mt32_lcd ? {{2{mt32_lcd_pix}}, mac_vga_b[7:2]} : mac_vga_b;

// Audio: the MT32-pi I2S return joins at unity gain, gated by mt32_use (a Pi
// is present AND "Use MT32-pi" is Yes); exact zeros otherwise, so the mix is
// bit-identical to today with no Pi attached or the device disabled.
wire signed [15:0] mac_audio_l, mac_audio_r;
// CD-DA from the SCSI CD-ROM's audio engine (rtl/cd_audio.sv): exact zeros
// unless the AppleCD player is playing, so the mix is unchanged otherwise.
// These were left undeclared at the instantiation once (implicit 1-bit
// nets, never summed): the engine played, the core stayed silent.
wire signed [15:0] cd_snd_l, cd_snd_r;
wire signed [17:0] audio_mix_l = {{2{mac_audio_l[15]}}, mac_audio_l}
                               + {{2{cd_snd_l[15]}}, cd_snd_l}
                               + synth_audio_l;
wire signed [17:0] audio_mix_r = {{2{mac_audio_r[15]}}, mac_audio_r}
                               + {{2{cd_snd_r[15]}}, cd_snd_r}
                               + synth_audio_r;
assign AUDIO_L = (audio_mix_l > 18'sd32767)  ?  16'sd32767 :
                 (audio_mix_l < -18'sd32768) ? -16'sd32768 : audio_mix_l[15:0];
assign AUDIO_R = (audio_mix_r > 18'sd32767)  ?  16'sd32767 :
                 (audio_mix_r < -18'sd32768) ? -16'sd32768 : audio_mix_r[15:0];

assign LED_USER = ioctl_download | (|sd_rd) | (|sd_wr);
assign LED_DISK = {1'b1, (|sd_rd) | (|sd_wr)};

//////////////////////////////////////////////////////////////////
// SDRAM — the machine's RAM.  ROM stays in DDR3 (it is uploaded once
// through the ioctl path and read rarely enough that latency is free).
//
// rtl/sdram_beat32.sv owns the 16-bit controller and both clock domains:
// one read captures a complete BL8/16-byte line, returning its critical
// longword first; a write uses two 16-bit commands and is acknowledged here
// before it drains behind the machine.  The
// controller runs at 75 MHz — three times clk_sys, from the same PLL — and
// derives SDRAM_CLK itself with an altddio_out, so no phase-shifted clock
// is needed here.
//////////////////////////////////////////////////////////////////

wire        sdr_ack;
wire [31:0] sdr_rdata;
wire        sdr_beat_req, sdr_beat_we, sdr_beat_ack, sdr_busy;
wire [26:2] sdr_beat_addr;
wire [3:0]  sdr_beat_be;
wire [31:0] sdr_beat_wdata, sdr_beat_rdata;

`ifdef SWIM2
// Floppy lock acts like the disk's write-protect tab: the loader samples it
// together with the image's read-only flag when a disk is inserted, so
// toggling it affects the next insert, never the disk the guest has mounted.
// No reset needed, so it stays out of settings_pending.
wire floppy_lock = status[18];

// Guest reset drains media ownership; only PLL loss aborts the storage path.
swim2_platform #(.CLK_HZ(SYS_CLK_HZ)) floppy (
	.clk(clk_sys), .nreset(pll_locked), .guest_reset(reset), .init(~pll_locked),
	.sdram_sz(sdram_sz), .EXT_BUS(floppy_ext_bus),
	.sel(floppy_sel), .write(floppy_write), .addr(floppy_addr),
	.wdata(floppy_wdata), .rdata(floppy_rdata),
	.img_mounted(img_mounted[VD_FLOPPY]), .img_size(img_size),
	.img_readonly(img_readonly | floppy_lock),
	.sd_lba(sd_lba[VD_FLOPPY]), .sd_rd(sd_rd[VD_FLOPPY]), .sd_wr(sd_wr[VD_FLOPPY]),
	.sd_ack(sd_ack[VD_FLOPPY]), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr), .sd_buff_din(sd_buff_din[VD_FLOPPY]), .fault(floppy_fault),
	.cpu_req(mem_req && mem_is_ram), .cpu_we(mem_write), .cpu_addr(mem_addr[26:2]),
	.cpu_be(mem_be), .cpu_wdata(mem_wdata), .cpu_ack(sdr_ack), .cpu_rdata(sdr_rdata),
	.beat_req(sdr_beat_req), .beat_we(sdr_beat_we), .beat_addr(sdr_beat_addr),
	.beat_be(sdr_beat_be), .beat_wdata(sdr_beat_wdata), .beat_ack(sdr_beat_ack),
	.beat_rdata(sdr_beat_rdata), .beat_busy(sdr_busy), .beat_line_pending(sdr_line_pending)
`ifdef SWIM2_TRACE
	, .trace_tx(floppy_trace_tx)
`endif
);
`else
assign sdr_beat_req = mem_req && mem_is_ram;
assign sdr_beat_we = mem_write;
assign sdr_beat_addr = mem_addr[26:2];
assign sdr_beat_be = mem_be;
assign sdr_beat_wdata = mem_wdata;
assign sdr_ack = sdr_beat_ack;
assign sdr_rdata = sdr_beat_rdata;
`endif

// The ack the machine sees is this bridge's, the VRAM port's or the ROM one;
// they are never asserted together, because mem_memsel picks exactly one
// consumer.  A VRAM beat is acknowledged in its second clock, straight from
// the block RAM's output, or by vram_ddr3 (vram_ack, below).
wire        vram_ack;
`ifdef VRAM_BRAM
reg  [31:0] vram_qa;
`else
wire [31:0] vram_qa;
`endif
assign mem_ack   = mem_ack_r | sdr_ack | vram_ack;
assign mem_rdata = sdr_ack ? sdr_rdata : mem_is_vram ? vram_qa : mem_rdata_r;

sdram_beat32 #(.RAM_CLK_HZ(RAM_CLK_HZ)) sdr
(
	.init      (~pll_locked),
	.clk_sys   (clk_sys),
	.clk_ram   (clk_ram),

	.req       (sdr_beat_req),
	.we        (sdr_beat_we),
	.addr      (sdr_beat_addr),
	.be        (sdr_beat_be),
	.wdata     (sdr_beat_wdata),
	.ack       (sdr_beat_ack),
	.rdata     (sdr_beat_rdata),
	.busy      (sdr_busy),
	.line_valid_o(sdr_line_valid),
	.line_tag_o(sdr_line_tag),
	.line_data_o(sdr_line_data),
	.line_pending_o(sdr_line_pending),
	.line_pending_tag_o(sdr_line_pending_tag),
	.wp_valid  (mem_wp_valid),
	.wp_addr   (mem_wp_addr[26:2]),
	.wp_be     (mem_wp_be),
	.wp_data   (mem_wp_data),
	.wq_room   (sdr_wq_room),

	.SDRAM_DQ  (SDRAM_DQ),
	.SDRAM_A   (SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA  (SDRAM_BA),
	.SDRAM_nCS (SDRAM_nCS),
	.SDRAM_nWE (SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE (SDRAM_CKE),
	.SDRAM_CLK (SDRAM_CLK)
);

// DDR3 VRAM client port to the bridge below (tied off under VRAM_BRAM)
wire        vram_ddr_req, vram_ddr_we;
wire [28:0] vram_ddr_addr;
wire  [7:0] vram_ddr_burstcnt;
wire [63:0] vram_ddr_din;
wire  [7:0] vram_ddr_be;
wire        vram_ddr_ack;
wire        vram_ddr_rvalid;

`ifdef VRAM_BRAM
//////////////////////////////////////////////////////////////////
// VRAM — on-chip, true dual port: CPU beats on port A (2-cycle
// handshake: capture, then deliver), DAFB scanout on port B with the
// registered 1-cycle read the machine expects.
//
// The machine's 2 MB window aliases mod 512 KB, so a ROM size probe sees
// the classic power-of-2 wrap and ADVERTISES 512 KB.  Backing all of it
// is impossible on this device — but it does not have to be backed
// densely; see the compaction note on VRAM_WORDS below.
//////////////////////////////////////////////////////////////////
// STRIDE COMPACTION.  The ROM programs a 1024-byte row pitch (confirmed on
// hardware and by the sim's [DAFB] tap), so a 480-row framebuffer spans
// 0x1000 + 480*1024 = 495,616 bytes — far past anything M10K can hold, and
// the old fold aliased screen rows 304..479 back onto rows 100..275 (the
// duplicated boot floppy seen on the DE10).
//
// But at 640 pixels wide only the FIRST 640 bytes of each 1024-byte row are
// ever visible: 80 bytes at 1bpp, 160 at 2bpp, 320 at 4bpp, 640 at 8bpp.
// The remaining 384 bytes are pitch padding no supported depth reaches.  So
// store 640 bytes of every row and drop the tail: the whole 512 KB window
// becomes 512*640 = 320 KB of BRAM, which fits with room to spare, and
// EVERY row of EVERY depth (8bpp included) is backed exactly once — no
// aliasing anywhere in the visible framebuffer.
//
// The 384-byte tails all share one scratch block, so a write and read-back
// at the same tail address still agree (VRAM size probes poke row-aligned
// offsets, which are all col 0).  Only software genuinely storing data in
// the pitch padding of two different rows at once would notice.
//
// Compaction assumes the 1024-byte pitch, so it engages only when the
// driver has actually programmed one; any pitch <= 640 already fits the
// array linearly and maps identically (with the old fold as a backstop for
// probe reads past the end).
localparam VRAM_WORDS = 82016;             // 320.4 KB: 512*160 + 96 tail
localparam [16:0] VRAM_FOLD = 17'd52224;   // 204 KB, in words
localparam [16:0] VRAM_TAIL = 17'd81920;   // 512 rows * 160 words

wire vram_compact = (vid_stride == 14'd1024);

function [16:0] vram_map(input [16:0] w);  // window word -> storage word
	reg [8:0] row;                         // 1024 B = 256 words per row
	reg [7:0] col;
	begin
		row = w[16:8];
		col = w[7:0];
		if (!vram_compact)
			vram_map = (w >= VRAM_WORDS) ? (w - VRAM_FOLD) : w;
		else if (col < 8'd160)             // visible 640 bytes: row*160 + col
			vram_map = {row, 7'd0} + {2'd0, row, 5'd0} + {9'd0, col};
		else                               // pitch padding: shared scratch
			vram_map = VRAM_TAIL + {9'd0, (col - 8'd160)};
	end
endfunction

reg        vram_ph;                        // port-A phase: 0 capture, 1 deliver

wire [16:0]  va_addr     = vram_map(mem_addr[18:2]);
wire [16:0]  vb_addr     = vram_map(vid_addr[18:2]);
// a beat writes in its capture clock; a direct write (the store buffer's
// drain, lc475 bus_vram_direct) is a one-clock pulse with mem_req low
wire         va_we       = (mem_req && mem_is_vram && mem_write && !vram_ph) || mem_vram_wp;
assign       vram_ack    = mem_req && mem_is_vram && vram_ph;

// Storage is one byte-wide array per lane rather than one 32-bit array
// with byte enables: mem_be becomes each lane's write enable, so nothing
// rests on Quartus inferring byte enables on a true-dual-port M10K, and a
// x8 two-read-port array is the simplest shape a block can take.
// no_rw_check is accurate here — port A throws its read away on a write
// cycle (vram_ph delivers on the FOLLOWING cycle), so the
// read-during-write value is a genuine don't-care.  Without these
// attributes Quartus honors the implied "old data" same-port
// read-during-write in logic cells, and 2.5 Mbit of registers is what
// turns Analysis & Synthesis into an all-day run that never finishes.
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram0 [0:VRAM_WORDS-1];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram1 [0:VRAM_WORDS-1];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram2 [0:VRAM_WORDS-1];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] vram3 [0:VRAM_WORDS-1];

always @(posedge clk_sys) begin            // port A: CPU beats
	if (va_we && mem_be[0]) vram0[va_addr] <= mem_wdata[7:0];
	if (va_we && mem_be[1]) vram1[va_addr] <= mem_wdata[15:8];
	if (va_we && mem_be[2]) vram2[va_addr] <= mem_wdata[23:16];
	if (va_we && mem_be[3]) vram3[va_addr] <= mem_wdata[31:24];
	vram_qa <= {vram3[va_addr], vram2[va_addr],
	            vram1[va_addr], vram0[va_addr]};
end

// port B: DAFB scanout, on the PIXEL clock.  M10K is natively dual-clock, so
// this costs nothing and there is no timed arc between the ports -- the
// crossing is blessed in MacLC475.sdc along with the rest of clk_vid.
always @(posedge clk_vid)
	vid_rdata <= {vram3[vb_addr], vram2[vb_addr],
	              vram1[vb_addr], vram0[vb_addr]};

// the port-A phase toggles with each VRAM beat (was in the DDR3 bridge)
always @(posedge clk_sys) begin
	if (mem_req && mem_is_vram) vram_ph <= !vram_ph;
	if (reset && !ioctl_download) vram_ph <= 0;
end

assign vram_wq_room      = 1'b1;
assign vram_perf_ev      = 12'd0;
assign vram_fast_hit     = 1'b0;
assign vram_fast_data    = 32'd0;
assign vram_ddr_req      = 1'b0;
assign vram_ddr_we       = 1'b0;
assign vram_ddr_addr     = 29'd0;
assign vram_ddr_burstcnt = 8'd0;
assign vram_ddr_din      = 64'd0;
assign vram_ddr_be       = 8'd0;
`else
//////////////////////////////////////////////////////////////////
// VRAM — 1 MB in DDR3 with an M10K ping-pong scanline cache
// (rtl/vram_ddr3.sv, imported from the lean Q800 DDR3 branch).  Flat, no
// pitch compaction: the ROM's size probe wraps at 1 MB, so it advertises
// 1 MB of VRAM (a real LC 475 with the VRAM SIMM).  CPU beats go through
// the module's read cache and write queue (vram_wq_room gates the
// machine's direct VRAM writes); the scanout reads a line the DMA
// fetched during the previous one.
//////////////////////////////////////////////////////////////////
localparam [28:0] DDR_VRAM_BASE = 29'h0500_0000;   // byte 0x2800_0000 >> 3

vram_ddr3 #(
	.DDR_VRAM_BASE(DDR_VRAM_BASE),
	.VRAM_1MB(1)
) vram_inst (
	.clk_sys(clk_sys),
	.reset(reset),

	.mem_req(mem_req),
	.mem_is_vram(mem_is_vram),
	.mem_write(mem_write),
	.mem_addr(mem_addr),
	.mem_be(mem_be),
	.mem_wdata(mem_wdata),
	.mem_vram_wp(mem_vram_wp),
	.vram_ack(vram_ack),
	.vram_rdata(vram_qa),
	.vram_wq_room(vram_wq_room),
	.fast_addr(vram_fast_addr),
	.fast_take(vram_fast_take),
	.fast_hit(vram_fast_hit),
	.fast_data(vram_fast_data),
	.perf_ev(vram_perf_ev),

	.clk_vid(clk_vid),
	.reset_vid(!nreset_vid),
	.vid_col_word(vid_col_word),
	.vid_stride(vid_stride),
	.vid_line_req(vid_line_req),
	.vid_line_addr(vid_line_addr),
	.vid_line_swap(vid_line_swap),
	.vid_rdata(vid_rdata),

	.vram_ddr_req(vram_ddr_req),
	.vram_ddr_we(vram_ddr_we),
	.vram_ddr_addr(vram_ddr_addr),
	.vram_ddr_burstcnt(vram_ddr_burstcnt),
	.vram_ddr_din(vram_ddr_din),
	.vram_ddr_be(vram_ddr_be),
	.vram_ddr_busy(DDRAM_BUSY),
	.vram_ddr_ack(vram_ddr_ack),
	.vram_ddr_dout(DDRAM_DOUT),
	.vram_ddr_rvalid(vram_ddr_rvalid)
);
`endif

//////////////////////////////////////////////////////////////////
// DDR3 bridge — RAM + ROM regions, plus the boot0.rom upload path.
// 64-bit word convention: the machine's 32-bit word at byte address A
// sits in DDRAM_DOUT[31:0] when A[2]=0 and [63:32] when A[2]=1; the
// big-endian byte packing inside the 32-bit lane is preserved, so
// mem_be maps 1:1 onto DDRAM_BE (shifted by the half-select).
//////////////////////////////////////////////////////////////////
assign DDRAM_CLK = clk_sys;

localparam [28:0] DDR_RAM_BASE = 29'h0600_0000;   // byte 0x3000_0000 >> 3
localparam [28:0] DDR_ROM_BASE = 29'h0700_0000;   // byte 0x3800_0000 >> 3
// The Ethernet mailbox window the Main fork maps (support/mac/mac_eth.h): ARM
// physical 0x1FF00000, the area the Minimig A2065 and the MacLC card use too.
localparam [28:0] DDR_ETH_BASE = 29'h03FE_0000;   // byte 0x1FF0_0000 >> 3

// the VRAM client's bursts (rtl/vram_ddr3.sv): reads are acknowledged on
// issue and their beats counted back; a write burst holds DDRAM_WE and
// streams vram_ddr_din/be until every beat is taken
reg        ddr_wait_vram = 1'b0;
reg  [7:0] ddr_vram_beats_left = 8'd0;
reg        ddr_wait_vram_wr = 1'b0;
reg  [7:0] ddr_vram_wr_beats_left = 8'd0;
reg        vram_ddr_accept = 1'b0;
reg        vram_rd_ack = 1'b0;
wire       vram_wr_ack = ddr_wait_vram_wr && !DDRAM_BUSY;
assign     vram_ddr_ack = vram_wr_ack || vram_rd_ack;
assign     vram_ddr_rvalid = ddr_wait_vram && DDRAM_DOUT_READY;

reg  [7:0] ddram_burstcnt;
reg [28:0] ddram_addr;
reg [63:0] ddram_din;
reg  [7:0] ddram_be;
reg        ddram_we, ddram_rd;
assign DDRAM_BURSTCNT = ddram_burstcnt;
assign DDRAM_ADDR     = ddram_addr;
// a VRAM write burst streams the client's data/BE beat by beat
assign DDRAM_DIN      = ddr_wait_vram_wr ? vram_ddr_din : ddram_din;
assign DDRAM_BE       = ddr_wait_vram_wr ? vram_ddr_be  : ddram_be;
assign DDRAM_WE       = ddram_we;
assign DDRAM_RD       = ddram_rd;

reg        ioctl_pend;
reg [26:0] ioctl_a;
reg [15:0] ioctl_d;
reg        ddr_wait_data;                  // read issued, awaiting DOUT_READY
// The ROM's retained line: every ROM read fetches its whole 16-byte line in
// one two-beat burst, and the machine answers the line's other longwords from
// here (lc475 bus_rom_match) -- the I-cache's fill of a ROM line is one
// DDR3 round trip instead of four.  ROM changes only by a boot0.rom download.
reg [127:0] rom_line;                      // longword 0 in [127:96]
reg  [19:4] rom_line_tag;
reg         rom_line_valid = 1'b0;
reg   [1:0] ddr_rd_word;
reg         ddr_rd_beat1;                  // the line's first 64-bit beat is in
reg        ddr_wait_eth = 1'b0;            // ... for the Ethernet window instead
assign     eth_mem_rvalid = ddr_wait_eth && DDRAM_DOUT_READY;

// Perf counter snapshot (debug builds): every 2^18 clocks (10.5 ms) the 42
// counters of rtl/perf_counters.sv are copied to DDR3 at ARM physical
// 0x27F00000, for support/perf/perflog.py to read over SSH via /dev/mem.  23
// little-endian 64-bit words:
//   word 0       {seq, "PERF" 0x50455246}   written first
//   words 1-21   {counter 2k+1, counter 2k} for k = 0..20
//   word 22      {seq, ~0x50455246}         closes the snapshot
//   words 23-26  the CPU's last F-line / illegal trap (perf_counters reads
//                42-49; layout in ap68040_backend dbg_trap), after the
//                trailer so perflog.py's 23-word snapshot is unchanged
// A reader that finds the two seq fields equal has a whole snapshot.  The
// counters are read one per clock while the copy runs, so a snapshot spans a
// few microseconds; nothing is cleared or frozen.  Writes go after every
// other DDR3 client, one beat each.
localparam [28:0] DDR_PERF_BASE = 29'h04FE_0000;  // byte 0x27F0_0000 >> 3
localparam [31:0] PERF_MAGIC    = 32'h5045_5246;
`ifdef MACLC475_DEBUG
localparam PERF_DDR = 1;
`else
localparam PERF_DDR = 0;
`endif
reg [17:0] perf_ddr_tick = 18'd0;
reg [31:0] perf_ddr_seq = 32'd0;
reg        perf_ddr_busy = 1'b0;
reg  [4:0] perf_ddr_word = 5'd0;           // 0-22
reg  [1:0] perf_ddr_phase = 2'd0;
reg  [5:0] perf_ddr_idx = 6'd0;
reg [31:0] perf_ddr_lo = 32'd0;
reg        perf_ddr_req = 1'b0;
reg [63:0] perf_ddr_data = 64'd0;
reg        perf_ddr_accept = 1'b0;         // arbiter took the beat (pulse)
assign     perf_rd_idx = perf_ddr_idx;

always @(posedge clk_sys) begin
	perf_ddr_tick <= perf_ddr_tick + 1'b1;
	if (perf_ddr_accept) begin
		perf_ddr_req <= 1'b0;
		if (perf_ddr_word == 5'd26) perf_ddr_busy <= 1'b0;
		else perf_ddr_word <= perf_ddr_word + 1'b1;
	end
	else if (!perf_ddr_busy) begin
		if (PERF_DDR && perf_ddr_tick == 18'd0) begin
			perf_ddr_busy  <= 1'b1;
			perf_ddr_seq   <= perf_ddr_seq + 1'b1;
			perf_ddr_word  <= 5'd0;
			perf_ddr_phase <= 2'd0;
		end
	end
	else if (!perf_ddr_req) begin
		case (perf_ddr_phase)
		2'd0:
			if (perf_ddr_word == 5'd0) begin
				perf_ddr_data <= {perf_ddr_seq, PERF_MAGIC};
				perf_ddr_req  <= 1'b1;
			end
			else if (perf_ddr_word == 5'd22) begin
				perf_ddr_data <= {perf_ddr_seq, ~PERF_MAGIC};
				perf_ddr_req  <= 1'b1;
			end
			else begin
				perf_ddr_idx   <= (perf_ddr_word > 5'd22) ? {perf_ddr_word - 5'd2, 1'b0}
				                                           : {perf_ddr_word - 5'd1, 1'b0};
				perf_ddr_phase <= 2'd1;
			end
		2'd1: begin
			perf_ddr_lo    <= perf_rd_data;
			perf_ddr_idx   <= perf_ddr_idx + 1'b1;
			perf_ddr_phase <= 2'd2;
		end
		default: begin
			perf_ddr_data  <= {perf_rd_data, perf_ddr_lo};
			perf_ddr_req   <= 1'b1;
			perf_ddr_phase <= 2'd0;
		end
		endcase
	end
end

// 128 KB on-chip ROM cache (lean Q800): a hit answers in two clocks with
// no DDR3 trip, so ROM code no longer queues behind the VRAM line DMA.
// Invalidated on every reset, which a boot0.rom download holds.
`ifdef ROM_CACHE_OFF
localparam ROM_CACHE = 0;
wire        rom_cache_hit  = 1'b0;
wire [127:0] rom_cache_data = 128'd0;
`else
localparam ROM_CACHE = 1;
wire        rom_cache_hit;
wire [127:0] rom_cache_data;
`endif
reg         rom_cache_fill_we = 1'b0;
reg  [19:4] rom_cache_fill_addr = 16'd0;
reg [127:0] rom_cache_fill_data = 128'd0;
reg         rom_cache_checking = 1'b0;
reg         rom_ddr_pend = 1'b0;

`ifndef ROM_CACHE_OFF
rom_cache_128k rom_cache (
	.clk(clk_sys),
	.rst(reset),
	.lookup_req(mem_req && mem_is_rom && !mem_write),
	.lookup_addr(mem_addr[19:4]),
	.lookup_hit(rom_cache_hit),
	.lookup_data(rom_cache_data),
	.fill_we(rom_cache_fill_we),
	.fill_addr(rom_cache_fill_addr),
	.fill_data(rom_cache_fill_data)
);
`endif

always @(posedge clk_sys) begin
	mem_ack_r <= 0;
	eth_mem_accept <= 0;
	perf_ddr_accept <= 0;
	vram_rd_ack <= 0;
	rom_cache_fill_we <= 0;

	// djMEMC discards ROM writes
	if (mem_req && !mem_ack && mem_is_rom && mem_write) mem_ack_r <= 1;

	// ROM read: the on-chip cache first (one clock to look), else DDR3
	if (rom_cache_checking) begin
		rom_cache_checking <= 0;
		if (rom_cache_hit) begin
			rom_line       <= rom_cache_data;
			rom_line_tag   <= mem_addr[19:4];
			rom_line_valid <= 1;
			case (mem_addr[3:2])
				2'd0: mem_rdata_r <= rom_cache_data[127:96];
				2'd1: mem_rdata_r <= rom_cache_data[95:64];
				2'd2: mem_rdata_r <= rom_cache_data[63:32];
				2'd3: mem_rdata_r <= rom_cache_data[31:0];
			endcase
			mem_ack_r <= 1;
		end
		else rom_ddr_pend <= 1;
	end
	else if (mem_req && !mem_ack && mem_is_rom && !mem_write && !ddr_wait_data && !rom_ddr_pend) begin
		if (ROM_CACHE) rom_cache_checking <= 1;
		else           rom_ddr_pend <= 1;
	end

	if (!vram_ddr_req && !ddr_wait_vram_wr) vram_ddr_accept <= 0;

	// boot0.rom halfwords: capture, then stall hps_io until written
	if (ioctl_download && rom_index && ioctl_wr) begin
		ioctl_pend <= 1;
		ioctl_wait <= 1;
		ioctl_a <= ioctl_addr;
		ioctl_d <= ioctl_dout;
	end

	if (!DDRAM_BUSY) begin
		if (!ddr_wait_vram_wr) ddram_we <= 0;
		ddram_rd <= 0;
	end

	if (ddr_wait_vram_wr) begin
		if (!DDRAM_BUSY) begin
			ddr_vram_wr_beats_left <= ddr_vram_wr_beats_left - 1'b1;
			if (ddr_vram_wr_beats_left == 8'd1) begin
				ddram_we         <= 0;
				ddr_wait_vram_wr <= 0;
				if (!vram_ddr_req) vram_ddr_accept <= 0;
			end
		end
	end

	if (ddr_wait_data) begin
		if (DDRAM_DOUT_READY) begin
			// beat 0 holds longwords 0 (low half) and 1, beat 1 longwords 2 and 3
			if (!ddr_rd_beat1) begin
				rom_line[127:64] <= {DDRAM_DOUT[31:0], DDRAM_DOUT[63:32]};
				ddr_rd_beat1 <= 1;
			end
			else begin
				rom_line[63:0] <= {DDRAM_DOUT[31:0], DDRAM_DOUT[63:32]};
				rom_line_valid <= 1;
				case (ddr_rd_word)
					2'd0: mem_rdata_r <= rom_line[127:96];
					2'd1: mem_rdata_r <= rom_line[95:64];
					2'd2: mem_rdata_r <= DDRAM_DOUT[31:0];
					2'd3: mem_rdata_r <= DDRAM_DOUT[63:32];
				endcase
				mem_ack_r   <= 1;
				ddr_wait_data <= 0;
				rom_cache_fill_we   <= 1;
				rom_cache_fill_addr <= rom_line_tag;
				rom_cache_fill_data <= {rom_line[127:64], DDRAM_DOUT[31:0], DDRAM_DOUT[63:32]};
			end
		end
	end
	else if (ddr_wait_vram) begin
		if (DDRAM_DOUT_READY) begin
			ddr_vram_beats_left <= ddr_vram_beats_left - 1'b1;
			if (ddr_vram_beats_left == 8'd1) ddr_wait_vram <= 0;
		end
	end
	else if (ddr_wait_eth) begin
		if (DDRAM_DOUT_READY) ddr_wait_eth <= 0;
	end
	else if (!DDRAM_BUSY && !ddram_we && !ddram_rd) begin
		if (ioctl_pend) begin
			// file bytes are big-endian in the 32-bit lane: swap the
			// little-endian ioctl halfword and replicate across lanes,
			// steering with BE
			ddram_addr     <= DDR_ROM_BASE | {10'd0, ioctl_a[19:3]};
			ddram_din      <= {4{{ioctl_d[7:0], ioctl_d[15:8]}}};
			ddram_be       <= ioctl_a[1] ? (ioctl_a[2] ? 8'h30 : 8'h03)
			                             : (ioctl_a[2] ? 8'hC0 : 8'h0C);
			ddram_burstcnt <= 8'd1;
			ddram_we       <= 1;
			ioctl_pend     <= 0;
			ioctl_wait     <= 0;
		end
		else if (rom_ddr_pend) begin
			ddram_addr     <= DDR_ROM_BASE | {12'd0, mem_addr[19:4], 1'b0};
			ddram_burstcnt <= 8'd2;
			ddram_rd       <= 1;
			ddr_rd_word    <= mem_addr[3:2];
			ddr_rd_beat1   <= 0;
			rom_line_valid <= 0;
			rom_line_tag   <= mem_addr[19:4];
			ddr_wait_data  <= 1;
			rom_ddr_pend   <= 0;
		end
		// the VRAM client: CPU cache fills/misses, write bursts, line DMA
		else if (vram_ddr_req && !vram_ddr_accept) begin
			ddram_addr      <= vram_ddr_addr;
			ddram_burstcnt  <= vram_ddr_burstcnt;
			ddram_we        <= vram_ddr_we;
			ddram_rd        <= !vram_ddr_we;
			if (vram_ddr_we) begin
				ddr_wait_vram_wr       <= 1;
				ddr_vram_wr_beats_left <= vram_ddr_burstcnt;
			end
			else begin
				ddr_wait_vram       <= 1;
				ddr_vram_beats_left <= vram_ddr_burstcnt;
				vram_rd_ack         <= 1;
			end
			vram_ddr_accept <= 1;
		end
		// The Ethernet mailbox comes last: single 64-bit beats, a few hundred a
		// second when the link is idle.  A ROM beat that arrives behind one waits
		// for it, which is one DDR3 round trip.  !eth_mem_accept: the requester
		// needs a clock to drop the request this block has just taken.
		else if ((eth_mem_rd || eth_mem_we) && !eth_mem_accept) begin
			ddram_addr     <= DDR_ETH_BASE | {17'd0, eth_mem_addr};
			ddram_din      <= eth_mem_wdata;
			ddram_be       <= 8'hFF;
			ddram_burstcnt <= 8'd1;
			ddram_we       <= eth_mem_we;
			ddram_rd       <= !eth_mem_we;
			ddr_wait_eth   <= !eth_mem_we;
			eth_mem_accept <= 1;
		end
		// the perf snapshot, behind everything: 23 single beats per 10.5 ms
		else if (perf_ddr_req && !perf_ddr_accept) begin
			ddram_addr      <= DDR_PERF_BASE | {24'd0, perf_ddr_word};
			ddram_din       <= perf_ddr_data;
			ddram_be        <= 8'hFF;
			ddram_burstcnt  <= 8'd1;
			ddram_we        <= 1;
			perf_ddr_accept <= 1;
		end
		// RAM beats are sdram_beat32's; nothing here gates them, so a RAM
		// access never waits on the DDR3 side of this block.
	end

	if (ioctl_download && rom_index) rom_line_valid <= 0;
	if (reset && !ioctl_download) begin
		ddr_wait_data <= 0;
		ddr_wait_vram <= 0;
		rom_cache_checking <= 0;
		rom_ddr_pend <= 0;
		// ddr_wait_eth is NOT cleared: the bridge will still answer that read, and the
		// answer must not be taken for the ROM's.
	end
	if (RESET) begin
		ioctl_pend <= 0;
		ioctl_wait <= 0;
	end
end

endmodule
