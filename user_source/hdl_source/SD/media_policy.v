// 策略层只解释事件、计算图片顺序，不接触 SPI 或帧写握手。
module media_policy (
    input wire key1_click_event,
    input wire key1_double_event,
    input wire key1_long_event,
    input wire key2_click_event,
    input wire key2_double_event,
    input wire key2_long_event,
    input wire chord_click_event,
    input wire [1:0] img_idx,
    input wire [2:0] img_found_count,
    output wire manual_req,
    output wire manual_prev,
    output wire auto_toggle,
    output reg [1:0] next_idx,
    output reg [1:0] prev_idx,
    output reg [2:0] reserved_events
);
// 组合短按与 KEY1 单击一样请求下一张，沿用执行层的忙时缓存及轮播策略。
assign manual_req = key1_click_event || key2_double_event || key2_long_event || chord_click_event;
// 两个独立按键事件同拍时，上一张优先；组合键由路由层提前互斥。
assign manual_prev = key2_long_event;
assign auto_toggle = key2_click_event;
always @(*) begin
    next_idx = 2'd0;
    prev_idx = 2'd0;
    if (img_found_count > 3'd1) begin
        if (img_found_count >= 3'd4) begin
            next_idx = (img_idx == 2'd3) ? 2'd0 : img_idx + 2'd1;
            prev_idx = (img_idx == 2'd0) ? 2'd3 : img_idx - 2'd1;
        end else begin
            next_idx = ({1'b0, img_idx} >= img_found_count - 3'd1) ? 2'd0 : img_idx + 2'd1;
            prev_idx = (img_idx == 2'd0) ? img_found_count[1:0] - 2'd1 : img_idx - 2'd1;
        end
    end
    reserved_events = 3'b000;
    if (key1_double_event) begin
        // 预留：KEY1 双击的策略处理位置，当前不产生媒体动作。
        reserved_events[0] = 1'b1;
    end
    if (key1_long_event) begin
        // 预留：KEY1 长按的策略处理位置。
        reserved_events[1] = 1'b1;
    end
    // reserved_events[2] 保留接口位，当前为 0；组合短按已映射到 manual_req。
end
endmodule
