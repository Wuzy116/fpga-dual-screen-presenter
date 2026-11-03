// 像素域最近一次实际帧提交状态；用于生产顶层的可选预加载通路。
// 所有输入属于 pix_clk，pix_rst_n 须异步置位、同步释放并与 reader 同源。
// frame_slot_pix 必须接 reader 的事务槽，不得接 desired_slot 或 CDC 的实时选择。
// playback_ok_pix 应为播放许可且 reader 未锁停/报错；撤销优先于 frame_started。
// 在采到 frame_started 的沿更新（比 reader 注册该脉冲晚一拍，仍在垂直消隐）。
// valid 表示本复位代次、当前许可下曾提交过画面，不表示 DE 或整帧已成功输出。
// 正常帧间消隐/预填充保留最近已提交槽；后续请求、ACK、ready、选槽均不得更新它。
// 许可撤销立即屏蔽输出，采到撤销后清除历史；再次许可须等新的实际帧提交。
module media_display_state (
    input wire pix_clk, pix_rst_n,
    input wire playback_ok_pix,
    input wire frame_started,
    input wire [2:0] frame_slot_pix,
    output wire display_valid_pix,
    output wire [2:0] display_slot_pix
);
reg committed_valid;
reg [2:0] committed_slot;
assign display_valid_pix = pix_rst_n && playback_ok_pix && committed_valid;
assign display_slot_pix = display_valid_pix ? committed_slot : 3'd0;
always @(posedge pix_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
        committed_valid <= 1'b0;
        committed_slot <= 3'd0;
    end else if (!playback_ok_pix) begin
        committed_valid <= 1'b0;
        committed_slot <= 3'd0;
    end else if (frame_started) begin
        committed_valid <= 1'b1;
        committed_slot <= frame_slot_pix;
    end
end
endmodule
