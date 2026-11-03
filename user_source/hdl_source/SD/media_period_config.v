// 控制域周期配置源；rst 与消费者共用异步置位、同步释放的控制域复位。
// 输入已在 clk 域同步，write 高的每拍都是一次请求；本模块不做 CDC/消抖/Flash 校验。
// 讲义规定默认 5000 ms、范围 1000..60000 ms；下列仲裁是本工程的接口约定：
// 合法恢复 > 合法用户写入 > 复位后首次默认发布；非法请求不阻挡另一路合法请求。
// restore_write 由未来已完成有效性校验的恢复流程发出，不等于原始 Flash 数据有效。
// 复位清 update；释放后首拍发布默认值，若该拍有合法写入则只发布选中的写入值。
// period_ms 是当前配置；period_update 与数据成对寄存，消费者在下一沿采样。
// 同值写入也发布，连续请求允许连续高；空闲不重复发布，不排队、不自动保存。
// 不处理播放许可/故障；轮播器保留其故障优先/锁停语义，恢复依靠共同复位。
module media_period_config #(
    parameter integer DEFAULT_PERIOD_MS = 5000
)(
    input wire clk, rst,
    input wire restore_write,
    input wire [15:0] restore_period_ms,
    input wire user_write,
    input wire [15:0] user_period_ms,
    output reg period_update,
    output reg [15:0] period_ms
);
// synthesis translate_off
initial begin
    if (DEFAULT_PERIOD_MS < 1000 || DEFAULT_PERIOD_MS > 60000) begin
        $display("MEDIA_CONFIG_ERROR period_config %m: default period must be 1000..60000 ms");
        $finish;
    end
end
// synthesis translate_on
reg initial_publish;
wire restore_valid = restore_write && restore_period_ms >= 16'd1000 && restore_period_ms <= 16'd60000;
wire user_valid = user_write && user_period_ms >= 16'd1000 && user_period_ms <= 16'd60000;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        period_ms <= DEFAULT_PERIOD_MS;
        period_update <= 1'b0;
        initial_publish <= 1'b1;
    end else begin
        initial_publish <= 1'b0;
        period_update <= 1'b0;
        if (restore_valid) begin
            period_ms <= restore_period_ms;
            period_update <= 1'b1;
        end else if (user_valid) begin
            period_ms <= user_period_ms;
            period_update <= 1'b1;
        end else if (initial_publish) begin
            period_update <= 1'b1;
        end
    end
end
endmodule
