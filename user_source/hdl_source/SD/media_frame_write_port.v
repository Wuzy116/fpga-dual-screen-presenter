`timescale 1ns/1ps

// 第 8 课写端口：保留 sd_card_bmp 原有写握手，数据面换成 media_pixel_cdc + media_frame_loader。
// write_req 保持至 write_req_ack 单拍；ack 同拍在像素通道里插入 load_start，之后的像素按序到达 loader。
// write_finish 为 mem_clk 单拍，仅在整帧写入且控制器 busy 撤销后出现；loader 报错不产生完成，
// 由源端写超时转入取消。write_cancel_req/ack 为保持型握手：ack 在 loader 排空、像素通道清空后置位。
module media_frame_write_port #(
    parameter integer ADDR_WIDTH   = 21,
    parameter integer IMAGE_WORDS  = 307200,
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer WRITE_V_FLIP = 1,
    // 第 13 课：1 = 同时把 4:1 缩略图写入总览页 bank（D19：第 6 个 bank，3×2 网格；写完成/取消确认都等缩略图写完）
    parameter integer ENABLE_THUMBS = 0
) (
    input  wire                  write_clk,
    input  wire                  write_rst_n,
    input  wire                  write_req,
    output reg                   write_req_ack,
    input  wire [2:0]            write_addr_index,
    // 与 write_req 同时有效，保持到 write_req_ack 撤销：1 = 本帧源行序自上而下（不翻转）
    input  wire                  write_top_down,
    input  wire                  write_en,
    input  wire [31:0]           write_data,
    input  wire                  write_cancel_req,
    output wire                  write_cancel_ack,

    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  write_finish,
    output wire [4:0]            image_complete,
    output wire [7:0]            memory_error,
    output wire                  pixel_overflow,
    output wire                  App_wr_en,
    output wire [ADDR_WIDTH-1:0] App_wr_addr,
    output wire [3:0]            App_wr_dm,
    output wire [31:0]           App_wr_din,
    input  wire                  burst_hold,
    output wire                  burst_request,
    output wire                  burst_idle
);
    reg [1:0] cancel_req_mem;
    reg [1:0] cancel_ack_wr;
    wire cancel_done_mem;
    wire loader_start;
    wire [2:0] loader_index;
    wire loader_top_down;
    wire loader_pixel_valid;
    wire [23:0] loader_pixel_rgb;
    wire loader_finish, loader_cancel_done, loader_start_accept;
    wire loader_wr_en, loader_burst_request, loader_burst_idle;
    wire [ADDR_WIDTH-1:0] loader_wr_addr;
    wire [3:0] loader_wr_dm;
    wire [31:0] loader_wr_din;
    wire loader_hold;

    // 源端在 ack 撤销前不会再次请求；ack 与首个像素之间至少隔 BMP 数据流水，load_start 不与像素同拍
    always @(posedge write_clk or negedge write_rst_n) begin
        if (!write_rst_n)
            write_req_ack <= 1'b0;
        else
            write_req_ack <= write_req && !write_req_ack && !write_cancel_req;
    end

    media_pixel_cdc u_pixel_cdc (
        .src_clk          (write_clk),
        .src_rst_n        (write_rst_n),
        .src_load_start   (write_req_ack),
        .src_image_index  (write_addr_index),
        .src_top_down     (write_top_down),
        .src_pixel_valid  (write_en && !write_cancel_req),
        .src_pixel_rgb    (write_data[31:8]),
        .src_frame_commit (1'b0),
        .src_overflow     (pixel_overflow),
        .dst_clk          (mem_clk),
        .dst_rst_n        (mem_rst_n),
        .dst_load_start   (loader_start),
        .dst_image_index  (loader_index),
        .dst_top_down     (loader_top_down),
        .dst_pixel_valid  (loader_pixel_valid),
        .dst_pixel_rgb    (loader_pixel_rgb),
        .dst_frame_commit ()
    );

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) cancel_req_mem <= 2'b00;
        else            cancel_req_mem <= {cancel_req_mem[0], write_cancel_req};
    end

    always @(posedge write_clk or negedge write_rst_n) begin
        if (!write_rst_n) cancel_ack_wr <= 2'b00;
        else              cancel_ack_wr <= {cancel_ack_wr[0], cancel_done_mem};
    end
    assign write_cancel_ack = cancel_ack_wr[1];

    // 帧长由 IMAGE_WORDS 决定：最后一个像素进 FIFO 即视为提交，不依赖源端完成信号的时序
    // 比帧长多一位：多出的像素（上游出错）要超过 IMAGE_WORDS 个才会回绕到再次 rx_last，单次加载不会发生
    localparam integer RX_W = $clog2(IMAGE_WORDS) + 1;
    reg [RX_W-1:0] rx_count;
    wire rx_last = loader_pixel_valid && rx_count == IMAGE_WORDS - 1;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n)
            rx_count <= 0;
        else if (loader_start || cancel_req_mem[1])
            rx_count <= 0;
        else if (loader_pixel_valid)
            rx_count <= rx_count + 1'b1;
    end
    reg commit_q;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) commit_q <= 1'b0;
        else            commit_q <= rx_last;
    end

    media_frame_loader #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .IMAGE_WORDS   (IMAGE_WORDS),
        .FIFO_DEPTH    (512),
        .BURST_SIZE    (128),
        .STALL_TIMEOUT (65535),
        .WRITE_V_FLIP  (WRITE_V_FLIP),
        .FRAME_WIDTH   (FRAME_WIDTH),
        .FRAME_HEIGHT  (FRAME_HEIGHT),
        .RGB_IN_MSB    (1),
        .DRAIN_ON_BUSY (1)
    ) u_loader (
        .clk                 (mem_clk),
        .rst_n               (mem_rst_n),
        .load_start          (loader_start),
        .load_cancel         (cancel_req_mem[1]),
        .load_cancel_done    (loader_cancel_done),
        .image_index         (loader_index),
        .top_down            (loader_top_down),
        .pixel_valid         (loader_pixel_valid && !cancel_req_mem[1]),
        .pixel_rgb           (loader_pixel_rgb),
        .frame_commit        (commit_q),
        .decode_error        (8'd0),
        .load_busy           (),
        .load_done           (),
        .frame_done          (loader_finish),
        .image_complete      (image_complete),
        .memory_error        (memory_error),
        .controller_init_done(controller_init_done),
        .controller_busy     (controller_busy),
        .refresh_active      (refresh_active),
        .app_wr_en           (loader_wr_en),
        .app_wr_addr         (loader_wr_addr),
        .app_wr_mask         (loader_wr_dm),
        .app_wr_data         (loader_wr_din),
        .burst_hold          (loader_hold),
        .burst_request       (loader_burst_request),
        .burst_idle          (loader_burst_idle),
        .start_accept        (loader_start_accept)
    );

    generate if (ENABLE_THUMBS) begin : g_thumbs
        wire thumb_request, thumb_idle, thumb_empty, thumb_wr_en, thumb_overflow;
        wire [ADDR_WIDTH-1:0] thumb_wr_addr;
        wire [31:0] thumb_wr_din;
        // 缩略图 burst 搭主图授权的便车：仲裁器只看到主图的 burst_request；主图 burst 结束后
        // burst_idle 保持低（仍占用本次授权），若缩略图已攒满一个 burst 就隔 GAP 拍接着写，写完才交还。
        // 帧尾残留在主图写完后单独请求一次。缩略图队列 64 字，每 640 主图字最多产生 160 字，
        // 主图 128 字 burst 产生 <= 32 字，便车频率足够，不会溢出（仿真断言溢出即停）。
        // 厂商控制器在上一 burst 之后过早接受下一 burst 会丢掉首个 4 字组（实测间隔 2 拍丢失、4 拍起正常），
        // 两次 burst 之间至少隔 GAP 拍无写（取 2 倍余量）。不等 controller_busy：busy 可长时间为高。
        localparam integer GAP = 8;
        reg [3:0] wr_gap;
        wire gap_ok = (wr_gap == GAP);
        // ride：主图刚写完一个 burst 且授权仍在手，缩略图接着写。ride_now 在主图 burst 结束的当拍
        // 即成立（组合），保证 burst_idle 不会有一拍为高、让仲裁器提前把授权交给读侧。
        reg ride_q;
        reg loader_finish_seen;
        reg loader_was_active;
        wire ride_start = loader_was_active && loader_burst_idle && thumb_request && !cancel_req_mem[1];
        wire ride = ride_start || ride_q;
        // 主图本帧已无待写（FIFO 空且整帧已写完 / 已提交）时，缩略图残余可单独申请授权
        wire tail_request = thumb_request && !loader_burst_request && loader_burst_idle && loader_finish_seen;
        always @(posedge mem_clk or negedge mem_rst_n) begin
            if (!mem_rst_n) wr_gap <= 4'd0;
            else if (App_wr_en) wr_gap <= 4'd0;
            else if (wr_gap != GAP) wr_gap <= wr_gap + 4'd1;
        end
        media_thumb_writer #(
            .ADDR_WIDTH  (ADDR_WIDTH),
            .IMAGE_WORDS (IMAGE_WORDS),
            .FRAME_WIDTH (FRAME_WIDTH),
            .FRAME_HEIGHT(FRAME_HEIGHT)
        ) u_thumb (
            .clk          (mem_clk),
            .rst_n        (mem_rst_n),
            .start        (loader_start_accept),
            .start_vflip  (WRITE_V_FLIP != 0 && !loader_top_down),
            .start_image  (loader_index),
            .cancel       (cancel_req_mem[1]),
            .tap_valid    (loader_wr_en),
            .tap_data     (loader_wr_din),
            .burst_hold   (!((ride || (tail_request && !burst_hold)) && loader_burst_idle && gap_ok)),
            .burst_request(thumb_request),
            .burst_idle   (thumb_idle),
            .empty        (thumb_empty),
            .app_wr_en    (thumb_wr_en),
            .app_wr_addr  (thumb_wr_addr),
            .app_wr_data  (thumb_wr_din),
            .overflow     (thumb_overflow)
        );
        assign loader_hold = burst_hold || ride || !thumb_idle || !gap_ok;
        assign burst_request = loader_burst_request || tail_request;
        // 便车期间对仲裁器保持“忙”，缩略图写完才交还授权
        assign burst_idle = loader_burst_idle && thumb_idle && !ride;
        assign App_wr_en = loader_wr_en || thumb_wr_en;
        assign App_wr_addr = thumb_wr_en ? thumb_wr_addr : loader_wr_addr;
        assign App_wr_din = thumb_wr_en ? thumb_wr_din : loader_wr_din;
        assign App_wr_dm = thumb_wr_en ? 4'b0000 : loader_wr_dm;
        // 缩略图写完且控制器连续 4 拍不忙后，才发出写完成 / 取消确认
        reg [2:0] thumb_quiet;
        reg finish_pending;
        wire thumb_drained = thumb_idle && thumb_empty && thumb_quiet == 3'd4;
        always @(posedge mem_clk or negedge mem_rst_n) begin
            if (!mem_rst_n) begin
                thumb_quiet <= 3'd0;
                finish_pending <= 1'b0;
                loader_finish_seen <= 1'b0;
                loader_was_active <= 1'b0;
                ride_q <= 1'b0;
            end else begin
                loader_was_active <= !loader_burst_idle;
                // 主图 burst 刚结束：若缩略图已满一个 burst 则进入便车；缩略图开始写后退出
                // 缩略图 burst 发出后（!thumb_idle）由其自身 burst_idle 占住授权，便车标志即可撤销
                if (cancel_req_mem[1] || !thumb_idle) ride_q <= 1'b0;
                else if (ride_start) ride_q <= 1'b1;
                if (loader_start_accept || cancel_req_mem[1]) loader_finish_seen <= 1'b0;
                else if (loader_finish) loader_finish_seen <= 1'b1;
                if (thumb_wr_en || controller_busy) thumb_quiet <= 3'd0;
                else if (thumb_quiet != 3'd4) thumb_quiet <= thumb_quiet + 3'd1;
                if (loader_start_accept || cancel_req_mem[1]) finish_pending <= 1'b0;
                else if (loader_finish) finish_pending <= 1'b1;
                else if (finish_pending && thumb_drained) finish_pending <= 1'b0;
            end
        end
        assign write_finish = finish_pending && thumb_drained;
        assign cancel_done_mem = loader_cancel_done && thumb_idle && thumb_quiet == 3'd4;
        // synthesis translate_off
        always @(posedge mem_clk) if (mem_rst_n) begin
            if (thumb_overflow) begin
                $display("FATAL: %m thumbnail queue overflow");
                $finish;
            end
            if (thumb_wr_en && loader_wr_en) begin
                $display("FATAL: %m thumbnail and loader bursts overlap");
                $finish;
            end
        end
        // synthesis translate_on
    end else begin : g_no_thumbs
        assign loader_hold = burst_hold;
        assign burst_request = loader_burst_request;
        assign burst_idle = loader_burst_idle;
        assign App_wr_en = loader_wr_en;
        assign App_wr_addr = loader_wr_addr;
        assign App_wr_din = loader_wr_din;
        assign App_wr_dm = loader_wr_dm;
        assign write_finish = loader_finish;
        assign cancel_done_mem = loader_cancel_done;
    end endgenerate
endmodule
