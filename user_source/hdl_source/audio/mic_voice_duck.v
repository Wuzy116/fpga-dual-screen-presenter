// INMP441 说话检测 + 背景音乐闪避（像素域）：I2S 主机读麦克风左声道 → 高通去低频 → 包络与底噪比较 → talking，
// talking 期间把音乐增益系数 duck_gain 从 255 斜降到 DUCK_LEVEL，结束后斜升回 255。只判断“有没有人在说话”，不做识别。
module mic_voice_duck #(
    parameter integer CLK_HZ      = 25_000_000,
    parameter integer SCK_DIV     = 8,       // SCK = CLK_HZ / SCK_DIV（INMP441 0.5~3.2 MHz），采样率 = SCK / 64
    parameter integer HPF_SHIFT   = 5,       // 一阶高通，fc ≈ fs / (2π·2^N)，N=5 约 240 Hz
    parameter integer ENV_SHIFT   = 8,       // 包络平滑，2^N / fs，约 5 ms
    parameter integer RATIO_SHIFT = 2,       // 说话判据：包络 > 底噪 × 2^N + MIN_ENV
    parameter integer MIN_ENV     = 256,     // 20 位样本刻度的绝对下限（约 -66 dBFS）
    parameter integer ONSET_MS    = 50,      // 连续超过阈值这么久才判为说话
    parameter integer HOLD_MS     = 800,     // 最后一次超过阈值后保持说话状态的时间
    parameter integer WARM_MS     = 1000,    // 上电后底噪快速跟随、不判说话（含麦克风约 85 ms 启动）
    parameter integer SPEAK_HOLD_MS = 300,   // speaking：说话中且最近这么久内超过过阈值（提词屏说话滚动用，比 HOLD 释放快）
    parameter integer ABSENT_MS   = 500,     // 连续这么久样本全为 0（未接麦克风、SD 被下拉）判为不在线
    parameter integer DUCK_LEVEL  = 64,      // 说话时音乐增益（/256），64 ≈ -12 dB
    parameter integer ATTACK_MS   = 100,     // 255 → DUCK_LEVEL 用时
    parameter integer RELEASE_MS  = 1000     // DUCK_LEVEL → 255 用时
)(
    input            clk,
    input            rst_n,
    output           mic_sck,
    output           mic_ws,
    input            mic_sd,
    output           talking,
    output           speaking,
    output           present,
    output     [4:0] env_log,      // 包络 / 说话阈值的最高位位置（20 位样本刻度，约每级 6 dB），电平条用
    output     [4:0] thr_log,
    output     [7:0] duck_gain
);
localparam integer FS = CLK_HZ / (SCK_DIV * 64);
wire               s_valid;
wire signed [19:0] s_data;
mic_i2s_rx #(.SCK_DIV(SCK_DIV)) u_rx (
    .clk(clk), .rst_n(rst_n), .mic_sck(mic_sck), .mic_ws(mic_ws), .mic_sd(mic_sd),
    .sample_valid(s_valid), .sample(s_data)
);
mic_voice_detect #(.FS(FS), .HPF_SHIFT(HPF_SHIFT), .ENV_SHIFT(ENV_SHIFT), .RATIO_SHIFT(RATIO_SHIFT),
    .MIN_ENV(MIN_ENV), .ONSET_MS(ONSET_MS), .HOLD_MS(HOLD_MS), .WARM_MS(WARM_MS),
    .SPEAK_HOLD_MS(SPEAK_HOLD_MS), .ABSENT_MS(ABSENT_MS)) u_detect (
    .clk(clk), .rst_n(rst_n), .sample_valid(s_valid), .sample(s_data),
    .floor_hold(talking || duck_gain != 8'd255), .talking(talking), .speaking(speaking), .present(present),
    .env_log(env_log), .thr_log(thr_log)
);
mic_duck_gain #(.CLK_HZ(CLK_HZ), .DUCK_LEVEL(DUCK_LEVEL), .ATTACK_MS(ATTACK_MS), .RELEASE_MS(RELEASE_MS)) u_gain (
    .clk(clk), .rst_n(rst_n), .talking(talking), .gain(duck_gain)
);
endmodule

