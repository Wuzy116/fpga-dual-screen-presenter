`timescale 1ns/1ps

// 第 13 课缩略图布局（讲义 thumbnail_layout.v 修正版，纯组合）。D19 起为 3×2 网格（COLS×ROWS），左上为格 0，
// 按行编号 0 1 2 / 3 4 5；只有格号 < CELLS 的格子有图（CELLS=5 时第 6 格恒黑）。格内且该图已加载才 thumb_de=1，
// 焦点格最外 BORDER 圈为 focus_border。source_x/y 为讲义的最近邻源坐标（local * 缩小倍数）；本工程缩略图已在加载时
// 写成总览页，显示侧只用 thumb_de/边框。pending_de = 格内但该图未加载（显示侧画加载占位），cell_edge = 有图格的最外 BORDER 圈。
module thumbnail_layout #(
    parameter integer DISPLAY_WIDTH  = 640,
    parameter integer DISPLAY_HEIGHT = 480,
    parameter integer THUMB_WIDTH    = 160,
    parameter integer THUMB_HEIGHT   = 120,
    parameter integer BORDER         = 2,
    parameter integer COLS           = 3,
    parameter integer ROWS           = 2,
    parameter integer CELLS          = 5
) (
    input  wire        in_de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [2:0]  focus_index,
    input  wire [4:0]  image_complete,
    output reg         thumb_de,
    output reg  [2:0]  source_index,
    output reg  [9:0]  source_x,
    output reg  [9:0]  source_y,
    output reg         focus_border,
    output reg         pending_de,
    output reg         cell_edge
);
    localparam integer SX = DISPLAY_WIDTH / THUMB_WIDTH;
    localparam integer SY = DISPLAY_HEIGHT / THUMB_HEIGHT;
    // synthesis translate_off
    initial begin
        if (COLS < 1 || COLS > 3 || ROWS < 1 || ROWS > 2 || CELLS < 1 || CELLS > COLS * ROWS || CELLS > 5) begin
            $display("MEDIA_CONFIG_ERROR thumbnail_layout %m: COLS 1..3, ROWS 1..2, CELLS 1..min(COLS*ROWS,5)");
            $finish;
        end
    end
    // synthesis translate_on
    reg [1:0]  col;
    reg        row;
    reg [11:0] local_x, local_y;
    always @* begin
        thumb_de = 1'b0;
        source_index = 3'd0;
        source_x = 10'd0;
        source_y = 10'd0;
        focus_border = 1'b0;
        pending_de = 1'b0;
        cell_edge = 1'b0;
        col = (pixel_x >= 2 * THUMB_WIDTH) ? 2'd2 : (pixel_x >= THUMB_WIDTH) ? 2'd1 : 2'd0;
        row = (pixel_y >= THUMB_HEIGHT);
        local_x = pixel_x - col * THUMB_WIDTH;
        local_y = row ? pixel_y - THUMB_HEIGHT : pixel_y;
        if (in_de && pixel_x < COLS * THUMB_WIDTH && pixel_y < ROWS * THUMB_HEIGHT &&
            row * COLS + col < CELLS) begin
            source_index = row * COLS + col;
            cell_edge = local_x < BORDER || local_y < BORDER ||
                        local_x >= THUMB_WIDTH - BORDER || local_y >= THUMB_HEIGHT - BORDER;
            if (image_complete[source_index]) begin
                thumb_de = 1'b1;
                source_x = local_x * SX;
                source_y = local_y * SY;
                focus_border = (source_index == focus_index) && cell_edge;
            end else begin
                pending_de = 1'b1;
            end
        end
    end
endmodule
