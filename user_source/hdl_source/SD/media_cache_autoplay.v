// 缓存轮播请求仲裁；全部输入属于 clk 域，跨域反馈/故障同步由外层负责。
// step_req/step_prev 同拍交给 media_cache_select，desired_slot 接回其目标槽。
// 初次 enable 只启动选槽器，忽略同拍按键；此前事件不缓存，轮播默认关闭。
// 故障或启动后撤销 enable 均锁停至共同复位。反馈不是故障门控或逐帧 ACK。
// 只在收到的有效显示槽等于目标槽时计时；首次有效/换槽先采样，再等完整周期。
// 同槽刷新不清零；手动优先到期，toggle 同拍屏蔽自动请求但不屏蔽手动请求。
// 状态反馈可合并：这里衡量收到状态后的驻留时间，不承诺物理画面精确驻留时长。
// 可选运行时周期：同域 period_update 高电平所在沿采样 period_ms (1000..60000)。
// WAIT_ENABLE/RUN 可更新；合法更新含同值写入均重新计时并屏蔽同拍自动请求，
// 不屏蔽手动/toggle；非法值、故障/锁停时更新忽略。持续拉高会持续重计时。
// 默认关闭接口，保持静态周期/计数位宽；共同复位恢复 AUTO_PERIOD_MS。
// ENABLE_PAUSE=1：pause 高时不计时、不发自动请求（手动请求照常），撤销后重新计完整周期。
module media_cache_autoplay #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer AUTO_PERIOD_MS = 1000,
    parameter integer ENABLE_RUNTIME_PERIOD = 0,
    parameter integer ENABLE_PAUSE = 0
)(
    input wire clk, rst,
    input wire player_enable, playback_fault,
    input wire mode_ready, mode_value,
    input wire manual_req, manual_prev, auto_toggle,
    input wire display_valid,
    input wire [2:0] display_slot, desired_slot,
    output wire step_req, step_prev,
    output wire auto_play_en, stopped,
    input wire period_update,
    input wire [15:0] period_ms,
    input wire pause,
    // 强制轮播（暖场阶段，D17）：为 1 时按开启处理，不改变 KEY3 / Flash 记录的 enabled
    input wire force_on
);
wire paused = ENABLE_PAUSE && pause;
localparam [63:0] PERIOD_RAW = 64'd1 * (CLK_FREQ_HZ / 1000) * AUTO_PERIOD_MS;
localparam [63:0] PERIOD_CYCLES = (PERIOD_RAW > 0) ? PERIOD_RAW : 64'd1;
localparam [63:0] MAX_RUNTIME_CYCLES = 64'd1 * (CLK_FREQ_HZ / 1000) * 60000;
localparam integer COUNTER_BITS = ENABLE_RUNTIME_PERIOD ? 32 :
                                 ((PERIOD_CYCLES <= 1) ? 1 : $clog2(PERIOD_CYCLES));
// synthesis translate_off
initial begin
    if (CLK_FREQ_HZ < 1000 || (CLK_FREQ_HZ % 1000) != 0 || AUTO_PERIOD_MS < 1 ||
        PERIOD_RAW > 64'd4294967295 ||
        (ENABLE_RUNTIME_PERIOD != 0 && ENABLE_RUNTIME_PERIOD != 1) ||
        (ENABLE_RUNTIME_PERIOD && (AUTO_PERIOD_MS < 1000 || AUTO_PERIOD_MS > 60000 ||
                                  MAX_RUNTIME_CYCLES > 64'd4294967295))) begin
        $display("MEDIA_CONFIG_ERROR cache_autoplay %m: invalid clock/period or cycle-count overflow");
        $finish;
    end
end
// synthesis translate_on
localparam WAIT_ENABLE=2'd0, RUN=2'd1, STOPPED=2'd2;
reg [1:0] state;
reg enabled, display_seen;
reg [2:0] last_display_slot;
reg mode_applied;
reg [COUNTER_BITS-1:0] auto_count;
wire period_accept = ENABLE_RUNTIME_PERIOD && period_update &&
                     period_ms >= 16'd1000 && period_ms <= 16'd60000 &&
                     !rst && !playback_fault &&
                     (state == WAIT_ENABLE || (state == RUN && player_enable));
wire [31:0] period_cycles;
generate if (ENABLE_RUNTIME_PERIOD) begin : g_runtime_period
    reg [31:0] cycles;
    wire [63:0] requested_cycles = 64'd1 * (CLK_FREQ_HZ / 1000) * period_ms;
    always @(posedge clk or posedge rst) begin
        if (rst) cycles <= PERIOD_CYCLES[31:0];
        else if (period_accept) cycles <= requested_cycles[31:0];
    end
    assign period_cycles = cycles;
end else begin : g_static_period
    assign period_cycles = PERIOD_CYCLES[31:0];
end endgenerate
wire active = !rst && player_enable && !playback_fault && state == RUN;
wire display_matches = display_valid && display_seen &&
                       display_slot == last_display_slot && display_slot == desired_slot;
wire run_auto = enabled || force_on;
wire auto_due = run_auto && !paused && !auto_toggle && !period_accept && display_matches &&
                auto_count == period_cycles - 1'b1;
assign step_req = active && (manual_req || auto_due);
assign step_prev = step_req && manual_req && manual_prev;
assign auto_play_en = active && run_auto;
assign stopped = state == STOPPED;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= WAIT_ENABLE;
        enabled <= 1'b0;
        mode_applied <= 1'b0;
        display_seen <= 1'b0;
        last_display_slot <= 3'd0;
        auto_count <= 0;
    end else if (playback_fault || (state == RUN && !player_enable)) begin
        state <= STOPPED;
        enabled <= 1'b0;
        mode_applied <= 1'b0;
        display_seen <= 1'b0;
        auto_count <= 0;
    end else begin
        if (mode_ready && !mode_applied) begin
            enabled <= mode_value;
            mode_applied <= 1'b1;
            auto_count <= 0;
        end
        case (state)
            WAIT_ENABLE: if (player_enable) state <= RUN;
            RUN: begin
                if (auto_toggle) enabled <= ~enabled;
                display_seen <= display_valid;
                if (display_valid) last_display_slot <= display_slot;
                if (!run_auto || paused || auto_toggle || manual_req || period_accept || !display_matches || step_req)
                    auto_count <= 0;
                else if (auto_count < period_cycles - 1'b1)
                    auto_count <= auto_count + 1'b1;
            end
            default: begin
                state <= STOPPED;
                enabled <= 1'b0;
                display_seen <= 1'b0;
                auto_count <= 0;
            end
        endcase
    end
end
endmodule
