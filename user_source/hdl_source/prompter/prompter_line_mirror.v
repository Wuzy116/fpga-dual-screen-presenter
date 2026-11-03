// 提词屏整行镜像：输出整体比输入晚 LINE_CYCLES 拍（恰好一行），mirror 打开时每行有效像素左右反序。
// hs/vs/de 经 LINE_CYCLES-1 深环形 RAM 延迟一行（不依赖行内结构）；RGB 按有效像素序号写入两行乒乓缓存，
// 下一行反序（或正序）读出。mirror_en 只在输出侧场同步下降沿锁存，切换不打断时序、整帧一致。
module prompter_line_mirror #(
    parameter integer LINE_CYCLES = 800,   // 每行总拍数
    parameter integer H_ACTIVE    = 640
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        mirror_en,
    input  wire        hs_in,      // 低有效
    input  wire        vs_in,      // 低有效
    input  wire        de_in,
    input  wire [23:0] rgb_in,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output wire [23:0] rgb_out     // 消隐期恒 0
);
    localparam integer RING = LINE_CYCLES - 1;

    // ---------------- 同步信号一行延迟：写 p，读 p+1（RING-1 拍前写入），寄存读出再打一拍 ----------------
    reg [2:0]  sync_mem [0:1023];
    reg [9:0]  ring_p;
    reg [2:0]  sync_q;
    reg        primed;    // 环形 RAM 写满一圈前读出的是未初始化内容，输出空闲电平
    wire [9:0] ring_next = (ring_p == RING - 1) ? 10'd0 : ring_p + 10'd1;
    always @(posedge clk) begin
        sync_mem[ring_p] <= {hs_in, vs_in, de_in};
        sync_q <= sync_mem[ring_next];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ring_p <= 10'd0; primed <= 1'b0;
        end else begin
            ring_p <= ring_next;
            if (ring_p == RING - 1) primed <= 1'b1;
        end
    end
    // 读侧前视信号：比输入晚 RING 拍，再寄存一拍成为输出
    wire la_hs = primed ? sync_q[2] : 1'b1;
    wire la_vs = primed ? sync_q[1] : 1'b1;
    wire la_de = primed ? sync_q[0] : 1'b0;

    // ---------------- RGB 两行乒乓缓存：地址 {行选择, 有效像素序号} ----------------
    reg [23:0] line_mem [0:2047];
    reg [9:0]  wk, rk;
    reg        wbank, rbank, de_in_q, la_de_q, la_vs_q, mirror_q;
    reg [23:0] rgb_q;
    wire [9:0] rcol = mirror_q ? (H_ACTIVE - 1) - rk : rk;
    always @(posedge clk) begin
        if (de_in) line_mem[{wbank, wk}] <= rgb_in;
        rgb_q <= line_mem[{rbank, rcol}];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wk <= 10'd0; rk <= 10'd0; wbank <= 1'b0; rbank <= 1'b0;
            de_in_q <= 1'b0; la_de_q <= 1'b0; la_vs_q <= 1'b1; mirror_q <= 1'b0;
            hs_out <= 1'b1; vs_out <= 1'b1; de_out <= 1'b0;
        end else begin
            de_in_q <= de_in;
            wk <= de_in ? wk + 10'd1 : 10'd0;
            if (de_in_q && !de_in) wbank <= ~wbank;

            la_de_q <= la_de;
            la_vs_q <= la_vs;
            rk <= la_de ? rk + 10'd1 : 10'd0;
            if (la_de_q && !la_de) rbank <= ~rbank;
            if (la_vs_q && !la_vs) mirror_q <= mirror_en;

            hs_out <= la_hs; vs_out <= la_vs; de_out <= la_de;
        end
    end
    assign rgb_out = de_out ? rgb_q : 24'd0;
endmodule
