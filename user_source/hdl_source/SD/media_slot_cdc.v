// 单笔槽号邮箱；生产顶层可选预加载通路使用，默认旧通路不实例化。
// 源域仅在 src_valid && src_ready 的上升沿受理，忙时不受理、不覆盖、不自动排队。
// 需要保留请求的调用者必须保持 valid/slot 至受理；持续 valid 可在每次 ready 时再次提交。
// rst 是两域共同的异步高有效复位源，内部各自两拍同步释放；不支持只复位单域。
// 复位丢弃在途提交，目标槽回到 0；复位前已显示/尚未显示的语义由上层统一处理。
// SLOT_W 可加宽以随槽号携带附加标志（例如转场类型），整笔经同一握手跨域。
module media_slot_cdc #(
    parameter integer SLOT_W = 2
) (
    input wire src_clk, dst_clk, rst,
    input wire [SLOT_W-1:0] src_slot,
    input wire src_valid,
    output wire src_ready,
    output reg [SLOT_W-1:0] dst_slot,
    output reg dst_update
);
wire src_rst_n, dst_rst_n;
wire request_dst, acknowledge_src;
reg request, acknowledge;
reg [SLOT_W-1:0] held_slot;
reset_sync u_src_reset(.clk(src_clk),.ext_rst_n(!rst),.rst_n_sync(src_rst_n));
reset_sync u_dst_reset(.clk(dst_clk),.ext_rst_n(!rst),.rst_n_sync(dst_rst_n));
sync_2ff u_request_sync(.clk(dst_clk),.rst_n(dst_rst_n),
    .async_in(request),.sync_out(request_dst));
sync_2ff u_ack_sync(.clk(src_clk),.rst_n(src_rst_n),
    .async_in(acknowledge),.sync_out(acknowledge_src));
assign src_ready = !rst && src_rst_n && (request == acknowledge_src);

always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
        request <= 1'b0;
        held_slot <= {SLOT_W{1'b0}};
    end else if (src_valid && src_ready) begin
        held_slot <= src_slot;
        request <= !request;
    end
end
always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
        acknowledge <= 1'b0;
        dst_slot <= {SLOT_W{1'b0}};
        dst_update <= 1'b0;
    end else begin
        dst_update <= 1'b0;
        if (request_dst != acknowledge) begin
            // 只同步单比特请求；两拍同步后整笔采样稳定数据，源端保持至确认返回。
            // 此确认仅表示槽号已送达，不表示 reader 已发请求或该图片已显示。
            dst_slot <= held_slot;
            dst_update <= 1'b1;
            acknowledge <= request_dst;
        end
    end
end
endmodule
