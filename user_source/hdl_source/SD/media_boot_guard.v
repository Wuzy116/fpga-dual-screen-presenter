// 启动屏障：所有输入/输出均属于 clk 域；不负责 CDC 或生成额外上电延时。
// preload_done/image_complete 来自已确认写排空的预加载控制器，完成后须保持至复位。
// startup_error 为外层汇总的启动错误；错误及完成协议异常锁存，只有统一复位可解除。
// 首张即显示：槽 0 写排空完成且此前无错误即开放播放，其余槽在后台继续加载。
// 开放前的任何错误都阻止播放；开放后的加载错误只锁存 boot_error、停止后续加载，
// 已完成的槽继续播放（降级）。完成协议异常（已完成位撤销/越界/完成时缺槽）仍撤销播放。
// player_enable 不能直接跨域驱动 HDMI。
module media_boot_guard (
    input wire clk,
    input wire rst,
    input wire preload_done,
    input wire [4:0] image_complete,
    // 目录实际张数 1..5：只允许前 N 槽完成；0 或越界不能放行。须在首张完成前稳定。
    input wire [2:0] slot_count,
    input wire startup_error,
    output reg player_enable,
    output reg boot_error
);
wire [4:0] expected_mask = (slot_count == 3'd1) ? 5'b00001 :
                           (slot_count == 3'd2) ? 5'b00011 :
                           (slot_count == 3'd3) ? 5'b00111 :
                           (slot_count == 3'd4) ? 5'b01111 :
                           (slot_count == 3'd5) ? 5'b11111 : 5'b00000;
wire all_complete = (expected_mask != 5'b00000) && (image_complete == expected_mask);
// 槽按 0..N-1 顺序装入，完成位必须是期望掩码内的前缀
wire prefix_ok = (image_complete == 5'b00000) || (image_complete == 5'b00001) ||
                 (image_complete == 5'b00011) || (image_complete == 5'b00111) ||
                 (image_complete == 5'b01111) || (image_complete == 5'b11111);
wire mask_ok = prefix_ok && ((image_complete & ~expected_mask) == 5'b00000);
wire first_ready = (expected_mask != 5'b00000) && image_complete[0] && mask_ok;
reg done_seen;
// 完成时缺槽、完成位越界/非前缀、已开放后槽 0 完成位撤销，或 done 撤销，都不是正常启动
wire completion_error = (preload_done && !all_complete) || !mask_ok ||
                        (player_enable && !image_complete[0]) || (done_seen && !preload_done);
always @(posedge clk or posedge rst) begin
    if (rst) done_seen <= 1'b0;
    else if (preload_done) done_seen <= 1'b1;
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        player_enable <= 1'b0;
        boot_error <= 1'b0;
    end else if (completion_error) begin
        player_enable <= 1'b0;
        boot_error <= 1'b1;
    end else if (startup_error) begin
        // 开放后的加载错误降级：保持播放许可，只锁存错误
        boot_error <= 1'b1;
    end else if (!player_enable) begin
        // 错误优先，不能用后续成功覆盖；这里只增加寄存器采样，不加等待计数。
        player_enable <= !boot_error && first_ready;
    end
end
endmodule
