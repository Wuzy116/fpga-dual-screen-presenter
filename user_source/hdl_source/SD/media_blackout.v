`timescale 1ns/1ps

// 观众屏黑场（D21，像素域）：black=1 时亮度级 level 从 16 每 STEP_FRAMES 帧减 1 到 0（全黑），black=0 时同样逐级回到 16。
// level 只在 frame_start 变化，整帧一致。D24 起不再逐像素相乘：图片层淡变并入 brightness_contrast_adjust 的 alpha
//   （alpha_out = alpha_in * level / 16），叠加层（字幕 / 二维码 / 波形）在 active=1（level != 16）时由顶层隐藏；
//   音频增益 gain_out = gain_in * level / 16 与画面同步淡变。level=16 时两路都原样透传。
module media_blackout #(
    parameter integer STEP_FRAMES = 2
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire        black,
    input  wire [7:0]  alpha_in,
    output wire [7:0]  alpha_out,
    input  wire [7:0]  gain_in,
    output wire [7:0]  gain_out,
    output wire        active,
    output reg  [4:0]  level
);
    reg [1:0] div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level <= 5'd16; div <= 2'd0;
        end else if (frame_start) begin
            if ((black && level == 5'd0) || (!black && level == 5'd16)) div <= 2'd0;
            else if (div == STEP_FRAMES - 1) begin
                div <= 2'd0;
                level <= black ? level - 5'd1 : level + 5'd1;
            end else div <= div + 2'd1;
        end
    end
    // c * level / 16，level 0..16：按 level 的位做移位相加（level=16 时等于 c）
    function [7:0] scale;
        input [7:0] c;
        input [4:0] l;
        reg [12:0] p;
        begin
            p = (l[4] ? {c, 4'd0} : 13'd0) + (l[3] ? {1'b0, c, 3'd0} : 13'd0) + (l[2] ? {2'b0, c, 2'd0} : 13'd0) +
                (l[1] ? {3'b0, c, 1'b0} : 13'd0) + (l[0] ? {5'b0, c} : 13'd0);
            scale = p[11:4];
        end
    endfunction
    assign active = (level != 5'd16);
    assign alpha_out = scale(alpha_in, level);
    assign gain_out = scale(gain_in, level);
    // synthesis translate_off
    initial if (STEP_FRAMES < 1 || STEP_FRAMES > 4) begin
        $display("MEDIA_CONFIG_ERROR %m: STEP_FRAMES 1..4");
        $finish;
    end
    // synthesis translate_on
endmodule
