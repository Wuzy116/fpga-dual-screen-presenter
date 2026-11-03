// 提词屏窗口起点控制（阶段 2.5，像素域）。window_row 只在 frame_start 那拍更新；prompter_script_reader 在同一
// 场同步沿锁存，因此读到的是上一帧算好的值，帧内永不变化（无撕裂）。
// 翻页：page_next / page_prev 单拍脉冲，目标为相邻页起点。每帧把剩余距离降到下一档
//   480,468,444,404,348,284,220,156,100,60,32,12,0（缓入缓出，整页 12 帧，每帧最多 64 行）；
//   滚动中途翻页的距离不足一页，从表中相应位置开始，同样平滑。
//   滑动中收到的翻页请求累计（±7 饱和），到达后紧接着滑；越过首末页的请求丢弃。
// 跳页：jump 单拍脉冲，下一帧直接切到 jump_slot（不动画），清除排队。
// 连续滚动：scroll_en=1 且未在滑动时每帧前进 scroll_speed/16 行（Q4），到最后一页起点停住；scroll_en=0 即暂停。
// page_slot 为窗口所在页（滚动中为向下取整的页，滑动中为目标页）。slots=0 时窗口恒为 0，翻页请求丢弃。
// D16：翻页与滚动只在讲稿页 [0, pages) 内进行（总览页存放在其后）；跳页可到任意已装槽 [0, slots)。
//   pages=0 时不翻页、不滚动。
// DIRECT=1（D18 产品默认）：翻页不做动画，下一帧直接到目标页（sliding 只高一帧）；排队只留 ±1（按键间隔远大于一帧，
//   更深的队列用不到）；默认 0 为 12 帧缓动、排队 ±7。
module prompter_window_ctrl #(
    parameter DIRECT = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire [5:0]  slots,
    input  wire [5:0]  pages,
    input  wire        page_next,
    input  wire        page_prev,
    input  wire        jump,
    input  wire [5:0]  jump_slot,
    input  wire        scroll_en,
    input  wire [7:0]  scroll_speed,      // 行/帧，Q4（16 = 每帧 1 行）
    output reg  [15:0] window_row,
    output reg  [5:0]  page_slot,
    output wire        sliding
);
    function [8:0] next_rem(input [8:0] r);   // 表中严格小于 r 的最大一档
        next_rem = (r > 9'd468) ? 9'd468 : (r > 9'd444) ? 9'd444 : (r > 9'd404) ? 9'd404 :
                   (r > 9'd348) ? 9'd348 : (r > 9'd284) ? 9'd284 : (r > 9'd220) ? 9'd220 :
                   (r > 9'd156) ? 9'd156 : (r > 9'd100) ? 9'd100 : (r > 9'd60)  ? 9'd60  :
                   (r > 9'd32)  ? 9'd32  : (r > 9'd12)  ? 9'd12  : 9'd0;
    endfunction
    function [15:0] times480(input [5:0] s);
        times480 = {1'b0, s, 9'd0} - {5'd0, s, 5'd0};
    endfunction

    localparam integer QW = DIRECT ? 2 : 4;
    localparam signed [QW:0] QLIM = 1 <<< (QW - 1);      // 饱和界（不可达）：DIRECT ±2，否则 ±8
    reg  [15:0] target;             // 滑动目标行；静止时等于 window_row
    reg  [QW-1:0] queue;            // 排队翻页，补码 -(QLIM-1)..+(QLIM-1)
    reg  [3:0]  frac;
    reg  [15:0] page_row;           // page_slot*480
    wire [5:0]  last_slot = (pages == 6'd0) ? 6'd0 : pages - 6'd1;
    wire [15:0] last_row = times480(last_slot);
    assign sliding = (window_row != target);

    wire        down = (target > window_row);
    wire [8:0]  rem = down ? (target[8:0] - window_row[8:0]) : (window_row[8:0] - target[8:0]);   // 恒 <= 480
    wire [8:0]  rem_n = DIRECT ? 9'd0 : next_rem(rem);
    wire signed [QW:0] q_ext = {queue[QW-1], queue};
    wire signed [QW:0] q_one = 1;
    wire signed [QW:0] q_next = q_ext + (page_next ? q_one : 0) - (page_prev ? q_one : 0);
    wire        q_take = (page_next ^ page_prev) && q_next != QLIM && q_next != -QLIM;
    wire [QW-1:0] q_cur = q_take ? q_next[QW-1:0] : queue;   // 含本拍按键
    wire        q_neg = q_cur[QW-1];
    wire [8:0]  frac_sum = {5'd0, frac} + {1'b0, scroll_speed};
    wire [16:0] scroll_row = {1'b0, window_row} + {12'd0, frac_sum[8:4]};
    wire        on_page = (window_row == page_row);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_row <= 16'd0; target <= 16'd0; page_slot <= 6'd0; page_row <= 16'd0;
            queue <= {QW{1'b0}}; frac <= 4'd0;
        end else if (jump) begin
            queue <= {QW{1'b0}}; frac <= 4'd0;
            if (jump_slot < slots) begin
                page_slot <= jump_slot; page_row <= times480(jump_slot);
                window_row <= times480(jump_slot); target <= times480(jump_slot);
            end
        end else begin
            queue <= (pages == 6'd0) ? {QW{1'b0}} : q_cur;
            if (frame_start && slots != 6'd0) begin
                if (sliding) begin
                    window_row <= down ? target - {7'd0, rem_n} : target + {7'd0, rem_n};
                end else if (pages == 6'd0) begin
                    queue <= {QW{1'b0}};
                end else if (q_cur != {QW{1'b0}}) begin
                    if (!q_neg && page_slot < last_slot) begin
                        queue <= q_cur - 1'b1; frac <= 4'd0;
                        page_slot <= page_slot + 6'd1; page_row <= page_row + 16'd480;
                        target <= page_row + 16'd480;
                    end else if (q_neg && !on_page) begin
                        queue <= q_cur + 1'b1; frac <= 4'd0;     // 滚动中途：先回到所在页起点
                        target <= page_row;
                    end else if (q_neg && page_slot != 6'd0) begin
                        queue <= q_cur + 1'b1; frac <= 4'd0;
                        page_slot <= page_slot - 6'd1; page_row <= page_row - 16'd480;
                        target <= page_row - 16'd480;
                    end else queue <= {QW{1'b0}};
                end else if (scroll_en) begin
                    if (scroll_row >= {1'b0, last_row}) begin
                        window_row <= last_row; target <= last_row; frac <= 4'd0;
                        page_slot <= last_slot; page_row <= last_row;
                    end else begin
                        window_row <= scroll_row[15:0]; target <= scroll_row[15:0]; frac <= frac_sum[3:0];
                        if (scroll_row[15:0] >= page_row + 16'd480) begin
                            page_slot <= page_slot + 6'd1; page_row <= page_row + 16'd480;
                        end
                    end
                end
            end
        end
    end
endmodule
