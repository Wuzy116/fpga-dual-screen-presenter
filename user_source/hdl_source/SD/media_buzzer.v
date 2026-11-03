`timescale 1ns/1ps

// 板载蜂鸣器提示音（D23，控制域）。板上 BUZZER（H11）低电平响、高电平静音，SW5 为硬件静音开关。
// 事件（单拍）对应的提示音，新事件打断正在播放的提示音：
//   ev_click  ：短“嘀” 1 声（时期切换）
//   ev_double ：短“嘀嘀” 2 声（演讲剩 1 分钟）
//   ev_triple ：短“嘀嘀嘀” 3 声（演讲超时）
//   ev_long   ：长“嘀” 1 声（参数保存成功）
//   ev_reveal ：“叮——咚”高低两音（价格揭晓）
// 发声时输出 TONE_HZ 方波（50% 占空比），兼容无源与有源蜂鸣器；TONE_HZ=0 时持续低电平（仅有源）。
module media_buzzer #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer TONE_HZ = 2700,
    parameter integer SHORT_MS = 80,
    parameter integer LONG_MS  = 300,
    parameter integer GAP_MS   = 80
) (
    input  wire clk,
    input  wire rst,
    input  wire ev_click,
    input  wire ev_double,
    input  wire ev_triple,
    input  wire ev_long,
    input  wire ev_reveal,
    output wire buzzer_n
);
    localparam integer MS = CLK_HZ / 1000;
    localparam integer HALF_HI = (TONE_HZ == 0) ? 1 : CLK_HZ / (2 * TONE_HZ);
    localparam integer HALF_LO = (TONE_HZ == 0) ? 1 : CLK_HZ / (2 * TONE_HZ * 3 / 4);   // “咚” = 3/4 音高
    // synthesis translate_off
    initial if (CLK_HZ < 1000 || SHORT_MS < 1 || LONG_MS < 1 || GAP_MS < 1 || TONE_HZ < 0 || TONE_HZ * 2 > CLK_HZ) begin
        $display("MEDIA_CONFIG_ERROR media_buzzer %m: bad timing parameters");
        $finish;
    end
    // synthesis translate_on

    // 播放序列：最多 3 段发声，每段 {时长 ms, 低音}，段间 GAP_MS 静音
    reg [1:0]  segs_left;      // 还剩几段（含当前段）
    reg        on;             // 1 = 发声段，0 = 段间静音
    reg [8:0]  seg_ms;         // 当前段时长
    reg        seg_low;        // 当前段用低音
    reg        next_low;       // 下一段用低音（叮咚）
    reg [8:0]  next_ms;
    reg [8:0]  ms_left;
    // tick 不超过 MS-1，half 不超过较长半周期 - 1
    localparam integer HALF_MAX = (HALF_LO > HALF_HI) ? HALF_LO : HALF_HI;
    localparam integer TICK_W = (MS <= 2) ? 1 : $clog2(MS);
    localparam integer HALF_W = (HALF_MAX <= 2) ? 1 : $clog2(HALF_MAX);
    reg [TICK_W-1:0] tick;     // 1 ms 分频
    reg [HALF_W-1:0] half;     // 方波半周期计数
    reg        wave;

    wire start = ev_click || ev_double || ev_triple || ev_long || ev_reveal;
    wire ms_tick = (tick == MS - 1);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            segs_left <= 2'd0; on <= 1'b0; seg_ms <= 9'd0; seg_low <= 1'b0; next_low <= 1'b0; next_ms <= 9'd0;
            ms_left <= 9'd0; tick <= 0; half <= 0; wave <= 1'b0;
        end else if (start) begin
            // 优先级：揭晓 > 保存 > 超时 > 1 分钟 > 时期切换（同拍多个事件只放一种）
            on <= 1'b1; tick <= 0; half <= 0; wave <= 1'b0;
            if (ev_reveal) begin
                segs_left <= 2'd2; seg_ms <= 9'd150; seg_low <= 1'b0; next_ms <= 9'd300; next_low <= 1'b1; ms_left <= 9'd150;
            end else if (ev_long) begin
                segs_left <= 2'd1; seg_ms <= LONG_MS; seg_low <= 1'b0; next_ms <= LONG_MS; next_low <= 1'b0; ms_left <= LONG_MS;
            end else begin
                segs_left <= ev_triple ? 2'd3 : ev_double ? 2'd2 : 2'd1;
                seg_ms <= SHORT_MS; seg_low <= 1'b0; next_ms <= SHORT_MS; next_low <= 1'b0; ms_left <= SHORT_MS;
            end
        end else if (segs_left != 2'd0) begin
            tick <= ms_tick ? 0 : tick + 1'b1;
            if (on) begin
                if (half == ((seg_low ? HALF_LO : HALF_HI) - 1)) begin half <= 0; wave <= !wave; end
                else half <= half + 1'b1;
            end
            if (ms_tick) begin
                if (ms_left != 9'd1) ms_left <= ms_left - 9'd1;
                else if (on) begin
                    // 发声段结束：还有下一段则进入段间静音，否则结束
                    on <= 1'b0; wave <= 1'b0; half <= 0;
                    if (segs_left == 2'd1) segs_left <= 2'd0;
                    else ms_left <= GAP_MS;
                end else begin
                    // 段间静音结束：开始下一段
                    on <= 1'b1; segs_left <= segs_left - 2'd1;
                    seg_ms <= next_ms; seg_low <= next_low; ms_left <= next_ms;
                end
            end
        end
    end
    wire sounding = (segs_left != 2'd0) && on && ((TONE_HZ == 0) || wave);
    assign buzzer_n = !sounding;
endmodule
