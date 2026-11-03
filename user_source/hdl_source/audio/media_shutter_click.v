`timescale 1ns/1ps

// D30 相机快门“咔嚓”（音频样本域，与像素同一 video_clk）：start 单拍后按样本握手 fire 推进，共 T_END 个样本（48.8 kHz 下约 170 ms）。
//   “咔”：第 0 个样本起，噪声（16 位 LFSR 经一阶低通）× 3/4，每 256 个样本衰减一半（右移 0..9 位），约 52 ms 后静音；
//   “嚓”：第 B_START 个样本起再来一次，每 512 个样本衰减一半，更长更软。不用乘法器。
// 幅度上限 3/4 满幅：active 期间混音器把背景音乐降到 1/4 再叠加本模块输出，和不会溢出（D31 板测：原 1/2 幅度被音乐盖住）。
module media_shutter_click #(
    parameter integer B_START = 3072,
    parameter integer T_END   = 8192
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire               fire,
    output reg                active,
    output wire signed [15:0] sample
);
    localparam [3:0] OFF = 4'd15;
    reg [12:0] t;
    reg [15:0] lfsr;
    reg signed [15:0] lp;
    wire        in_b = t >= B_START;
    wire [12:0] tb = t - B_START;
    wire [3:0]  sh_a = (t[12:8] >= 5'd10) ? OFF : t[11:8];
    wire [3:0]  sh_b = (tb[12:9] >= 4'd10) ? OFF : tb[12:9];
    wire signed [16:0] lp_diff = $signed({lfsr[15], lfsr}) - $signed({lp[15], lp});
    wire signed [16:0] lp_next = $signed({lp[15], lp}) + (lp_diff >>> 1);
    wire [3:0]  sh = in_b ? sh_b : sh_a;
    wire signed [15:0] lp_s = lp >>> sh;
    wire signed [15:0] shaped = (lp_s >>> 1) + (lp_s >>> 2);
    assign sample = (active && sh != OFF) ? shaped : 16'sd0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 1'b0; t <= 13'd0; lfsr <= 16'hace1; lp <= 16'sd0;
        end else if (start) begin
            active <= 1'b1; t <= 13'd0;
        end else if (active && fire) begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            lp <= lp_next[15:0];
            if (t == T_END - 1) active <= 1'b0;
            t <= t + 13'd1;
        end
    end
endmodule
