// 页面编号：0=PIC，1=PRD，2=VOLUME，3=DIAG（可选）。新增页面只调整本模块和排版模块。
module seg_page_control #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer PAGE_PERIOD_MS = 1000,
    parameter integer HOLD_MS = 2000,
    parameter ENABLE_DIAG_PAGE = 0
)(
    input wire clk,
    input wire rst,
    input wire manual_pic_event,
    input wire load_busy,
    output reg [1:0] page_id
);
localparam integer PAGE_RAW = (CLK_FREQ_HZ / 1000) * PAGE_PERIOD_MS;
localparam integer HOLD_RAW = (CLK_FREQ_HZ / 1000) * HOLD_MS;
localparam integer PAGE_CYCLES = (PAGE_RAW > 0) ? PAGE_RAW : 1;
localparam integer HOLD_CYCLES = (HOLD_RAW > 0) ? HOLD_RAW : 1;
localparam [1:0] PAGE_PIC = 2'd0, PAGE_PRD = 2'd1, PAGE_VOLUME = 2'd2, PAGE_DIAG = 2'd3;
// 两个计时器分别不超过 PAGE_CYCLES-1 / HOLD_CYCLES-1
localparam integer PAGE_W = (PAGE_CYCLES <= 2) ? 1 : $clog2(PAGE_CYCLES);
localparam integer HOLD_W = (HOLD_CYCLES <= 2) ? 1 : $clog2(HOLD_CYCLES);
reg [PAGE_W-1:0] page_timer;
reg [HOLD_W-1:0] hold_timer;
reg holding;
reg waiting_load;
reg idle_seen;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        page_id <= PAGE_PIC;
        page_timer <= 0;
        hold_timer <= 0;
        holding <= 1'b0;
        waiting_load <= 1'b0;
        idle_seen <= 1'b0;
    end else if (manual_pic_event) begin
        // 请求立即抢占 PIC，但加载时间不计入完成后的保持时间。
        page_id <= PAGE_PIC;
        page_timer <= 0;
        hold_timer <= 0;
        holding <= 1'b1;
        waiting_load <= 1'b1;
        idle_seen <= 1'b0;
    end else if (holding) begin
        if (waiting_load) begin
            hold_timer <= 0;
            if (load_busy) begin
                idle_seen <= 1'b0;
            end else if (!idle_seen) begin
                idle_seen <= 1'b1;
            end else begin
                // 连续观察两拍空闲，避开播放器提交后启动排队请求的一拍间隙。
                // 无实际加载或加载失败也可退出等待，不能永久锁住页面。
                waiting_load <= 1'b0;
                idle_seen <= 1'b0;
            end
        end else if (hold_timer >= HOLD_CYCLES - 1) begin
            holding <= 1'b0;
            hold_timer <= 0;
            page_timer <= 0;
            page_id <= PAGE_PRD;
        end else begin
            hold_timer <= hold_timer + 1'b1;
        end
    end else if (page_timer >= PAGE_CYCLES - 1) begin
        page_timer <= 0;
        case (page_id)
            PAGE_PIC: page_id <= PAGE_PRD;
            PAGE_PRD: page_id <= PAGE_VOLUME;
            PAGE_VOLUME: page_id <= ENABLE_DIAG_PAGE ? PAGE_DIAG : PAGE_PIC;
            default:  page_id <= PAGE_PIC;
        endcase
    end else begin
        page_timer <= page_timer + 1'b1;
    end
end
endmodule
