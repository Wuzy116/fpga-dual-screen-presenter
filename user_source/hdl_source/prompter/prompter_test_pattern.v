// 提词屏（HDMI A）阶段 1.1 测试图案：8 条竖彩条 + 白边框 + 左上角红方块（镜像方向标记）
// + 逐帧下移 4 行、16 行高的反色带。坐标由输入 de/vs 自行计数，输出整体比输入晚 1 拍。
module prompter_test_pattern (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        hs_in,      // 低有效
    input  wire        vs_in,      // 低有效
    input  wire        de_in,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out     // 消隐期恒 0
);
    localparam [8:0] BAND_STEP = 9'd4;
    localparam [8:0] BAND_LAST = 9'd460;   // 带顶 0..460，带底不越过第 475 行

    reg [9:0] x;
    reg [8:0] y;
    reg [8:0] band_y;
    reg       de_q, vs_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 10'd0; y <= 9'd0; band_y <= 9'd0;
            de_q <= 1'b0; vs_q <= 1'b1;
        end else begin
            de_q <= de_in;
            vs_q <= vs_in;
            x <= de_in ? x + 10'd1 : 10'd0;
            if (!vs_in)              y <= 9'd0;
            else if (de_q && !de_in) y <= y + 9'd1;
            if (vs_q && !vs_in) band_y <= (band_y == BAND_LAST) ? 9'd0 : band_y + BAND_STEP;
        end
    end

    reg [23:0] bar;
    always @* begin
        if      (x < 10'd80)  bar = 24'hFFFFFF;
        else if (x < 10'd160) bar = 24'hFFFF00;
        else if (x < 10'd240) bar = 24'h00FFFF;
        else if (x < 10'd320) bar = 24'h00FF00;
        else if (x < 10'd400) bar = 24'hFF00FF;
        else if (x < 10'd480) bar = 24'hFF0000;
        else if (x < 10'd560) bar = 24'h0000FF;
        else                  bar = 24'h000000;
    end

    wire border = (x == 10'd0) || (x == 10'd639) || (y == 9'd0) || (y == 9'd479);
    wire marker = (x >= 10'd8) && (x < 10'd40) && (y >= 9'd8) && (y < 9'd40);
    wire band   = (y >= band_y) && (y < band_y + 9'd16);

    wire [23:0] pattern = border ? 24'hFFFFFF :
                          marker ? 24'hFF0000 :
                          band   ? ~bar : bar;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_out <= 1'b1; vs_out <= 1'b1; de_out <= 1'b0; rgb_out <= 24'd0;
        end else begin
            hs_out  <= hs_in;
            vs_out  <= vs_in;
            de_out  <= de_in;
            rgb_out <= de_in ? pattern : 24'd0;
        end
    end
endmodule
