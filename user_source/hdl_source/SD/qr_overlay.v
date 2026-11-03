`timescale 1ns/1ps

// 观众屏二维码叠加（D21，纯组合）：有效区坐标 (x, y) 落在 (X0, Y0) 起 132x132 的方框内时 hit=1，
// 方框 = 4 模块白色静区 + 25x25 模块（qr_rom），每模块 SCALE x SCALE 像素；dark=1 画黑，否则画白。
module qr_overlay #(
    parameter integer X0 = 500,
    parameter integer Y0 = 248,
    parameter integer SCALE = 4
) (
    input  wire        enable,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    output wire        hit,
    output wire        dark
);
    localparam integer QUIET = 4;
    localparam integer SIDE = (25 + 2 * QUIET) * SCALE;
    wire [11:0] qx = x - X0;                     // 方框外为回绕大值
    wire [11:0] qy = y - Y0;
    assign hit = enable && de && qx < SIDE && qy < SIDE;
    wire [5:0]  col = qx / SCALE;
    wire [5:0]  row = qy / SCALE;
    wire [5:0]  mx = col - QUIET;
    wire [5:0]  my = row - QUIET;
    wire        in_code = mx < 6'd25 && my < 6'd25;
    wire [24:0] bits;
    qr_rom u_rom (.row(my[4:0]), .bits(bits));
    assign dark = hit && in_code && bits[5'd24 - mx[4:0]];
endmodule