// I2S 主机（标准 I2S：WS 在 SCK 下降沿变化，MSB 晚一个 SCK）。L/R 接地，左声道在 WS=0 半帧，右半帧 SD 为高阻。
// SCK 低半周期开始时麦克风换数，FPGA 在 SCK 上升沿那一刻取 SD（经两级同步，故晚两拍读同步值）。
module mic_i2s_rx #(
    parameter integer SCK_DIV = 8        // 偶数且 >= 8：上升沿后两拍取同步值须仍在高半周期内
)(
    input                    clk,
    input                    rst_n,
    output reg               mic_sck,
    output reg               mic_ws,
    input                    mic_sd,
    output reg               sample_valid,
    output reg signed [19:0] sample      // 24 位样本的高 20 位
);
localparam integer HALF = SCK_DIV / 2;
localparam integer CW = $clog2(SCK_DIV);
reg [CW-1:0] div;
reg [5:0]    slot;       // 当前 SCK 周期在 64 位帧中的序号（0..31 左、32..63 右）
wire [5:0]   slot_n = slot + 6'd1;
(* ASYNC_REG="TRUE" *) reg sd_s1, sd_s2;
reg [18:0]   shift;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        div <= 0;
        slot <= 6'd63;
        mic_sck <= 1'b0;
        mic_ws <= 1'b1;
        sd_s1 <= 1'b0;
        sd_s2 <= 1'b0;
        shift <= 19'd0;
        sample_valid <= 1'b0;
        sample <= 20'sd0;
    end else begin
        sd_s1 <= mic_sd;
        sd_s2 <= sd_s1;
        sample_valid <= 1'b0;
        div <= (div == SCK_DIV - 1) ? {CW{1'b0}} : div + 1'b1;
        if (div == HALF - 1)
            mic_sck <= 1'b1;
        if (div == SCK_DIV - 1) begin
            mic_sck <= 1'b0;
            slot <= slot_n;
            mic_ws <= slot_n[5];
        end
        // 上升沿在 div=HALF-1 那一拍发出，两拍同步后在 div=HALF+1 读到该时刻的 SD；左声道 MSB 起在 slot 1..24，只取前 20 位
        if (div == HALF + 1 && slot >= 6'd1 && slot <= 6'd20) begin
            shift <= {shift[17:0], sd_s2};
            if (slot == 6'd20) begin
                sample <= {shift, sd_s2};
                sample_valid <= 1'b1;
            end
        end
    end
end
// synthesis translate_off
initial if (SCK_DIV < 8 || SCK_DIV % 2 != 0) begin
    $display("AUDIO_CONFIG_ERROR %m: SCK_DIV must be even and >= 8");
    $finish;
end
// synthesis translate_on
endmodule

// 说话检测：y = x - LP(x)（一阶高通）→ |y| → 包络 env（一阶平滑）；底噪 floor 低于 env 时慢升、高于时较快降。
// floor_hold（说话或音乐尚未恢复）期间底噪只许极慢上升、不许下降：漏进麦克风的背景音乐被压低时，底噪若跟着降，
// 音乐恢复就会被当成说话而反复闪避；只慢升不冻结，持续的稳定噪声最终仍会并入底噪。
// env > floor·2^RATIO + MIN_ENV 连续 ONSET 判为说话，之后每次超过阈值都重置 HOLD 计时，计时到 0 结束说话。
// speaking = talking 且最近 SPEAK_HOLD 内超过过阈值（起始同样要求连续 ONSET，短促杂音不触发）；present = 最近 ABSENT 内有非零样本。
module mic_voice_detect #(
    parameter integer FS          = 48828,
    parameter integer HPF_SHIFT   = 5,
    parameter integer ENV_SHIFT   = 8,
    parameter integer RATIO_SHIFT = 2,
    parameter integer MIN_ENV     = 256,
    parameter integer ONSET_MS    = 50,
    parameter integer HOLD_MS     = 800,
    parameter integer WARM_MS     = 1000,
    parameter integer SPEAK_HOLD_MS = 300,
    parameter integer ABSENT_MS   = 500
)(
    input                    clk,
    input                    rst_n,
    input                    sample_valid,
    input  signed [19:0]     sample,
    input                    floor_hold,
    output reg               talking,
    output                   speaking,
    output reg               present,
    output reg   [4:0]       env_log,
    output reg   [4:0]       thr_log
);
localparam integer FL_FRAC    = 19;
localparam integer FL_UP      = 17;   // 不说话时底噪上升时间常数 2^17/fs ≈ 2.7 s
localparam integer FL_UP_HOLD = 19;   // floor_hold 期间 ≈ 10.7 s
localparam integer FL_DOWN    = 10;   // 下降 ≈ 21 ms
localparam integer FL_WARM    = 9;    // 预热期双向 ≈ 10 ms
localparam integer ONSET_N = FS * ONSET_MS / 1000;
localparam integer HOLD_N  = FS * HOLD_MS / 1000;
localparam integer WARM_N  = FS * WARM_MS / 1000;
localparam integer ON_W = $clog2(ONSET_N + 1);
localparam integer HD_W = $clog2(HOLD_N + 1);
localparam integer WM_W = $clog2(WARM_N + 1);
localparam integer SPEAK_N  = FS * SPEAK_HOLD_MS / 1000;
localparam integer ABSENT_N = FS * ABSENT_MS / 1000;
localparam integer SP_W = $clog2(SPEAK_N + 1);
localparam integer AB_W = $clog2(ABSENT_N + 1);

function [4:0] msb24(input [23:0] v);   // 最高位 1 的位置，v = 0 时为 0
    integer k;
    begin
        msb24 = 5'd0;
        for (k = 1; k < 24; k = k + 1)
            if (v[k]) msb24 = k;
    end
endfunction

// 累加器恒非负，但声明为有符号，使加负的差值时按符号扩展
reg  signed [20+HPF_SHIFT:0]   lp_acc;      // LP(x) × 2^HPF_SHIFT
reg  signed [21+ENV_SHIFT:0]   env_acc;     // env × 2^ENV_SHIFT
reg  signed [21+FL_FRAC:0]     floor_acc;   // floor × 2^FL_FRAC
reg  [ON_W-1:0] onset_cnt;
reg  [HD_W-1:0] hold_cnt;
reg  [WM_W-1:0] warm_cnt;
reg             warm;
reg  [SP_W-1:0] speak_cnt;
reg  [AB_W-1:0] zero_cnt;

wire signed [20:0] lp  = lp_acc >>> HPF_SHIFT;
wire signed [21:0] hp  = sample - lp;
wire        [21:0] mag = hp[21] ? -hp : hp;
wire        [20:0] mag_c = mag[21] ? 21'h1fffff : mag[20:0];
wire        [20:0] env = env_acc[20+ENV_SHIFT:ENV_SHIFT];
wire        [20:0] flr = floor_acc[20+FL_FRAC:FL_FRAC];
wire signed [22:0] env_d = $signed({2'b00, mag_c}) - $signed({2'b00, env});
wire signed [22:0] fl_d  = $signed({2'b00, env}) - $signed({2'b00, flr});
// D32：阈值为原来的 1.5 倍（floor × 6 + 384，默认参数下），减少台下噪声 / 音乐串入误判
wire        [23:0] thr_b = ({3'b000, flr} << RATIO_SHIFT) + MIN_ENV;
wire        [23:0] thr = thr_b + (thr_b >> 1);
wire               above = {3'b000, env} > thr;
wire [4:0]         fl_shift = warm ? FL_WARM : fl_d[22] ? FL_DOWN : floor_hold ? FL_UP_HOLD : FL_UP;
wire signed [21+FL_FRAC:0] fl_step = (!warm && fl_d[22] && floor_hold) ? 0 : $signed(fl_d) <<< (FL_FRAC - fl_shift);
assign speaking = talking && speak_cnt != 0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lp_acc <= 0;
        env_acc <= 0;
        floor_acc <= 0;
        onset_cnt <= 0;
        hold_cnt <= 0;
        warm_cnt <= 0;
        warm <= 1'b1;
        talking <= 1'b0;
        speak_cnt <= 0;
        zero_cnt <= 0;
        present <= 1'b0;
        env_log <= 5'd0;
        thr_log <= 5'd0;
    end else if (sample_valid) begin
        env_log <= msb24({3'b000, env});
        thr_log <= msb24(thr);
        if (sample != 0) begin
            zero_cnt <= 0;
            present <= 1'b1;
        end else if (zero_cnt == ABSENT_N - 1)
            present <= 1'b0;
        else
            zero_cnt <= zero_cnt + 1'b1;
        if (!warm && above)
            speak_cnt <= SPEAK_N;
        else if (speak_cnt != 0)
            speak_cnt <= speak_cnt - 1'b1;
        lp_acc <= lp_acc + (sample - lp);
        env_acc <= env_acc + env_d;
        floor_acc <= floor_acc + fl_step;
        if (warm) begin
            if (warm_cnt == WARM_N - 1) warm <= 1'b0;
            warm_cnt <= warm_cnt + 1'b1;
        end
        if (warm || !above)
            onset_cnt <= 0;
        else if (onset_cnt != ONSET_N)
            onset_cnt <= onset_cnt + 1'b1;
        if (!talking) begin
            if (!warm && above && onset_cnt == ONSET_N - 1) begin
                talking <= 1'b1;
                hold_cnt <= HOLD_N;
            end
        end else if (above)
            hold_cnt <= HOLD_N;
        else if (hold_cnt == 0)
            talking <= 1'b0;
        else
            hold_cnt <= hold_cnt - 1'b1;
    end
end
// synthesis translate_off
initial if (FS < 8000 || ONSET_N < 2 || HOLD_N < 1 || WARM_N < 2 || RATIO_SHIFT > 3 || MIN_ENV < 1 ||
             SPEAK_N < 1 || SPEAK_N > HOLD_N || ABSENT_N < 2) begin
    $display("AUDIO_CONFIG_ERROR %m: invalid voice detect parameters");
    $finish;
end
// synthesis translate_on
endmodule

// 闪避增益：talking 时每 DOWN_CYC 拍减 1 直到 DUCK_LEVEL，否则每 UP_CYC 拍加 1 直到 255（线性斜坡，无乘法）。
module mic_duck_gain #(
    parameter integer CLK_HZ     = 25_000_000,
    parameter integer DUCK_LEVEL = 64,
    parameter integer ATTACK_MS  = 100,
    parameter integer RELEASE_MS = 1000
)(
    input            clk,
    input            rst_n,
    input            talking,
    output reg [7:0] gain
);
localparam integer STEPS   = 255 - DUCK_LEVEL;
localparam integer DOWN_CYC = (CLK_HZ / 1000) * ATTACK_MS / STEPS;
localparam integer UP_CYC   = (CLK_HZ / 1000) * RELEASE_MS / STEPS;
localparam integer TW = $clog2((DOWN_CYC > UP_CYC ? DOWN_CYC : UP_CYC) + 1);
reg [TW-1:0] tick;
wire [TW-1:0] period = talking ? DOWN_CYC - 1 : UP_CYC - 1;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tick <= 0;
        gain <= 8'd255;
    end else if (talking ? gain == DUCK_LEVEL : gain == 8'd255) begin
        tick <= 0;
    end else if (tick >= period) begin
        tick <= 0;
        gain <= talking ? gain - 8'd1 : gain + 8'd1;
    end else
        tick <= tick + 1'b1;
end
// synthesis translate_off
initial if (DUCK_LEVEL < 0 || DUCK_LEVEL > 254 || DOWN_CYC < 1 || UP_CYC < 1) begin
    $display("AUDIO_CONFIG_ERROR %m: invalid duck gain parameters");
    $finish;
end
// synthesis translate_on
endmodule
