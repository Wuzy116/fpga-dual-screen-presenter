// 面板的稳定对外接口：这里只读播放器状态，不向播放器输出控制信号。
module seg_panel #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer PAGE_PERIOD_MS = 1000,
    parameter integer HOLD_MS = 2000,
    parameter integer SCAN_FREQ = 200,
    parameter integer ON_PERCENT = 100,
    parameter ENABLE_PARAMETER_HINT = 0,
    parameter ENABLE_DIAG_PAGE = 0,
    parameter ENABLE_STAGE = 0
)(
    input wire clk,
    input wire rst,
    input wire [2:0] img_idx,
    input wire display_valid,
    input wire load_busy,
    input wire manual_pic_event,
    input wire [31:0] auto_period_ms,
    output wire [7:0] seg_sel,
    output wire [7:0] seg_data,
    input wire parameter_hint_ready,
    input wire parameter_selected_volume,
    input wire [31:0] diag_digits,
    input wire [7:0] volume,
    input wire [1:0] stage,
    input wire [2:0] fault,
    // min(floor(auto_period_ms/1000), 99)，供 OSD 参数行使用；与 PRD 页同一换算结果。
    output wire [6:0] period_s
);
// 只处理面板局部复位：异步置位、同域同步释放，不改原工程复位逻辑。
reg [1:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if (rst)
        reset_sync <= 2'b11;
    else
        reset_sync <= {reset_sync[0], 1'b0};
end
wire panel_rst = reset_sync[1];
wire [1:0] page_id;
wire [63:0] slot_sel;
wire [63:0] slot_seg;
wire period_valid;
wire [7:0] period_bcd;

seg_period_seconds u_period_seconds (
    .clk(clk), .rst(panel_rst), .period_ms(auto_period_ms),
    .period_valid(period_valid), .period_bcd(period_bcd), .period_sat(period_s)
);
seg_page_control #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .PAGE_PERIOD_MS(PAGE_PERIOD_MS), .HOLD_MS(HOLD_MS),
    .ENABLE_DIAG_PAGE(ENABLE_DIAG_PAGE)
) u_page_control (
    .clk(clk), .rst(panel_rst), .manual_pic_event(manual_pic_event),
    .load_busy(load_busy), .page_id(page_id)
);
seg_page_render #(.ENABLE_PARAMETER_HINT(ENABLE_PARAMETER_HINT),
    .ENABLE_DIAG_PAGE(ENABLE_DIAG_PAGE), .ENABLE_STAGE(ENABLE_STAGE)) u_page_render (
    .page_id(page_id), .img_idx(img_idx), .display_valid(display_valid),
    .load_busy(load_busy),
    .period_valid(period_valid), .period_bcd(period_bcd),
    .slot_sel(slot_sel), .slot_seg(slot_seg),
    .parameter_hint_ready(parameter_hint_ready),
    .parameter_selected_volume(parameter_selected_volume),
    .diag_digits(diag_digits),
    .volume(volume),
    .stage(stage),
    .fault(fault)
);
seg_scan #(.CLK_FREQ(CLK_FREQ_HZ), .SCAN_FREQ(SCAN_FREQ), .ON_PERCENT(ON_PERCENT)) u_scan (
    .clk(clk), .rst_n(~panel_rst), .slot_sel(slot_sel), .slot_seg(slot_seg),
    .seg_sel(seg_sel), .seg_data(seg_data)
);
endmodule

// 毫秒周期换算为秒：输入变化后逐拍减 1000（最多 100 拍），结果整组寄存后一次更新，换算期间保持旧值。
// period_valid：0～99 的整数秒；period_bcd：{十位, 个位}；period_sat：min(floor(ms/1000), 99)。
module seg_period_seconds (
    input wire clk,
    input wire rst,
    input wire [31:0] period_ms,
    output reg period_valid,
    output reg [7:0] period_bcd,
    output reg [6:0] period_sat
);
reg primed, busy;
reg [31:0] ms_q, rem;
reg [6:0] cnt;
reg [3:0] tens, ones;
wire step = (rem >= 32'd1000) && (cnt != 7'd100);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        primed <= 1'b0;
        busy <= 1'b0;
        ms_q <= 32'd0;
        rem <= 32'd0;
        cnt <= 7'd0;
        tens <= 4'd0;
        ones <= 4'd0;
        period_valid <= 1'b0;
        period_bcd <= 8'd0;
        period_sat <= 7'd0;
    end else if (!primed || period_ms != ms_q) begin
        primed <= 1'b1;
        busy <= 1'b1;
        ms_q <= period_ms;
        rem <= period_ms;
        cnt <= 7'd0;
        tens <= 4'd0;
        ones <= 4'd0;
    end else if (busy) begin
        if (step) begin
            rem <= rem - 32'd1000;
            cnt <= cnt + 7'd1;
            if (ones == 4'd9) begin
                ones <= 4'd0;
                tens <= tens + 4'd1;
            end else begin
                ones <= ones + 4'd1;
            end
        end else begin
            busy <= 1'b0;
            period_valid <= (rem == 32'd0) && (cnt != 7'd100);
            period_bcd <= {tens, ones};
            period_sat <= (cnt == 7'd100) ? 7'd99 : cnt;
        end
    end
end
endmodule
