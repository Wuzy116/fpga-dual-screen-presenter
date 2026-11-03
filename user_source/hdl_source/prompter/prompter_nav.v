// 提词屏翻页导航（阶段 3.1，像素域）：按键命令 → prompter_window_ctrl。D20 起观众屏不跟随讲稿换节，本模块与节无关。
// 翻页一次只发一页：滑动中（或已发出、待下一帧接收）收到的翻页先暂存一次，之后再发。
// 上一页：滚动中途（不在页起点）先回到本页起点。enable=0 时不发任何命令，滚动关闭。
module prompter_nav (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire        enable,
    input  wire [5:0]  slots,           // 讲稿页数（总览页不参与翻页）
    input  wire        cmd_next,        // 单拍
    input  wire        cmd_prev,
    input  wire        cmd_scroll,      // 单拍：连续滚动开/关
    input  wire [5:0]  page_slot,       // 来自 window_ctrl
    input  wire [15:0] window_row,
    input  wire        sliding,
    output wire        page_next,
    output wire        page_prev,
    output reg         scroll_en
);
    reg        pend, pend_dir;          // pend_dir 1 = 下一页
    reg        issued;                  // 已发出翻页、window_ctrl 尚未在 frame_start 接收（page_slot 仍是旧值）
    wire       on_page = (window_row == ({4'd0, page_slot, 9'd0} - {8'd0, page_slot, 5'd0}));
    wire       want_op = enable && !sliding && !issued && (pend || cmd_next || cmd_prev);
    wire       op_dir = pend ? pend_dir : cmd_next;
    wire       can_next = (page_slot + 6'd1 < slots);
    wire       can_prev = (page_slot != 6'd0) || !on_page;
    wire       op_ok = op_dir ? can_next : can_prev;
    assign page_next = want_op && op_ok && op_dir;
    assign page_prev = want_op && op_ok && !op_dir;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend <= 1'b0; pend_dir <= 1'b0; scroll_en <= 1'b0; issued <= 1'b0;
        end else if (!enable) begin
            pend <= 1'b0; scroll_en <= 1'b0; issued <= 1'b0;
        end else begin
            if (page_next || page_prev) issued <= 1'b1;
            else if (frame_start) issued <= 1'b0;
            if (cmd_scroll) scroll_en <= !scroll_en;
            if (want_op) pend <= 1'b0;
            else if (cmd_next || cmd_prev) begin
                // 滑动或待接收中：只暂存最近一次
                pend <= 1'b1; pend_dir <= cmd_next;
            end
        end
    end
endmodule
