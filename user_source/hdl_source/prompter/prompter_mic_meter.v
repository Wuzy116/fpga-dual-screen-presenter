// 提词屏话筒电平条（像素域，组合叠加、零延迟，hs/vs/de 不经过本模块）：
// 底框 168x16 黑底，左边 12x12 方块在 speaking（讲稿会随说话滚动）时为青色，否则深灰；
// 右边 SEGS 格，每格 10 像素宽、间隔 2，第 i 格在包络位置 env_log >= LOG_BASE + i 时点亮（约每格 6 dB），
// 前 8 格绿、2 格黄、其余红；说话阈值 thr_log 对应的那一格左侧画 2 像素白线。enable=0（麦克风不在线）时整块不画。
// 显示值在场同步下降沿锁存：电平取上一帧内的峰值，回落每 DECAY_FRAMES 帧一格。
// D32 滚动状态方块：电平条右侧隔 2 像素、12x12（与电平条同行），mode_auto 绿色、mode_voice 蓝色，都为 0 时不画；与 enable 无关。
module prompter_mic_meter #(
    parameter integer X0 = 56,
    parameter integer Y0 = 8,
    parameter integer SEGS = 12,
    parameter integer LOG_BASE = 6,     // 包络 >= 2^6（约 -78 dBFS）亮第 1 格
    parameter integer DECAY_FRAMES = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        speaking,
    input  wire        mode_auto,
    input  wire        mode_voice,
    input  wire [4:0]  env_log,
    input  wire [4:0]  thr_log,
    input  wire        vs_in,      // 低有效；坐标由 de/vs 推出
    input  wire        de_in,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    localparam integer BOX_W = 20 + 12 * SEGS - 2 + 6;   // 默认 168
    localparam integer SEG_X0 = X0 + 20;
    localparam [23:0] C_BOX = 24'h000000, C_OFF = 24'h303030, C_IND_OFF = 24'h404040, C_IND_ON = 24'h00e0ff,
                      C_GREEN = 24'h40ff40, C_YELLOW = 24'hffd400, C_RED = 24'hff3030, C_TICK = 24'hffffff,
                      C_AUTO = 24'h30e050, C_VOICE = 24'h3080ff;
    localparam integer SQ_X0 = X0 + BOX_W + 2;

    function [4:0] segs_of(input [4:0] l);
        segs_of = (l < LOG_BASE) ? 5'd0 : (l - LOG_BASE + 1 > SEGS) ? SEGS : l - LOG_BASE + 1;
    endfunction

    // 当前像素坐标：x 在 de 期间逐拍加 1，y 在 de 下降沿加 1、场同步期间清零
    reg [9:0] x;
    reg [8:0] y;
    reg       de_q, vs_q;
    reg [3:0] sx;            // 当前像素在本格内的列 0..11（x >= SEG_X0 时有效）
    reg [4:0] si;            // 当前像素所在格号
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 10'd0; y <= 9'd0; de_q <= 1'b0; vs_q <= 1'b1; sx <= 4'd0; si <= 5'd0;
        end else begin
            de_q <= de_in;
            vs_q <= vs_in;
            if (!vs_in) y <= 9'd0;
            else if (de_q && !de_in) y <= y + 9'd1;
            if (!de_in) x <= 10'd0;
            else begin
                x <= x + 10'd1;
                if (x + 10'd1 == SEG_X0) begin sx <= 4'd0; si <= 5'd0; end
                else if (sx == 4'd11) begin sx <= 4'd0; si <= si + 5'd1; end
                else sx <= sx + 4'd1;
            end
        end
    end

    // 帧锁存：峰值保持 + 缓慢回落
    reg [4:0] peak, lvl, thr_seg;
    reg [1:0] decay;
    reg       en_f, spk_f, auto_f, voice_f;
    wire [4:0] now = segs_of(env_log);
    wire       frame_edge = vs_q && !vs_in;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            peak <= 5'd0; lvl <= 5'd0; thr_seg <= 5'd0; decay <= 2'd0; en_f <= 1'b0; spk_f <= 1'b0;
            auto_f <= 1'b0; voice_f <= 1'b0;
        end else if (frame_edge) begin
            peak <= now;
            en_f <= enable;
            spk_f <= speaking;
            auto_f <= mode_auto;
            voice_f <= mode_voice;
            thr_seg <= (thr_log < LOG_BASE) ? 5'd0 : (thr_log - LOG_BASE >= SEGS) ? SEGS - 1 : thr_log - LOG_BASE;
            decay <= (decay == DECAY_FRAMES - 1) ? 2'd0 : decay + 2'd1;
            if (peak >= lvl) lvl <= peak;
            else if (decay == DECAY_FRAMES - 1) lvl <= lvl - 5'd1;
        end else if (now > peak)
            peak <= now;
    end

    wire [8:0] ry = y - Y0;
    wire       in_box = de_in && x >= X0 && x < X0 + BOX_W && y >= Y0 && y < Y0 + 16;
    wire       in_row = ry >= 9'd2 && ry < 9'd14;
    wire       ind    = in_row && x < X0 + 12;
    wire       seg    = in_row && x >= SEG_X0 && si < SEGS && sx < 4'd10;
    wire       tick   = (thr_seg == 5'd0) ? (x == SEG_X0 - 2 || x == SEG_X0 - 1)
                                          : (x >= SEG_X0 && si == thr_seg - 5'd1 && sx >= 4'd10);
    wire [23:0] seg_on = (si < 5'd8) ? C_GREEN : (si < 5'd10) ? C_YELLOW : C_RED;
    wire [23:0] meter_rgb = tick ? C_TICK : ind ? (spk_f ? C_IND_ON : C_IND_OFF) :
                            seg ? ((si < lvl) ? seg_on : C_OFF) : C_BOX;
    wire       in_sq  = de_in && in_row && y >= Y0 && y < Y0 + 16 && x >= SQ_X0 && x < SQ_X0 + 12;
    assign rgb_out = (in_sq && auto_f) ? C_AUTO : (in_sq && voice_f) ? C_VOICE :
                     (en_f && in_box) ? meter_rgb : rgb_in;

    // synthesis translate_off
    initial if (SEGS < 1 || SEGS > 16 || DECAY_FRAMES < 1 || DECAY_FRAMES > 4 || LOG_BASE < 0 || LOG_BASE > 20) begin
        $display("PROMPTER_CONFIG_ERROR %m: SEGS 1..16, DECAY_FRAMES 1..4, LOG_BASE 0..20");
        $finish;
    end
    // synthesis translate_on
endmodule
