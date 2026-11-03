`timescale 1ns/1ps

// D30 观众屏图片层特效（像素域，作用在亮度/对比度之后、二维码/文字层之前；输出与输入同拍，不改时序）。
// 位置相关的判定按“下一个像素”的坐标提前一拍寄存，同拍组合只剩抠色比较、移位/饱和加法与选择。
//   闪光：add = sat(光晕 + flash_w)，光晕以 (GX,GY) 为心、八边形距离 d = max + min/2，d < glow_r 时 (glow_r - d)*8 饱和到 255；
//     各通道 sat(x + add)（白色叠加）。
//   充电：电池格子区 (CX0..CX1, CY0..CY1) 内、按原图像素抠出的青绿色（g >= 128 且 g - r >= 32）中，列 >= fill_x 的压暗为 x/4，
//     前沿左侧 8 列 +80；box_w != 0 时整块电池 (BX0..BX1, BY0..BY1) 的青绿像素 +box_w。闪电（黄）不受影响。
//   抖动（水平）：reader 把整行按 shake_dx 循环移位（同 bank 两段），回绕进来的 |dx| 列在这里用边缘像素填：
//     dx > 0（内容右移）缺口为 x < dx，填上一行第 dx 列；dx < 0 缺口为 x >= 640+dx，填本行第 639+dx 列。shake_dx 为本帧锁存值。
module media_fx_pixel #(
    parameter integer H_ACTIVE = 640,
    parameter integer GX = 240, GY = 282,
    parameter integer CX0 = 186, CX1 = 436, CY0 = 106, CY1 = 194,
    parameter integer BX0 = 170, BX1 = 466, BY0 = 90,  BY1 = 210
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire [11:0]       x,          // 当前像素在有效区内的坐标（有效区外为回绕大值）
    input  wire [11:0]       y,
    input  wire              de,
    input  wire [23:0]       key_rgb,    // 原图像素（抠色用）
    input  wire [23:0]       rgb_in,
    input  wire signed [4:0] shake_dx,
    input  wire [7:0]        flash_w,
    input  wire [6:0]        glow_r,
    input  wire              charge_on,
    input  wire [9:0]        fill_x,
    input  wire [7:0]        box_w,
    output wire [23:0]       rgb_out
);
    wire [11:0] nx = x + 12'd1;
    wire [11:0] adx = (nx > GX) ? nx - GX : GX - nx;
    wire [11:0] ady = (y > GY) ? y - GY : GY - y;
    wire [11:0] dmax = (adx > ady) ? adx : ady;
    wire [11:0] dmin = (adx > ady) ? ady : adx;
    wire [12:0] oct_d = {1'b0, dmax} + {2'b0, dmin[11:1]};
    wire [12:0] glow_gap = {6'd0, glow_r} - oct_d;          // 仅 oct_d < glow_r 时使用
    wire [7:0]  glow = (oct_d >= {6'd0, glow_r}) ? 8'd0 : (glow_gap[12:5] != 0) ? 8'd255 : {glow_gap[4:0], 3'd0};
    wire [8:0]  flash_sum = {1'b0, glow} + {1'b0, flash_w};
    wire in_cells = charge_on && nx >= CX0 && nx <= CX1 && y >= CY0 && y <= CY1;
    wire in_box   = box_w != 8'd0 && nx >= BX0 && nx <= BX1 && y >= BY0 && y <= BY1;
    wire dim_n    = in_cells && nx >= {2'b0, fill_x};
    wire edge_n   = in_cells && !dim_n && fill_x <= CX1 && nx + 12'd8 >= {2'b0, fill_x};
    wire [8:0] bat_sum = (edge_n ? 9'd80 : 9'd0) + (in_box ? {1'b0, box_w} : 9'd0);
    wire [9:0] l1 = shake_dx[4] ? H_ACTIVE + {{5{shake_dx[4]}}, shake_dx} : {5'd0, shake_dx};
    wire gap_n   = shake_dx != 5'sd0 && (shake_dx[4] ? nx >= {2'b0, l1} && nx < H_ACTIVE : nx < {2'b0, l1});
    wire latch_n = shake_dx != 5'sd0 && nx == (shake_dx[4] ? {2'b0, l1} - 12'd1 : {2'b0, l1});

    reg [7:0] add_q, bat_q;
    reg       dim_q, gap_q, latch_q;
    reg [23:0] edge_rgb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_q <= 8'd0; bat_q <= 8'd0; dim_q <= 1'b0; gap_q <= 1'b0; latch_q <= 1'b0;
        end else begin
            add_q <= flash_sum[8] ? 8'd255 : flash_sum[7:0];
            bat_q <= bat_sum[8] ? 8'd255 : bat_sum[7:0];
            dim_q <= dim_n;
            gap_q <= gap_n;
            latch_q <= latch_n;
        end
    end

    wire [8:0] key_diff = {1'b0, key_rgb[15:8]} - {1'b0, key_rgb[23:16]};
    wire key = key_rgb[15] && !key_diff[8] && key_diff[7:5] != 3'd0;
    wire [7:0] add = add_q | (key ? bat_q : 8'd0);   // 闪光与充电不会同时非零
    function [7:0] fx;
        input [7:0] c;
        input [7:0] a;
        input       d;
        reg [8:0] s;
        begin
            s = {1'b0, c} + {1'b0, a};
            fx = d ? {2'b00, c[7:2]} : s[8] ? 8'hff : s[7:0];
        end
    endfunction
    wire dim = dim_q && key;
    wire [23:0] fx_rgb = {fx(rgb_in[23:16], add, dim), fx(rgb_in[15:8], add, dim), fx(rgb_in[7:0], add, dim)};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) edge_rgb <= 24'd0;
        else if (de && latch_q) edge_rgb <= fx_rgb;
    end
    assign rgb_out = !de ? rgb_in : gap_q ? edge_rgb : fx_rgb;
endmodule
