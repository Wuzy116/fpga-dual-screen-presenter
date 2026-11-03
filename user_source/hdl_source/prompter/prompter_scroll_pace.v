// 提词屏连续滚动速度（D18，像素域）：滚完一整页（480 行）用 period_s * SLOW 秒（D24：SLOW=4，周期 5 s 时一页约 20 s）。
// 帧率 25 MHz / (800*525) = 59.524 Hz，每帧应走 480 / (59.524 * p * SLOW) 行。累加器每帧 +1032/SLOW（1032 = 8.064*128），
// 每够 p*128 出一行（Bresenham，
// 长期无漂移）。frame_start 后逐拍减（最多 10 拍）算出下一帧要走的行数，rows_q4 = 行数*16（Q4，接 window_ctrl）。
// run=0 时累加器清零、速度为 0。period_s=0 按 1 秒处理。
module prompter_scroll_pace #(
    parameter integer SLOW = 4
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_start,
    input  wire       run,
    input  wire [6:0] period_s,
    output reg  [7:0] rows_q4
);
    localparam [15:0] STEP = 1032 / SLOW;
    // synthesis translate_off
    initial if (SLOW < 1 || (1032 % SLOW) != 0) begin $display("PROMPTER_CONFIG_ERROR %m: SLOW must divide 1032"); $finish; end
    // synthesis translate_on
    wire [6:0]  p = (period_s == 7'd0) ? 7'd1 : period_s;
    wire [15:0] d = {2'b00, p, 7'd0};
    reg  [15:0] acc;
    reg  [3:0]  cnt;
    reg         busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 16'd0; cnt <= 4'd0; busy <= 1'b0; rows_q4 <= 8'd0;
        end else if (!run) begin
            acc <= 16'd0; cnt <= 4'd0; busy <= 1'b0; rows_q4 <= 8'd0;
        end else if (frame_start) begin
            acc <= acc + STEP; cnt <= 4'd0; busy <= 1'b1;
        end else if (busy) begin
            if (acc >= d) begin acc <= acc - d; cnt <= cnt + 4'd1; end
            else begin busy <= 1'b0; rows_q4 <= {cnt, 4'd0}; end
        end
    end
endmodule
