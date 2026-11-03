// 单槽 req/ack 状态邮箱：传输期间锁住整组数据，不逐位同步图片 ID。
// rst 必须同时复位两域；各域内部异步置位、同步释放。快速变化合并为最新状态，非事件 FIFO。
// ID_W：媒体 ID 位宽（默认 2；预加载显示反馈用 3 位槽号，D19）。
module audio_media_cdc #(parameter integer ID_W = 2) (
    input wire src_clk, dst_clk, rst,
    input wire [ID_W-1:0] src_media_id,
    input wire src_media_valid,
    output reg [ID_W-1:0] dst_media_id,
    output reg dst_media_valid,
    output reg dst_update
);
(* ASYNC_REG="TRUE" *) reg [1:0] src_reset_sync, dst_reset_sync;
(* ASYNC_REG="TRUE" *) reg [1:0] req_sync, ack_sync;
reg req, ack, sent;
reg [ID_W:0] held_data;
wire src_rst=src_reset_sync[1];
wire dst_rst=dst_reset_sync[1];
always @(posedge src_clk or posedge rst)
    if(rst) src_reset_sync<=2'b11;
    else src_reset_sync<={src_reset_sync[0],1'b0};
always @(posedge dst_clk or posedge rst)
    if(rst) dst_reset_sync<=2'b11;
    else dst_reset_sync<={dst_reset_sync[0],1'b0};
always @(posedge src_clk or posedge src_rst) begin
    if(src_rst) begin ack_sync<=0; req<=0; sent<=0; held_data<=0; end
    else begin
        ack_sync<={ack_sync[0],ack};
        if(req==ack_sync[1] && (!sent || held_data!={src_media_valid,src_media_id})) begin
            held_data<={src_media_valid,src_media_id};
            req<=~req;
            sent<=1;
        end
    end
end
always @(posedge dst_clk or posedge dst_rst) begin
    if(dst_rst) begin
        req_sync<=0; ack<=0; dst_media_id<=0; dst_media_valid<=0; dst_update<=0;
    end else begin
        req_sync<={req_sync[0],req};
        dst_update<=0;
        if(req_sync[1]!=ack) begin
            // 请求经两拍同步后再采样，held_data 在整个往返握手期间保持不变。
            {dst_media_valid,dst_media_id}<=held_data;
            dst_update<=1;
            ack<=req_sync[1];
        end
    end
end
endmodule
