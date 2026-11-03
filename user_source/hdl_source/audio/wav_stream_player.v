`timescale 1ns/1ps
// 第 11 讲 PCM 流播放器：SD 控制域文件字节 -> 小端拼帧 -> 异步 FIFO -> 音频域 ready/valid 双声道样本。
// 写侧（wr_clk）：restart 使拼帧回到文件首字节，flush 清空整个缓冲；单声道每 2 字节一帧并复制到左右，
//   立体声每 4 字节一帧（L 在前）；文件尾不足一帧的字节随下一次 restart 丢弃。
//   hold 在 FIFO 余量不足一个扇区（含余量）或复位/清空期间为 1，读取器据此暂停发起新扇区。
// 读侧（rd_clk）：缓冲达到 PREFILL_FRAMES 帧才开放输出，读空后撤销 valid（下游补零）并重新预填充。
// FIFO 复位只来自写域寄存器 fifo_rst_wr；写使能只用写域寄存器门控；读侧附加逻辑经本域 reset_sync 释放。
module wav_stream_player #(
    parameter integer CHANNELS = 1,
    parameter integer FIFO_ADDR_W = 12,
    parameter integer PREFILL_FRAMES = 256,
    parameter integer HOLD_MARGIN = 16
) (
    input  wire               wr_clk,
    input  wire               wr_rst_n,
    input  wire               byte_valid,
    input  wire [7:0]         byte_data,
    input  wire               stream_restart,
    input  wire               stream_flush,
    input  wire               track_active,
    output wire               hold,
    // 粘滞诊断：写入被拒（清空期间收到字节或 FIFO 满），复位清除。
    output reg                overflow,
    input  wire               rd_clk,
    input  wire               rd_rst_n,
    output wire               sample_valid,
    input  wire               sample_ready,
    output wire signed [15:0] sample_left,
    output wire signed [15:0] sample_right,
    output wire               wav_active,
    // 单拍诊断：播放中读空。
    output reg                underflow
);
localparam integer DEPTH = (1 << FIFO_ADDR_W) - 1;
localparam integer BYTES_PER_FRAME = 2 * CHANNELS;
localparam integer SECTOR_FRAMES = 512 / BYTES_PER_FRAME;
localparam integer HOLD_LEVEL = DEPTH - SECTOR_FRAMES - HOLD_MARGIN;
localparam [2:0] SETTLE_CYCLES = 3'd4;

// synthesis translate_off
initial begin
    if ((CHANNELS != 1 && CHANNELS != 2) || FIFO_ADDR_W < 9 || FIFO_ADDR_W > 14 ||
        HOLD_MARGIN < 4 || PREFILL_FRAMES < 1 || PREFILL_FRAMES > HOLD_LEVEL) begin
        $display("AUDIO_CONFIG_ERROR wav_stream_player %m: CHANNELS=%0d FIFO_ADDR_W=%0d PREFILL=%0d HOLD_LEVEL=%0d",
                 CHANNELS, FIFO_ADDR_W, PREFILL_FRAMES, HOLD_LEVEL);
        $finish;
    end
end
// synthesis translate_on

// ---------------- 写侧 ----------------
reg        fifo_rst_wr;
reg [2:0]  settle_wr;
reg [1:0]  byte_count;
reg [7:0]  byte0, byte1, byte2;
reg        we_wr;
reg [31:0] di_wr;
wire       fifo_full;
wire [FIFO_ADDR_W-1:0] fifo_wrusedw;
wire       write_block = fifo_rst_wr || (settle_wr != 3'd0);
wire       frame_last = (byte_count == BYTES_PER_FRAME - 1);
assign hold = write_block || (fifo_wrusedw >= HOLD_LEVEL);

always @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
        fifo_rst_wr <= 1'b1;
        settle_wr <= SETTLE_CYCLES;
        byte_count <= 2'd0;
        byte0 <= 8'd0;
        byte1 <= 8'd0;
        byte2 <= 8'd0;
        we_wr <= 1'b0;
        di_wr <= 32'd0;
        overflow <= 1'b0;
    end else begin
        we_wr <= 1'b0;
        fifo_rst_wr <= stream_flush;
        if (fifo_rst_wr)
            settle_wr <= SETTLE_CYCLES;
        else if (settle_wr != 3'd0)
            settle_wr <= settle_wr - 3'd1;
        if (we_wr && fifo_full)
            overflow <= 1'b1;
        if (stream_flush || stream_restart) begin
            byte_count <= 2'd0;
        end else if (byte_valid) begin
            if (write_block) begin
                overflow <= 1'b1;
            end else if (frame_last) begin
                we_wr <= 1'b1;
                di_wr <= (CHANNELS == 1) ? {byte_data, byte0, byte_data, byte0}
                                         : {byte1, byte0, byte_data, byte2};
                byte_count <= 2'd0;
            end else begin
                case (byte_count)
                    2'd0: byte0 <= byte_data;
                    2'd1: byte1 <= byte_data;
                    default: byte2 <= byte_data;
                endcase
                byte_count <= byte_count + 2'd1;
            end
        end
    end
end

// ---------------- FIFO ----------------
wire        raw_read_en, raw_valid, fifo_empty;
wire [31:0] raw_data;
wire [FIFO_ADDR_W-1:0] fifo_rdusedw;
rfifo_32_32_512 #(
    .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
    .ADDR_WIDTH_W(FIFO_ADDR_W), .ADDR_WIDTH_R(FIFO_ADDR_W),
    .AL_FULL_NUM(DEPTH - 1), .AL_EMPTY_NUM(2),
    .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
) u_fifo (
    .rst(fifo_rst_wr), .clkw(wr_clk), .clkr(rd_clk),
    .we(we_wr), .di(di_wr),
    .re(raw_read_en), .dout(raw_data), .valid(raw_valid),
    .full_flag(fifo_full), .empty_flag(fifo_empty),
    .afull(), .aempty(),
    .wrusedw(fifo_wrusedw), .rdusedw(fifo_rdusedw)
);

// ---------------- 读侧 ----------------
wire rd_local_rst_n;
reset_sync u_rd_reset (.clk(rd_clk), .ext_rst_n(rd_rst_n && !fifo_rst_wr), .rst_n_sync(rd_local_rst_n));
sync_2ff u_active_sync (.clk(rd_clk), .rst_n(rd_rst_n), .async_in(track_active), .sync_out(wav_active));

reg primed;
wire pf_valid;
wire [31:0] pf_data;
wire pop = sample_valid && sample_ready;
// 预填充期间不让预取取数，rdusedw 即缓冲内全部帧数。
fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
    .clk(rd_clk), .rst(!rd_local_rst_n),
    .raw_empty(fifo_empty || !primed), .raw_valid(raw_valid), .raw_data(raw_data),
    .raw_read_en(raw_read_en), .consume(pop),
    .out_valid(pf_valid), .out_empty(), .out_data(pf_data)
);
assign sample_valid = primed && pf_valid;
assign sample_left = pf_data[31:16];
assign sample_right = pf_data[15:0];

always @(posedge rd_clk or negedge rd_local_rst_n) begin
    if (!rd_local_rst_n) begin
        primed <= 1'b0;
        underflow <= 1'b0;
    end else begin
        underflow <= 1'b0;
        if (!primed) begin
            if (fifo_rdusedw >= PREFILL_FRAMES)
                primed <= 1'b1;
        end else if (!pf_valid && fifo_empty && !raw_valid) begin
            primed <= 1'b0;
            underflow <= wav_active;
        end
    end
end
endmodule
