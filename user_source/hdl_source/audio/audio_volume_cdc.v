// 八位音量状态邮箱：只同步 req/ack 单比特，整组 held_volume 保持至确认返回。
// src_volume 是源域持续有效的配置寄存器，不是单拍数据；不需要 volume_update 脉冲。
// 忙时不覆盖在途数据；确认后若当前值不同，再发最新值。中间变化合并，非事件 FIFO。
// rst 必须同时复位两域；内部异步置位、各自两级同步释放，不支持单域独立复位。
// 复位取消在途状态，目标立即回 DEFAULT_VOLUME；源释放后即使等于默认也发布一次。
// 上游配置源与消费者须同源复位，DEFAULT_VOLUME 应与配置源一致。
// 数字仿真不证明物理 CDC；接入时仍须检查同步器布局和 held_volume 整组数据路径约束。
module audio_volume_cdc #(
    parameter integer DEFAULT_VOLUME = 255
)(
    input wire src_clk, dst_clk, rst,
    input wire [7:0] src_volume,
    output reg [7:0] dst_volume,
    output reg dst_update
);
// synthesis translate_off
initial begin
    if (DEFAULT_VOLUME < 0 || DEFAULT_VOLUME > 255) begin
        $display("AUDIO_VOLUME_CDC_ERROR %m: default volume must be 0..255");
        $finish;
    end
end
// synthesis translate_on
wire src_rst_n, dst_rst_n;
wire request_dst, acknowledge_src;
reg request, acknowledge, sent;
reg [7:0] held_volume;
reset_sync u_src_reset(.clk(src_clk),.ext_rst_n(!rst),.rst_n_sync(src_rst_n));
reset_sync u_dst_reset(.clk(dst_clk),.ext_rst_n(!rst),.rst_n_sync(dst_rst_n));
sync_2ff u_request_sync(.clk(dst_clk),.rst_n(dst_rst_n),
    .async_in(request),.sync_out(request_dst));
sync_2ff u_ack_sync(.clk(src_clk),.rst_n(src_rst_n),
    .async_in(acknowledge),.sync_out(acknowledge_src));
always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
        request <= 1'b0;
        sent <= 1'b0;
        held_volume <= DEFAULT_VOLUME;
    end else if (request == acknowledge_src && (!sent || held_volume != src_volume)) begin
        held_volume <= src_volume;
        request <= !request;
        sent <= 1'b1;
    end
end
always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
        acknowledge <= 1'b0;
        dst_volume <= DEFAULT_VOLUME;
        dst_update <= 1'b0;
    end else begin
        dst_update <= 1'b0;
        if (request_dst != acknowledge) begin
            dst_volume <= held_volume;
            dst_update <= 1'b1;
            acknowledge <= request_dst;
        end
    end
end
endmodule
