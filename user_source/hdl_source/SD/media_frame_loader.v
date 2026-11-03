`timescale 1ns/1ps

module media_frame_loader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer BURST_SIZE = 128,
    parameter integer STALL_TIMEOUT = 65535,
    // BMP 行序自下而上：置 1 时第 0 行写到 bank 内最后一行
    parameter integer WRITE_V_FLIP = 0,
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    // 0：{8'h00, rgb}（课程格式）；1：{rgb, 8'h00}（本工程读出取 [31:8]）
    parameter integer RGB_IN_MSB = 0,
    // 1：帧完成须等控制器 busy 撤销（厂商控制器最后一组引脚写落在 busy 尾部）
    parameter integer DRAIN_ON_BUSY = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  load_start,
    // 保持型取消请求：放弃当前帧，排空已发出的写后 load_cancel_done 置高直至撤销
    input  wire                  load_cancel,
    output wire                  load_cancel_done,
    input  wire [2:0]            image_index,     // 背景槽 0..4（D19）
    // 与 load_start 同拍采样：1 = 源行序已自上而下，本帧不做 WRITE_V_FLIP
    input  wire                  top_down,
    input  wire                  pixel_valid,
    input  wire [23:0]           pixel_rgb,
    input  wire                  frame_commit,
    input  wire [7:0]            decode_error,
    output wire                  load_busy,
    output reg                   load_done,
    output reg                   frame_done,
    output reg  [4:0]            image_complete,
    output reg  [7:0]            memory_error,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [3:0]            app_wr_mask,
    output reg  [31:0]           app_wr_data,
    // 仲裁：burst_hold=1 时不发起新 burst；burst_request 为不看 hold 的发起条件
    input  wire                  burst_hold,
    output wire                  burst_request,
    output wire                  burst_idle,
    // 本拍接受了 load_start（缩略图写入器据此重置行列计数）
    output wire                  start_accept
);
    localparam ERR_NONE          = 8'h00;
    localparam ERR_NOT_ACTIVE    = 8'h41;
    localparam ERR_FIFO_OVERFLOW = 8'h42;
    localparam ERR_PIXEL_COUNT   = 8'h43;
    localparam ERR_DECODE        = 8'h44;
    localparam ERR_SHORT_FRAME   = 8'h45;
    localparam ERR_WRITE_STALL   = 8'h46;

    localparam integer PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam [PTR_WIDTH:0] EFFECTIVE_BURST =
        (BURST_SIZE < FIFO_DEPTH) ? BURST_SIZE : FIFO_DEPTH;
    localparam [ADDR_WIDTH-1:0] FIRST_OFFSET =
        WRITE_V_FLIP ? (FRAME_HEIGHT - 1) * FRAME_WIDTH : 0;
    localparam [ADDR_WIDTH-1:0] VFLIP_LINE_JUMP = FRAME_WIDTH * 2 - 1;

    reg active;
    reg [2:0] active_image;
    reg vflip;
    reg commit_seen;
    // 计数上界：pixels_received 到 IMAGE_WORDS 由 rx_full 截止，pixels_written 不超过它，stall_count 不超过 STALL_TIMEOUT
    localparam integer PIX_CNT_W = $clog2(IMAGE_WORDS + 1);
    localparam integer STALL_W = $clog2(STALL_TIMEOUT + 1);
    reg [PIX_CNT_W-1:0] pixels_received;
    reg [PIX_CNT_W-1:0] pixels_written;
    reg [STALL_W-1:0] stall_count;
    reg [ADDR_WIDTH-1:0] wr_offset;
    reg [15:0] wr_x;
    reg [31:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] fifo_count;
    // 125 MHz 下宽比较放进 push/pop 判断链会超时：用与计数器同拍维护的寄存器标志代替
    reg fifo_empty;   // == (fifo_count == 0)
    reg fifo_full;    // == !(fifo_count < FIFO_DEPTH)
    reg burst_ready;  // == (fifo_count >= EFFECTIVE_BURST)
    reg rx_full;      // == (pixels_received >= IMAGE_WORDS)
    reg burst_active;
    reg [PTR_WIDTH:0] burst_remaining;
    wire pop_allowed;
    wire push_allowed;
    wire start_burst;
    wire [PTR_WIDTH:0] next_burst_words;
    reg drain_wait;
    reg cancel_done;
    // 控制器在 busy 拉高前还有几拍流水；连续 4 拍无写且不忙才视为已排空
    reg [2:0] quiet_count;
    wire write_idle = quiet_count == 3'd4;

    assign load_busy = active || drain_wait;
    assign load_cancel_done = cancel_done;
    // The inherited controller consumes a continuous App_wr_en burst and
    // handles busy/refresh internally. Those status outputs are not per-word
    // ready signals and must not split an active write burst.
    assign burst_request = active && !load_cancel && controller_init_done && !burst_active &&
                           !fifo_empty && (burst_ready || commit_seen);
    assign start_burst = burst_request && !burst_hold;
    assign burst_idle = !burst_active && !app_wr_en;
    assign next_burst_words = burst_ready ? EFFECTIVE_BURST : fifo_count;
    assign pop_allowed = active && controller_init_done && burst_active &&
                         !fifo_empty;
    assign push_allowed = active && pixel_valid &&
                          (!fifo_full || pop_allowed);
    // 本拍实际出队：取消时只看 pop_allowed；否则与下方报错分支互斥（报错拍不出队）
    wire fail_now = (decode_error != 0) || (pixel_valid && rx_full) || (pixel_valid && !push_allowed);
    wire pop_fire = pop_allowed && (load_cancel || !fail_now);
    wire load_accept = load_start && !active && !drain_wait && !load_cancel;
    assign start_accept = load_accept;
    // 块 RAM 寄存读：按下一拍的 rd_ptr 预取队头；同拍写同址时下一拍改用旁路数据
    wire [PTR_WIDTH-1:0] rd_addr = load_accept ? {PTR_WIDTH{1'b0}} :
                                   pop_fire ? rd_ptr + 1'b1 : rd_ptr;
    wire [31:0] fifo_wdata = RGB_IN_MSB ? {pixel_rgb, 8'h00} : {8'h00, pixel_rgb};
    reg  [31:0] fifo_q, fifo_bypass;
    reg         fifo_hazard;
    wire [31:0] fifo_head = fifo_hazard ? fifo_bypass : fifo_q;

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = 0;
                3'd1: bank_base = IMAGE_WORDS;
                3'd2: bank_base = IMAGE_WORDS * 2;
                3'd3: bank_base = IMAGE_WORDS * 3;
                default: bank_base = IMAGE_WORDS * 4;
            endcase
        end
    endfunction

    task fail_load;
        input [7:0] code;
        begin
            memory_error <= code;
            active <= 1'b0;
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b1;
        end
    endtask

    // RAM 写使能只看 pixel_valid，避免 125 MHz 下写使能串上计数/报错逻辑；
    // 指针只在 push_allowed 时前进；不前进的写入只发生在未激活或已报错放弃本帧时
    always @(posedge clk) begin
        if (pixel_valid)
            fifo_mem[wr_ptr] <= fifo_wdata;
        fifo_q <= fifo_mem[rd_addr];
        fifo_hazard <= pixel_valid && (wr_ptr == rd_addr);
        fifo_bypass <= fifo_wdata;
    end
    // synthesis translate_off
    reg [PTR_WIDTH-1:0] rd_addr_q;
    reg rd_addr_check;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_check <= 1'b0;
        end else begin
            rd_addr_q <= rd_addr;
            rd_addr_check <= 1'b1;
            if (rd_addr_check && rd_addr_q !== rd_ptr) begin
                $display("FATAL: %m read-address predictor %0d != rd_ptr %0d", rd_addr_q, rd_ptr);
                $finish;
            end
        end
    end
    // synthesis translate_on

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            active_image <= 3'd0;
            vflip <= 1'b0;
            commit_seen <= 1'b0;
            pixels_received <= 0;
            pixels_written <= 0;
            stall_count <= 0;
            wr_offset <= FIRST_OFFSET;
            wr_x <= 16'd0;
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            fifo_count <= {(PTR_WIDTH+1){1'b0}};
            fifo_empty <= 1'b1;
            fifo_full <= 1'b0;
            burst_ready <= 1'b0;
            rx_full <= 1'b0;
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b0;
            frame_done <= 1'b0;
            drain_wait <= 1'b0;
            cancel_done <= 1'b0;
            quiet_count <= 3'd0;
            image_complete <= 5'd0;
            memory_error <= ERR_NONE;
            app_wr_en <= 1'b0;
            app_wr_addr <= {ADDR_WIDTH{1'b0}};
            app_wr_mask <= 4'b0000;
            app_wr_data <= 32'd0;
        end else begin
            load_done <= 1'b0;
            frame_done <= 1'b0;
            app_wr_en <= 1'b0;

            if (app_wr_en || (DRAIN_ON_BUSY && controller_busy))
                quiet_count <= 3'd0;
            else if (quiet_count != 3'd4)
                quiet_count <= quiet_count + 3'd1;

            // 取消：不再发起新 burst，但已开始的 burst 必须写完（控制器按 4 字组下发，截断会留下残字），
            // 之后等写和控制器 busy 都过去才确认
            if (load_cancel) begin
                drain_wait <= 1'b0;
                if (pop_allowed) begin
                    app_wr_en <= 1'b1;
                    app_wr_addr <= bank_base(active_image) + wr_offset;
                    app_wr_data <= fifo_head;
                    app_wr_mask <= 4'b0000;
                    rd_ptr <= rd_ptr + 1'b1;
                    fifo_count <= fifo_count - 1'b1;
                    fifo_empty <= (fifo_count == 1);
                    if (vflip && wr_x == FRAME_WIDTH - 1) begin
                        wr_x <= 16'd0;
                        wr_offset <= wr_offset - VFLIP_LINE_JUMP;
                    end else begin
                        wr_x <= wr_x + 1'b1;
                        wr_offset <= wr_offset + 1'b1;
                    end
                    if (burst_remaining == 1) begin
                        burst_active <= 1'b0;
                        burst_remaining <= 0;
                    end else begin
                        burst_remaining <= burst_remaining - 1'b1;
                    end
                end else if (!burst_active) begin
                    active <= 1'b0;
                end
                if (!burst_active && write_idle)
                    cancel_done <= 1'b1;
            end else begin
                cancel_done <= 1'b0;
            end

            if (drain_wait && !load_cancel && write_idle) begin
                drain_wait <= 1'b0;
                if (active_image <= 3'd4) image_complete[active_image] <= 1'b1;
                load_done <= 1'b1;
                frame_done <= 1'b1;
            end

            if (load_start && !active && !drain_wait && !load_cancel) begin
                active <= 1'b1;
                active_image <= image_index;
                vflip <= WRITE_V_FLIP && !top_down;
                commit_seen <= 1'b0;
                pixels_received <= 0;
                pixels_written <= 0;
                stall_count <= 0;
                wr_offset <= (WRITE_V_FLIP && !top_down) ? FIRST_OFFSET : {ADDR_WIDTH{1'b0}};
                wr_x <= 16'd0;
                wr_ptr <= {PTR_WIDTH{1'b0}};
                rd_ptr <= {PTR_WIDTH{1'b0}};
                fifo_count <= {(PTR_WIDTH+1){1'b0}};
                fifo_empty <= 1'b1;
                fifo_full <= 1'b0;
                burst_ready <= 1'b0;
                rx_full <= 1'b0;
                burst_active <= 1'b0;
                burst_remaining <= 0;
                memory_error <= ERR_NONE;
                if (image_index <= 3'd4) image_complete[image_index] <= 1'b0;
            end

            if (active && !load_cancel) begin
                if (decode_error != 0) begin
                    fail_load(ERR_DECODE);
                end else if (pixel_valid && rx_full) begin
                    fail_load(ERR_PIXEL_COUNT);
                end else if (pixel_valid && !push_allowed) begin
                    fail_load(ERR_FIFO_OVERFLOW);
                end else begin
                    if (start_burst) begin
                        burst_active <= 1'b1;
                        burst_remaining <= next_burst_words;
                    end

                    if (push_allowed) begin
                        wr_ptr <= wr_ptr + 1'b1;
                        pixels_received <= pixels_received + 1'b1;
                        if (pixels_received == IMAGE_WORDS - 1)
                            rx_full <= 1'b1;
                    end

                    if (pop_allowed) begin
                        app_wr_en <= 1'b1;
                        app_wr_addr <= bank_base(active_image) + wr_offset;
                        if (vflip && wr_x == FRAME_WIDTH - 1) begin
                            wr_x <= 16'd0;
                            wr_offset <= wr_offset - VFLIP_LINE_JUMP;
                        end else begin
                            wr_x <= wr_x + 1'b1;
                            wr_offset <= wr_offset + 1'b1;
                        end
                        app_wr_data <= fifo_head;
                        app_wr_mask <= 4'b0000;
                        rd_ptr <= rd_ptr + 1'b1;
                        pixels_written <= pixels_written + 1'b1;
                        stall_count <= 0;
                        if (burst_remaining == 1) begin
                            burst_active <= 1'b0;
                            burst_remaining <= 0;
                        end else begin
                            burst_remaining <= burst_remaining - 1'b1;
                        end
                    end else if (!fifo_empty && (commit_seen || burst_ready)) begin
                        if (stall_count == STALL_TIMEOUT)
                            fail_load(ERR_WRITE_STALL);
                        else
                            stall_count <= stall_count + 1'b1;
                    end else begin
                        stall_count <= 0;
                    end

                    case ({push_allowed, pop_allowed})
                        2'b10: begin
                            fifo_count <= fifo_count + 1'b1;
                            fifo_empty <= 1'b0;
                            fifo_full <= (fifo_count == FIFO_DEPTH - 1);
                            burst_ready <= (fifo_count >= EFFECTIVE_BURST - 1);
                        end
                        2'b01: begin
                            fifo_count <= fifo_count - 1'b1;
                            fifo_empty <= (fifo_count == 1);
                            fifo_full <= 1'b0;
                            burst_ready <= (fifo_count > EFFECTIVE_BURST);
                        end
                        default: fifo_count <= fifo_count;
                    endcase

                    if (frame_commit)
                        commit_seen <= 1'b1;

                    if (commit_seen && fifo_empty && !pop_allowed &&
                        !burst_active) begin
                        if (pixels_received != IMAGE_WORDS || pixels_written != IMAGE_WORDS) begin
                            fail_load(ERR_SHORT_FRAME);
                        end else begin
                            active <= 1'b0;
                            drain_wait <= 1'b1;
                        end
                    end
                end
            end else if (pixel_valid && !load_cancel && !cancel_done) begin
                memory_error <= ERR_NOT_ACTIVE;
            end
        end
    end
endmodule
