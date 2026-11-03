// 通用八槽扫描：位选和段码均由调用者提供，低 8 位为槽位 0。
// ON_PERCENT：每槽只在前 ON_PERCENT% 时间打开位选（调光 / 降功耗），默认 100 与原行为逐拍一致。
module seg_scan #(
    parameter integer SCAN_FREQ = 200,
    parameter integer CLK_FREQ = 50000000,
    parameter integer SCAN_COUNT = (SCAN_FREQ > 0) ? CLK_FREQ / (SCAN_FREQ * 8) - 1 : 0,
    parameter integer ON_PERCENT = 100
)(
    input wire clk,
    input wire rst_n,
    input wire [63:0] slot_sel,
    input wire [63:0] slot_seg,
    output reg [7:0] seg_sel,
    output reg [7:0] seg_data
);
// 每槽至少三个周期：关位选、准备段码、开位选。测试极小分频也保持消隐。
localparam integer SLOT_CYCLES = (SCAN_COUNT >= 2) ? SCAN_COUNT + 1 : 3;
localparam integer ON_RAW = SLOT_CYCLES * ON_PERCENT / 100;
// 位选在 [2, ON_END) 打开，至少一拍
localparam integer ON_END = (ON_RAW >= SLOT_CYCLES) ? SLOT_CYCLES : (ON_RAW > 3) ? ON_RAW : 3;
localparam integer TIMER_W = (SLOT_CYCLES <= 4) ? 2 : $clog2(SLOT_CYCLES);
reg [TIMER_W-1:0] scan_timer;
reg [2:0] scan_sel;
reg [63:0] frame_sel;
reg [63:0] frame_seg;
wire [7:0] selected_sel = frame_sel[scan_sel*8 +: 8];
wire [7:0] selected_seg = frame_seg[scan_sel*8 +: 8];
wire [7:0] active_bits = ~selected_sel;
wire selected_valid = (active_bits != 8'd0) &&
                      ((active_bits & (active_bits - 8'd1)) == 8'd0);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scan_timer <= {TIMER_W{1'b0}};
        scan_sel <= 3'd0;
        frame_sel <= 64'hffff_ffff_ffff_ffff;
        frame_seg <= 64'hffff_ffff_ffff_ffff;
        seg_sel <= 8'hff;
        seg_data <= 8'hff;
    end else begin
        if (scan_timer == 0) begin
            // 先关闭上一位，保持旧段码，下一拍再改段码。
            seg_sel <= 8'hff;
            if (scan_sel == 0) begin
                frame_sel <= slot_sel;
                frame_seg <= slot_seg;
            end
        end else if (scan_timer == 1) begin
            seg_sel <= 8'hff;
            seg_data <= selected_valid ? selected_seg : 8'hff;
        end else if (scan_timer < ON_END) begin
            // 全关或同时选中多位均消隐，避免错误输入点亮多个数码管。
            seg_sel <= selected_valid ? selected_sel : 8'hff;
        end else begin
            seg_sel <= 8'hff;
        end
        if (scan_timer >= SLOT_CYCLES - 1) begin
            scan_timer <= {TIMER_W{1'b0}};
            scan_sel <= (scan_sel == 3'd7) ? 3'd0 : scan_sel + 3'd1;
        end else begin
            scan_timer <= scan_timer + 1'b1;
        end
    end
end
endmodule
