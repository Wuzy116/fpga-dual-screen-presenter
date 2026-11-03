// 控制域音量调节请求源；与 media_period_adjust 保持相同事件契约。
// current_volume 来自唯一配置寄存器，不接本模块输出，不新增音量状态。
// 工程约定（讲义未规定步长）：默认每次1级，可配置为1..255级。
// 增减同拍抵消，边界饱和不回绕；数值未变化时不发写请求。
// 同域事件高电平的每个采样沿代表一次调节，不在本层做消抖或边沿检测。
// 配置源保持恢复优先，同拍调节被覆盖且不排队，下一拍按恢复后的值计算。
// 本模块不映射按键、不判断启动就绪、不做 CDC，也不触发 Flash 保存。
module media_volume_adjust #(
    parameter integer STEP = 1
)(
    input wire rst,
    input wire increase_event, decrease_event,
    input wire [7:0] current_volume,
    output reg user_write,
    output reg [7:0] user_volume
);
// synthesis translate_off
initial begin
    if (STEP < 1 || STEP > 255) begin
        $display("MEDIA_CONFIG_ERROR volume_adjust %m: step must be 1..255");
        $finish;
    end
end
// synthesis translate_on
localparam [8:0] STEP_VALUE = STEP;
wire [8:0] increased_volume = {1'b0, current_volume} + STEP_VALUE;
always @(*) begin
    user_write = 1'b0;
    user_volume = 8'd0;
    if (!rst) begin
        if (increase_event && !decrease_event && current_volume < 8'd255) begin
            user_write = 1'b1;
            user_volume = (increased_volume > 9'd255) ? 8'd255 : increased_volume[7:0];
        end else if (decrease_event && !increase_event && current_volume > 8'd0) begin
            user_write = 1'b1;
            user_volume = ({1'b0, current_volume} < STEP_VALUE) ?
                          8'd0 : current_volume - STEP_VALUE[7:0];
        end
    end
end
endmodule
