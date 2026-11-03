`timescale 1ns/1ps

// 第 13 课缩略图：旁听 media_frame_loader 的写流，按讲义最近邻 4:1 取样（source = local * 4）生成总览页，
// 写入第 6 个 bank（基址 5 * IMAGE_WORDS）。D19 起 3×2 网格居中：图 k 在第 k%3 列、第 k/3 行，格子左上角为
// (W/8 + (k%3)*W/4, H/4 + (k/3)*H/4)，格内 (lx, ly) 取主图屏幕坐标 (4lx, 4ly) 的像素；
// 总览页其余区域不写（显示侧按 image_complete 遮黑）。
// 主图每行列号递增，翻转时行号递减，故每个缩略图行的 W/4 个字地址连续；按 BURST 字攒满后单独发 burst，
// W/4 须为 BURST 的整数倍，且 BURST 为 4 的倍数（控制器 4 字组）。
// start 与 loader 接受新帧同拍；cancel 期间不再收取，进行中的 burst 写完后清空队列。
module media_thumb_writer #(
    parameter integer ADDR_WIDTH   = 21,
    parameter integer IMAGE_WORDS  = 307200,
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer BURST        = 32,
    parameter integer DEPTH        = 64
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    input  wire                  start_vflip,
    input  wire [2:0]            start_image,
    input  wire                  cancel,
    input  wire                  tap_valid,
    input  wire [31:0]           tap_data,
    input  wire                  burst_hold,
    output wire                  burst_request,
    output wire                  burst_idle,
    output wire                  empty,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [31:0]           app_wr_data,
    output reg                   overflow
);
    localparam integer AW = $clog2(DEPTH);
    localparam integer TW = FRAME_WIDTH / 4;
    localparam integer TH = FRAME_HEIGHT / 4;
    localparam [ADDR_WIDTH-1:0] SHEET_BASE = IMAGE_WORDS * 5;
    // synthesis translate_off
    initial begin
        if ((TW % BURST) != 0 || (BURST % 4) != 0 || BURST > DEPTH / 2 || (DEPTH & (DEPTH - 1)) != 0 ||
            (FRAME_WIDTH % 32) != 0 || IMAGE_WORDS * 6 > (1 << ADDR_WIDTH)) begin
            $display("MEDIA_CONFIG_ERROR media_thumb_writer %m: W/4 must be whole bursts of 4-word groups and sheet must fit");
            $finish;
        end
    end
    // synthesis translate_on

    reg [9:0]  col;
    reg [11:0] row;
    reg        vflip;
    reg [2:0]  image;
    wire       take = tap_valid && !cancel && row[1:0] == 2'b00 && col[1:0] == 2'b00;
    reg  [ADDR_WIDTH-1:0] cell_base;
    always @* begin
        case (image)
            3'd0: cell_base = SHEET_BASE + TH * FRAME_WIDTH + TW / 2;
            3'd1: cell_base = SHEET_BASE + TH * FRAME_WIDTH + TW / 2 + TW;
            3'd2: cell_base = SHEET_BASE + TH * FRAME_WIDTH + TW / 2 + 2 * TW;
            3'd3: cell_base = SHEET_BASE + 2 * TH * FRAME_WIDTH + TW / 2;
            default: cell_base = SHEET_BASE + 2 * TH * FRAME_WIDTH + TW / 2 + TW;
        endcase
    end
    wire [ADDR_WIDTH-1:0] thumb_addr = cell_base + (row >> 2) * FRAME_WIDTH + (col >> 2);

    reg [ADDR_WIDTH+31:0] mem [0:DEPTH-1];
    reg [AW-1:0] wp, rp;
    reg [AW:0]   cnt;
    reg          active;
    reg [7:0]    remaining;
    wire         pop = active;
    wire         start_burst = !active && !cancel && cnt >= BURST && !burst_hold;
    // 块 RAM 寄存读：按下一拍的 rp 预取队头。burst 只在队列已有 >= BURST 字时开始，
    // 出队地址永远落后入队地址至少一个字，不会读到同拍写入的项。
    wire         flush = (cancel || start) && !active && !start_burst;
    wire [AW-1:0] rd_addr = flush ? {AW{1'b0}} : pop ? rp + 1'b1 : rp;
    reg  [ADDR_WIDTH+31:0] mem_q;
    assign burst_request = !active && !cancel && cnt >= BURST;
    assign burst_idle = !active && !app_wr_en;
    assign empty = (cnt == 0);

    always @(posedge clk) begin
        if (take) mem[wp] <= {thumb_addr, tap_data};
        mem_q <= mem[rd_addr];
    end
    // synthesis translate_off
    reg [AW-1:0] rd_addr_q;
    reg rd_check;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_check <= 1'b0;
        else begin
            rd_addr_q <= rd_addr;
            rd_check <= 1'b1;
            if (rd_check && rd_addr_q !== rp) begin
                $display("FATAL: %m read-address predictor %0d != rp %0d", rd_addr_q, rp);
                $finish;
            end
            if (pop && take && wp == rd_addr) begin
                $display("FATAL: %m prefetch reads the slot being written");
                $finish;
            end
        end
    end
    // synthesis translate_on

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col <= 10'd0; row <= 12'd0; vflip <= 1'b0; image <= 3'd0;
            wp <= {AW{1'b0}}; rp <= {AW{1'b0}}; cnt <= {(AW+1){1'b0}};
            active <= 1'b0; remaining <= 8'd0; overflow <= 1'b0;
            app_wr_en <= 1'b0; app_wr_addr <= {ADDR_WIDTH{1'b0}}; app_wr_data <= 32'd0;
        end else begin
            app_wr_en <= 1'b0;
            if (start) begin
                col <= 10'd0;
                row <= start_vflip ? FRAME_HEIGHT - 1 : 12'd0;
                vflip <= start_vflip;
                image <= start_image;
                overflow <= 1'b0;
            end else if (tap_valid && !cancel) begin
                if (col == FRAME_WIDTH - 1) begin
                    col <= 10'd0;
                    row <= vflip ? row - 1'b1 : row + 1'b1;
                end else begin
                    col <= col + 1'b1;
                end
            end
            if (take && cnt[AW]) overflow <= 1'b1;
            if (take && !cnt[AW]) wp <= wp + 1'b1;
            if (pop) begin
                app_wr_en <= 1'b1;
                {app_wr_addr, app_wr_data} <= mem_q;
                rp <= rp + 1'b1;
                if (remaining == 8'd1) active <= 1'b0;
                remaining <= remaining - 1'b1;
            end
            case ({take && !cnt[AW], pop})
                2'b10: cnt <= cnt + 1'b1;
                2'b01: cnt <= cnt - 1'b1;
                default: ;
            endcase
            if (start_burst) begin
                active <= 1'b1;
                remaining <= BURST;
            end
            // 取消或新帧：进行中的 burst 写完后丢弃残余（不足一个 burst 的半行）
            if (flush) begin
                wp <= {AW{1'b0}}; rp <= {AW{1'b0}}; cnt <= {(AW+1){1'b0}};
            end
        end
    end
endmodule
