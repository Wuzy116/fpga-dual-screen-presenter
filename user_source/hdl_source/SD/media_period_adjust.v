// 控制域周期调节请求源：纯组合计算，接 media_period_config 的 user_* 输入。
// current_period_ms 必须来自配置寄存器，不能接本模块输出；不增加第二份配置状态。
// increase_event/decrease_event 是同域事件，高电平所在的每个采样沿均表示一次请求。
// 工程约定（讲义未规定步长/手势）：默认步长 1000 ms；双向同拍抵消；边界饱和不回绕。
// 未改变数值时不发写请求，避免边界/抵消事件重启轮播计时；非法当前值不擅自修复。
// 配置源保持合法恢复优先：同拍调节可被恢复覆盖，不排队；下一拍以恢复后的值计算。
// 本模块不负责按键映射、消抖、CDC、播放许可或 Flash 保存。
module media_period_adjust #(
    parameter integer STEP_MS = 1000
)(
    input wire rst,
    input wire increase_event, decrease_event,
    input wire [15:0] current_period_ms,
    output reg user_write,
    output reg [15:0] user_period_ms
);
// synthesis translate_off
initial begin
    if (STEP_MS < 1 || STEP_MS > 59000) begin
        $display("MEDIA_CONFIG_ERROR period_adjust %m: step must be 1..59000 ms");
        $finish;
    end
end
// synthesis translate_on
localparam [16:0] STEP_VALUE = STEP_MS;
wire [16:0] increased_ms = {1'b0, current_period_ms} + STEP_VALUE;
always @(*) begin
    user_write = 1'b0;
    user_period_ms = 16'd0;
    if (!rst && current_period_ms >= 16'd1000 && current_period_ms <= 16'd60000) begin
        if (increase_event && !decrease_event && current_period_ms < 16'd60000) begin
            user_write = 1'b1;
            user_period_ms = (increased_ms > 17'd60000) ? 16'd60000 : increased_ms[15:0];
        end else if (decrease_event && !increase_event && current_period_ms > 16'd1000) begin
            user_write = 1'b1;
            user_period_ms = ({1'b0, current_period_ms} < 17'd1000 + STEP_VALUE) ?
                             16'd1000 : current_period_ms - STEP_VALUE[15:0];
        end
    end
end
endmodule
