// 控制域音量配置源；输入已同步，rst 与消费者共用异步置位/同步释放的控制域复位。
// 讲义规定默认 255、范围 0..255；8 位输入的全部确定值均合法，不另做夹限。
// restore_write 只能来自已校验的恢复流程，不等同于原始 Flash 数据有效。
// 工程仲裁与周期配置一致：恢复 > 用户写入 > 复位后首次默认发布。
// 写入高的每拍均接纳，同值也发布；连续请求可使 volume_update 连续高。
// volume 与 volume_update 成对寄存；同域消费者下一沿采样，不做 CDC 或音频幅度运算。
// 空闲保持音量、不重复发布；复位清 update，释放后首次发布默认或该拍选中的写入。
// 本模块不映射按键、不排队、不触发保存；运行时写入不会自动写 Flash。
module media_volume_config #(
    parameter integer DEFAULT_VOLUME = 255
)(
    input wire clk, rst,
    input wire restore_write,
    input wire [7:0] restore_volume,
    input wire user_write,
    input wire [7:0] user_volume,
    output reg volume_update,
    output reg [7:0] volume
);
// synthesis translate_off
initial begin
    if (DEFAULT_VOLUME < 0 || DEFAULT_VOLUME > 255) begin
        $display("MEDIA_CONFIG_ERROR volume_config %m: default volume must be 0..255");
        $finish;
    end
end
// synthesis translate_on
reg initial_publish;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        volume <= DEFAULT_VOLUME;
        volume_update <= 1'b0;
        initial_publish <= 1'b1;
    end else begin
        initial_publish <= 1'b0;
        volume_update <= 1'b0;
        if (restore_write) begin
            volume <= restore_volume;
            volume_update <= 1'b1;
        end else if (user_write) begin
            volume <= user_volume;
            volume_update <= 1'b1;
        end else if (initial_publish) begin
            volume_update <= 1'b1;
        end
    end
end
endmodule
