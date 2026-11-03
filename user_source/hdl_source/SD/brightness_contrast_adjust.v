`timescale 1ns/1ps
// 第 14 课亮度/对比度（讲义 3.2 同名模块）：B、C 均以 128 为原图，再叠加第 10 课淡入淡出 alpha。
// 讲义级联式 y = sat(alpha/256 * sat((sat(x*B/128) - 128) * C/128 + 128)) 合并成每通道一次乘法：
//   y = clamp((x <= XM ? x*G : PSAT) >> 14 + OFF, 0, U)
//   a = fading ? alpha : 256（总览页同样淡变），K = C*a，G = B*K>>8，OFF = (128a - K)>>>8，
//   PSAT = 255K/2（亮度级饱和到 255 时的乘积），U = 255a>>8，XM = 32767/B（亮度级不饱和的最大 x）。
// 默认 B=C=128 且不淡出时逐位透传；B=C=128 淡出时与原转场 x*alpha>>8 逐位一致；
// 只调亮度或只调对比度时与讲义参考答案逐位一致；两者同时调时比级联写法最多大 2 LSB（少一次中间取整）。
// B/C 在 frame_start 锁存；系数由帧内恒定的输入连续寄存，除法 15 拍完成，均在场消隐内稳定。
// 像素输出为同拍组合逻辑，不改变 hs/vs/de 对齐。
// 低功耗：系数恰为恒等（G=16384、OFF=0、XM=255；穷举可知此时 U 必为 255）时直接输出原像素，
// 乘法器输入置 0 不再翻转；恒等时 x*16384>>14 = x，结果逐位相同。
module brightness_contrast_adjust (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire [7:0]  alpha,
    input  wire        fading,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    reg [7:0] b_q, c_q;
    reg       div_busy;
    reg [3:0] div_cnt;
    reg [8:0] div_rem;
    reg [7:0] div_quo;
    reg       div_quo_big;
    reg [7:0] xm_q;

    reg [8:0]  a_q;
    reg [16:0] k_q;
    reg [15:0] g_q;
    reg signed [9:0] off_q;
    reg [23:0] psat_q;
    reg [7:0]  u_q;

    wire [8:0] a_next = fading ? {1'b0, alpha} : 9'd256;
    wire [24:0] bk = b_q * k_q;
    wire signed [17:0] off_full = $signed({1'b0, a_q, 7'd0}) - $signed({1'b0, k_q});
    wire [24:0] psat_full = {k_q, 8'd0} - {8'd0, k_q};
    wire [9:0] div_shift = {div_rem, 1'b1};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_q <= 8'd128;
            c_q <= 8'd128;
            div_busy <= 1'b0;
            div_cnt <= 4'd0;
            div_rem <= 9'd0;
            div_quo <= 8'd0;
            div_quo_big <= 1'b0;
            xm_q <= 8'd255;
        end else begin
            if (frame_start) begin
                b_q <= brightness;
                c_q <= contrast;
                div_busy <= 1'b1;
                div_cnt <= 4'd14;
                div_rem <= 9'd0;
                div_quo <= 8'd0;
                div_quo_big <= 1'b0;
            end else if (div_busy) begin
                // 恢复除法 32767 / b_q：被除数全 1，每拍移入一个 1。商超过 255 即饱和。
                if (div_shift >= {2'b00, b_q}) begin
                    div_rem <= div_shift - {2'b00, b_q};
                    {div_quo_big, div_quo} <= {div_quo_big | div_quo[7], div_quo[6:0], 1'b1};
                end else begin
                    div_rem <= div_shift[8:0];
                    {div_quo_big, div_quo} <= {div_quo_big | div_quo[7], div_quo[6:0], 1'b0};
                end
                if (div_cnt == 4'd0) begin
                    div_busy <= 1'b0;
                    xm_q <= (div_quo_big || div_quo[7]) ? 8'd255 :
                            {div_quo[6:0], div_shift >= {2'b00, b_q}};
                end else begin
                    div_cnt <= div_cnt - 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_q <= 9'd256;
            k_q <= 17'd32768;
            g_q <= 16'd16384;
            off_q <= 10'sd0;
            psat_q <= 24'd4177920;
            u_q <= 8'd255;
        end else begin
            a_q <= a_next;
            k_q <= c_q * a_q;
            g_q <= bk[23:8];
            off_q <= off_full >>> 8;
            psat_q <= psat_full[24:1];
            u_q <= (a_q == 9'd256) ? 8'd255 : (a_q == 9'd0) ? 8'd0 : a_q[7:0] - 8'd1;
        end
    end

    // 系数作为参数传入：连续赋值只对函数实参敏感，不能在函数体内读模块寄存器。
    function [7:0] adjust_channel;
        input [7:0] x;
        input [7:0] xm;
        input [23:0] psat;
        input [15:0] g;
        input signed [9:0] off;
        input [7:0] u;
        reg [23:0] prod;
        reg signed [11:0] z;
        begin
            prod = (x > xm) ? psat : x * g;
            z = $signed({2'b00, prod[23:14]}) + off;
            if (z[11])
                adjust_channel = 8'd0;
            else if (z[10:0] > {3'b000, u})
                adjust_channel = u;
            else
                adjust_channel = z[7:0];
        end
    endfunction

    reg identity_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) identity_q <= 1'b1;
        else        identity_q <= (g_q == 16'd16384) && (off_q == 10'sd0) && (xm_q == 8'd255);
    end
    wire [23:0] x_in = identity_q ? 24'd0 : rgb_in;
    wire [23:0] adj = {adjust_channel(x_in[23:16], xm_q, psat_q, g_q, off_q, u_q),
                       adjust_channel(x_in[15:8],  xm_q, psat_q, g_q, off_q, u_q),
                       adjust_channel(x_in[7:0],   xm_q, psat_q, g_q, off_q, u_q)};
    assign rgb_out = identity_q ? rgb_in : adj;
endmodule
