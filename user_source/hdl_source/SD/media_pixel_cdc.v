`timescale 1ns/1ps

// BMP 解码器 -> media_frame_loader 的跨时钟域通道。
// load_start / 像素 / frame_commit 作为同一个 FIFO 里的令牌传递，到达 loader 的顺序与源端一致。
// 源端保证 load_start 不与像素或 frame_commit 同拍。src_top_down 随 load_start 令牌传递。
// 令牌位：[30] 槽号最高位、[29] top_down、[28] load_start、[27] commit、[26] 像素、[25:24] 槽号低 2 位、[23:0] RGB。
module media_pixel_cdc (
    input  wire        src_clk,
    input  wire        src_rst_n,
    input  wire        src_load_start,
    input  wire [2:0]  src_image_index,
    input  wire        src_top_down,
    input  wire        src_pixel_valid,
    input  wire [23:0] src_pixel_rgb,
    input  wire        src_frame_commit,
    output reg         src_overflow,

    input  wire        dst_clk,
    input  wire        dst_rst_n,
    output reg         dst_load_start,
    output reg  [2:0]  dst_image_index,
    output reg         dst_top_down,
    output reg         dst_pixel_valid,
    output reg  [23:0] dst_pixel_rgb,
    output reg         dst_frame_commit
);
    wire        fifo_we = src_load_start || src_pixel_valid || src_frame_commit;
    wire [31:0] fifo_di = {1'b0, src_image_index[2], src_top_down, src_load_start, src_frame_commit, src_pixel_valid,
                           src_image_index[1:0], src_pixel_rgb};
    wire        fifo_full;
    wire        fifo_empty;
    wire        fifo_valid;
    wire [31:0] fifo_do;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            src_overflow <= 1'b0;
        else if (fifo_we && fifo_full)
            src_overflow <= 1'b1;
    end

    // FIFO 复位专用寄存器：源域复位异步置位；目的域复位先作为电平两拍同步进源域再同步置位，
    // 两侧都释放后在源域释放。只驱动 FIFO 内两组复位同步器，避免全局复位高扇出网经组合门直达读侧
    // 同步器，也不让目的域复位网直接驱动源域寄存器的异步端（ext_mem_clk->clk 仅 5 ns 恢复预算）。
    (* ASYNC_REG="TRUE" *) reg [1:0] dst_rst_n_src;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            dst_rst_n_src <= 2'b00;
        else
            dst_rst_n_src <= {dst_rst_n_src[0], dst_rst_n};
    end
    reg  fifo_rst;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            fifo_rst <= 1'b1;
        else
            fifo_rst <= !dst_rst_n_src[1];
    end

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(9), .ADDR_WIDTH_R(9),
        .AL_FULL_NUM(500), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_fifo (
        .rst(fifo_rst), .clkw(src_clk), .clkr(dst_clk),
        .we(fifo_we), .di(fifo_di),
        .re(!fifo_empty), .dout(fifo_do), .valid(fifo_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(), .aempty(), .wrusedw(), .rdusedw()
    );

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_load_start   <= 1'b0;
            dst_image_index  <= 3'd0;
            dst_top_down     <= 1'b0;
            dst_pixel_valid  <= 1'b0;
            dst_pixel_rgb    <= 24'd0;
            dst_frame_commit <= 1'b0;
        end else begin
            dst_load_start   <= fifo_valid && fifo_do[28];
            dst_frame_commit <= fifo_valid && fifo_do[27];
            if (fifo_valid && fifo_do[28])
                dst_top_down <= fifo_do[29];
            dst_pixel_valid  <= fifo_valid && fifo_do[26];
            if (fifo_valid) begin
                dst_image_index <= {fifo_do[30], fifo_do[25:24]};
                dst_pixel_rgb   <= fifo_do[23:0];
            end
        end
    end
endmodule
