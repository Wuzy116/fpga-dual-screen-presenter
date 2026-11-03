// 播放模式控制：mode=0 手动，mode=1 自动。
// 所有输入均属于同一控制时钟域；Flash 恢复结果必须先经过外部有效性校验。
// 启动完成前只接收恢复结果，不接受 KEY2；boot_config_done 所在沿发布最终模式。
// 启动完成后只接受 KEY2 切换，忽略迟到恢复，避免运行中被 Flash 数据覆盖。
// restore_write 与 boot_config_done 同拍时恢复优先；本模块不做消抖、CDC 或自动保存。
module media_mode_control (
    input  wire clk,
    input  wire rst,
    input  wire restore_write,
    input  wire restore_mode,
    input  wire boot_config_done,
    input  wire key2_toggle,
    output reg  mode_update,
    output reg  mode,
    output reg  mode_ready,
    output reg  restore_accept,
    output reg  key2_accept
);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        mode <= 1'b0;
        mode_update <= 1'b0;
        mode_ready <= 1'b0;
        restore_accept <= 1'b0;
        key2_accept <= 1'b0;
    end else begin
        mode_update <= 1'b0;
        restore_accept <= 1'b0;
        key2_accept <= 1'b0;
        if (!mode_ready) begin
            if (restore_write) begin
                mode <= restore_mode;
                restore_accept <= 1'b1;
            end
            if (boot_config_done) begin
                mode_ready <= 1'b1;
                mode_update <= 1'b1;
            end
        end else if (key2_toggle) begin
            mode <= ~mode;
            mode_update <= 1'b1;
            key2_accept <= 1'b1;
        end
    end
end
endmodule
