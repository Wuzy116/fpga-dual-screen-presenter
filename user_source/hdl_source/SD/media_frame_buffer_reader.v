`timescale 1ns/1ps

module media_frame_buffer_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 8,
    parameter integer BURST_SIZE = 128,
    parameter integer BURST_GAP_CYCLES = 12,
    parameter integer MAX_INFLIGHT_BURSTS = 2,
    parameter integer DIAG_RETURN_PATTERN = 0,
    parameter integer DIAG_SYNTH_STREAM = 0,
    // 1：SDRAM 字为 {rgb, 8'h00}，与 media_frame_loader.RGB_IN_MSB 一致
    parameter integer RGB_IN_MSB = 0,
    // 1：每帧前 split_words 个字读 active_index，其余读 alt_index（转场 Wipe）；
    // split_words 须为 BURST_SIZE 整数倍，使每个 burst 只落在一个 bank 内。
    parameter integer ENABLE_SPLIT = 0,
    // 第 13 课：1 = active_sheet 为 1 的帧整帧读总览页 bank（D19：第 6 个，基址 5*IMAGE_WORDS），忽略 split
    parameter integer ENABLE_SHEET = 0,
    // D22 左右滑动：slide_en=1 的帧每行分两段，前 slide_cols 列读段 1、其余读段 2；slide_left=1 时段 1 = alt_index
    //   （旧图右移出的部分）、段 2 = active_index（新图），=0 时相反。段 1 地址 = bank + 行首 + 列 + (FRAME_WIDTH - slide_cols)，
    //   段 2 = bank + 行首 + 列 - slide_cols；burst 不跨段、不跨行。slide_cols 须为 4 的倍数且 1..FRAME_WIDTH-1。
    parameter integer ENABLE_SLIDE = 0,
    parameter integer FRAME_WIDTH = 640,
    // D30 画面抖动（竖直）：shake_dy（带符号）非 0 的帧，屏幕第 y 行读 bank 内第 clamp(y+dy, 0, FRAME_HEIGHT-1) 行，
    //   越界行重复边缘行；与 slide 可同时使用（水平抖动由顶层把 slide 两段设为同一 bank 实现）。burst 不跨行，偏移按行加在 burst 基址上。
    parameter integer ENABLE_SHAKE = 0,
    parameter integer FRAME_HEIGHT = 480,
    // D32 行重映射（rm_en=1 的帧，优先于 slide / shake / split）：整行一段，
    //   第 r 个读出行按“有效行” e = r + 1 取源（像素域经行缓存晚一行显示，第 e 行屏幕正好用到它）：
    //   e 在窗口 [win_lo, win_hi] 外：读 a_bank 第 min(e,479) 行原样；窗口内：读 a_bank 第 clamp(acc>>8) 行，
    //   若 band_en 且源行在 [BAND_LO, BAND_HI]，改读 BAND_BANK、行 + BAND_DROW、列 + BAND_DCOL（第 1 张右下的背面素材区）。
    //   acc = acc0 + e * step（Q8，逐行累加）；越界行钳位读取，由像素域判定显示黑 / 背景。
    parameter integer ENABLE_REMAP = 0,
    parameter integer BAND_BANK = 0,
    parameter integer BAND_LO = 22,
    parameter integer BAND_HI = 318,
    parameter integer BAND_DROW = 138,
    parameter integer BAND_DCOL = 240
) (
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    // 仲裁：burst_hold=1 时不发起新 burst（进行中的 burst 照常发完）
    input  wire                  burst_hold,
    output wire                  burst_idle,
    output wire [$clog2(FIFO_DEPTH)-1:0] fifo_level,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,

    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  frame_start,
    input  wire [2:0]            active_index,
    input  wire [2:0]            alt_index,
    input  wire [ADDR_WIDTH:0]   split_words,
    input  wire                  active_sheet,
    input  wire                  slide_en,
    input  wire                  slide_left,
    input  wire [9:0]            slide_cols,
    input  wire signed [4:0]     shake_dy,
    input  wire                  rm_en,
    input  wire                  rm_band_en,
    input  wire [8:0]            rm_win_lo,
    input  wire [8:0]            rm_win_hi,
    input  wire [2:0]            rm_a_bank,
    input  wire signed [19:0]    rm_a_acc0,
    input  wire [9:0]            rm_a_step,
    input  wire                  pixel_consume,
    output wire [23:0]           pixel_rgb,
    output wire                  pixel_valid,
    output reg                   underflow,

    output reg                   reader_busy,
    output reg                   frame_read_done,
    output reg  [2:0]            reader_index,
    output reg  [7:0]            reader_error
);
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FRAME_OVERRUN = 8'h61;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h62;
    localparam [7:0] ERR_UNDERFLOW     = 8'h63;
    localparam [7:0] ERR_SHORT_FRAME   = 8'h64;
    localparam integer FIFO_COUNT_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer BURST_COUNT_W =
        (BURST_SIZE < 2) ? 1 : $clog2(BURST_SIZE + 1);
    localparam integer INFLIGHT_COUNT_W =
        (MAX_INFLIGHT_BURSTS * BURST_SIZE < 2) ? 1 :
        $clog2(MAX_INFLIGHT_BURSTS * BURST_SIZE + 1);

    reg request_pending_pix;
    reg request_toggle_pix;
    reg [2:0] request_index_pix;
    reg [2:0] request_alt_pix;
    reg [ADDR_WIDTH:0] request_split_pix;
    reg request_sheet_pix;
    reg [11:0] request_slide_pix;   // {en, left, cols}
    reg [4:0] request_dy_pix;
    // 重映射参数：像素域在请求拍锁存；存储域在 toggle 同步到达后直接采样（数据此前已稳定多拍），帧切换时生效
    localparam integer RMW = 1 + 1 + 9 + 9 + 3 + 20 + 10;
    reg [RMW-1:0] request_rm_pix, reload_rm_mem, reader_rm_mem;
    reg request_fire_pix;
    reg frame_armed_pix;
    reg [ADDR_WIDTH:0] consumed_count_pix;

    reg request_sync1_mem;
    reg request_sync2_mem;
    reg request_seen_mem;
    reg [2:0] index_sync1_mem;
    reg [2:0] index_sync2_mem;
    reg reload_pending_mem;
    reg [2:0] reload_index_mem;
    reg [2:0] alt_sync1_mem, alt_sync2_mem, reload_alt_mem, reader_alt_mem;
    reg [ADDR_WIDTH:0] split_sync1_mem, split_sync2_mem, reload_split_mem, reader_split_mem;
    reg sheet_sync1_mem, sheet_sync2_mem, reload_sheet_mem, reader_sheet_mem;
    reg [11:0] slide_sync1_mem, slide_sync2_mem, reload_slide_mem, reader_slide_mem;
    reg [9:0] col_mem;              // 下一个发出字所在列
    reg [4:0] dy_sync1_mem, dy_sync2_mem, reload_dy_mem, reader_dy_mem;
    reg [9:0] row_mem;              // 下一个发出字所在行
    reg [ADDR_WIDTH-1:0] row_off_mem;   // (clamp(row+dy) - row) * FRAME_WIDTH，模 2^ADDR_WIDTH
    localparam [ADDR_WIDTH-1:0] SHEET_BASE = IMAGE_WORDS * 5;
    reg [ADDR_WIDTH-1:0] burst_base_mem;
    reg [2:0] fifo_reset_count_mem;
    reg [ADDR_WIDTH:0] issued_count_mem;
    reg [ADDR_WIDTH:0] returned_count_mem;
    reg [INFLIGHT_COUNT_W-1:0] inflight_count_mem;
    reg inflight_empty_mem /* fehdl keep="true" */;
    reg burst_active_mem;
    reg [BURST_COUNT_W-1:0] burst_issued_mem;
    reg [BURST_COUNT_W-1:0] burst_target_mem;
    reg [7:0] burst_gap_count_mem;
    reg [ADDR_WIDTH:0] diag_written_count_mem;
    reg [9:0] diag_column_mem;
    reg [23:0] diag_rgb_mem;
    reg [1:0] fifo_release_mem;
    reg [1:0] fifo_release_pix;
    reg [1:0] fifo_release_pix_mem;
    // rfifo 写侧在 rst 撤销后还要 2 拍 clkw 才退出内部复位，期间写入会丢字；
    // 等两侧 release 都到齐再多等几拍才允许发读 burst
    reg [2:0] fifo_settle_mem;

    wire fifo_reset_request = !mem_rst_n || !pix_rst_n ||
                              (fifo_reset_count_mem != 0);
    wire fifo_reset = fifo_reset_request ||
                      !fifo_release_mem[1] || !fifo_release_pix[1];
    // 写侧门控只用存储域寄存器（像素侧 release 取两拍同步版），避免像素域复位组合跨入写使能；
    // FIFO rst 端口仍接完整异步 fifo_reset。mem_rst_n 有效时 fifo_release_mem 已被异步清零。
    wire fifo_write_block_mem = (fifo_reset_count_mem != 0) ||
                                !fifo_release_mem[1] || !fifo_release_pix_mem[1];
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire [FIFO_COUNT_W-1:0] fifo_wrusedw;
    wire [31:0] fifo_raw_data;
    wire fifo_raw_valid;
    wire fifo_raw_read_en;
    wire prefetch_valid;
    wire [31:0] prefetch_data;
    wire pixel_pop = pixel_consume && prefetch_valid;
    wire [ADDR_WIDTH:0] inflight_words =
        {{(ADDR_WIDTH+1-INFLIGHT_COUNT_W){1'b0}}, inflight_count_mem};
    wire final_return = returned_count_mem == IMAGE_WORDS - 1;
    wire [ADDR_WIDTH+1:0] reserved_words =
        {{(ADDR_WIDTH+2-FIFO_COUNT_W){1'b0}}, fifo_wrusedw} +
        {{1{1'b0}}, inflight_words};
    localparam integer FULL_BURSTS_ONLY = (IMAGE_WORDS % BURST_SIZE) == 0;
    wire [ADDR_WIDTH:0] remaining_words = IMAGE_WORDS - issued_count_mem;
    wire        q_rm_en, q_band_en;
    wire [8:0]  q_win_lo, q_win_hi;
    wire [2:0]  q_a_bank;
    wire signed [19:0] q_a_acc0;
    wire [9:0]  q_a_step;
    assign {q_rm_en, q_band_en, q_win_lo, q_win_hi, q_a_bank, q_a_acc0, q_a_step} = reader_rm_mem;
    wire signed [19:0] n_a_acc0 = reload_rm_mem[29:10];
    wire [9:0]  n_a_step = reload_rm_mem[9:0];
    wire rm_mode = ENABLE_REMAP && q_rm_en && !reader_sheet_mem;
    wire slide_mode = ENABLE_SLIDE && reader_slide_mem[11] && !reader_sheet_mem && !rm_mode;
    wire [9:0] slide_l1 = reader_slide_mem[9:0];
    wire slide_seg1 = col_mem < slide_l1;
    wire [9:0] seg_left = (slide_seg1 ? slide_l1 : FRAME_WIDTH[9:0]) - col_mem;   // 本段剩余字数
    wire [ADDR_WIDTH:0] next_burst_words =
        (slide_mode && seg_left < BURST_SIZE) ? {{(ADDR_WIDTH+1-10){1'b0}}, seg_left} :
        FULL_BURSTS_ONLY ? BURST_SIZE :
        ((remaining_words > BURST_SIZE) ? BURST_SIZE : remaining_words);
    // 段 1 读 left ? alt : active，基址 + (W - L1)；段 2 读 left ? active : alt，基址 - L1（模 2^ADDR_WIDTH，加上帧内偏移后回到本 bank）
    wire [2:0] slide_bank = (slide_seg1 ^ reader_slide_mem[10]) ? reader_index : reader_alt_mem;
    wire [ADDR_WIDTH-1:0] slide_delta = slide_seg1 ? FRAME_WIDTH - {{(ADDR_WIDTH-10){1'b0}}, slide_l1}
                                                   : {ADDR_WIDTH{1'b0}} - {{(ADDR_WIDTH-10){1'b0}}, slide_l1};
    wire signed [11:0] shake_row = $signed({2'b00, row_mem}) + $signed(reader_dy_mem);
    wire signed [11:0] shake_src = (shake_row < 0) ? 12'sd0 :
                                   (shake_row > FRAME_HEIGHT - 1) ? FRAME_HEIGHT - 1 : shake_row;
    wire signed [11:0] shake_diff = shake_src - $signed({2'b00, row_mem});
    wire [ADDR_WIDTH-1:0] shake_diff_ext = {{(ADDR_WIDTH-12){shake_diff[11]}}, shake_diff};
    // ---- 行重映射：逐行累加器与两级寄存的段偏移（行号在 burst 内不变，burst 间隔 >= BURST_GAP_CYCLES） ----
    reg  signed [19:0] rm_acc_a;
    reg         rm_win_q, rm_band_q;
    reg  [9:0]  rm_row_a_q;
    reg  [ADDR_WIDTH-1:0] rm_off_a;
    reg  [2:0]  rm_bank_a;
    wire [9:0]  rm_e = row_mem + 10'd1;
    wire signed [11:0] rm_ra = rm_acc_a >>> 8;
    function [9:0] clamp_row;
        input signed [11:0] r;
        clamp_row = (r < 0) ? 10'd0 : (r > FRAME_HEIGHT - 1) ? FRAME_HEIGHT - 1 : r[9:0];
    endfunction
    wire        rm_in_win = rm_e >= {1'b0, q_win_lo} && rm_e <= {1'b0, q_win_hi};
    wire        rm_band = q_band_en && rm_in_win && rm_ra >= BAND_LO && rm_ra <= BAND_HI;
    wire [9:0]  rm_e_c = (rm_e > FRAME_HEIGHT - 1) ? FRAME_HEIGHT - 1 : rm_e;
    wire signed [11:0] rm_dra = $signed({2'b00, rm_row_a_q}) + (rm_band_q ? BAND_DROW : 0) - $signed({2'b00, row_mem});
    wire [ADDR_WIDTH-1:0] rm_dra_x = {{(ADDR_WIDTH-12){rm_dra[11]}}, rm_dra};
    // 行差 * FRAME_WIDTH；640 时写成 (d << 9) + (d << 7)，常数移位相加，不占乘法器
    wire [ADDR_WIDTH-1:0] rm_dra_w = (FRAME_WIDTH == 640) ? (rm_dra_x << 9) + (rm_dra_x << 7) : rm_dra_x * FRAME_WIDTH;
    wire [ADDR_WIDTH+2:0] reserved_after_burst =
        {{1{1'b0}}, reserved_words} + {{2{1'b0}}, next_burst_words};
    wire inflight_window_ok = (MAX_INFLIGHT_BURSTS == 1) ?
        inflight_empty_mem :
        ((inflight_words + next_burst_words) <=
         (MAX_INFLIGHT_BURSTS * BURST_SIZE));
    wire fifo_reservation_ok =
        reserved_after_burst <= (FIFO_DEPTH - FIFO_MARGIN);
    reg inflight_window_ok_q;
    reg fifo_reservation_ok_q;
    assign burst_idle = !burst_active_mem && inflight_empty_mem && !app_rd_en;
    assign fifo_level = fifo_wrusedw;
    wire start_burst = !DIAG_SYNTH_STREAM && reader_busy && controller_init_done && !burst_hold &&
                       fifo_reset_count_mem == 0 && fifo_settle_mem[2] &&
                       !burst_active_mem &&
                       burst_gap_count_mem == 0 &&
                       issued_count_mem != IMAGE_WORDS &&
                       inflight_window_ok_q && fifo_reservation_ok_q;
    wire issue_allowed = !DIAG_SYNTH_STREAM && reader_busy && burst_active_mem;
    wire diag_stream_write = DIAG_SYNTH_STREAM && reader_busy &&
                             !fifo_write_block_mem && !fifo_full;
    wire fifo_write_enable = DIAG_SYNTH_STREAM ? diag_stream_write :
                             (sdram_rd_valid && !fifo_write_block_mem && !fifo_full);
    wire [31:0] fifo_write_data = (DIAG_RETURN_PATTERN || DIAG_SYNTH_STREAM) ?
                                  {8'h00, diag_rgb_mem} : sdram_rd_data;

    always @* begin
        if (diag_column_mem < 10'd80)
            diag_rgb_mem = 24'hffffff;
        else if (diag_column_mem < 10'd160)
            diag_rgb_mem = 24'hffff00;
        else if (diag_column_mem < 10'd240)
            diag_rgb_mem = 24'h00ffff;
        else if (diag_column_mem < 10'd320)
            diag_rgb_mem = 24'h00ff00;
        else if (diag_column_mem < 10'd400)
            diag_rgb_mem = 24'hff00ff;
        else if (diag_column_mem < 10'd480)
            diag_rgb_mem = 24'hff0000;
        else if (diag_column_mem < 10'd560)
            diag_rgb_mem = 24'h0000ff;
        else
            diag_rgb_mem = 24'h000000;
    end

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = {ADDR_WIDTH{1'b0}};
                3'd1: bank_base = IMAGE_WORDS;
                3'd2: bank_base = IMAGE_WORDS * 2;
                3'd3: bank_base = IMAGE_WORDS * 3;
                default: bank_base = IMAGE_WORDS * 4;
            endcase
        end
    endfunction

    // Delay the request by one pixel clock so media_player_control can commit
    // active_index on the frame_start edge before this module captures it.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_pending_pix <= 1'b0;
            request_toggle_pix <= 1'b0;
            request_index_pix <= 3'd0;
            request_alt_pix <= 3'd0;
            request_split_pix <= IMAGE_WORDS;
            request_sheet_pix <= 1'b0;
            request_slide_pix <= {2'b01, FRAME_WIDTH[9:0]};
            request_dy_pix <= 5'd0;
            request_rm_pix <= {RMW{1'b0}};
            request_fire_pix <= 1'b0;
            frame_armed_pix <= 1'b0;
            consumed_count_pix <= 0;
            underflow <= 1'b0;
            fifo_release_pix <= 2'b00;
        end else begin
            request_fire_pix <= 1'b0;
            if (fifo_reset_request)
                fifo_release_pix <= 2'b00;
            else
                fifo_release_pix <= {fifo_release_pix[0], 1'b1};

            if (frame_start) begin
                if (frame_armed_pix && consumed_count_pix != IMAGE_WORDS) begin
                    underflow <= 1'b1;
                end
                consumed_count_pix <= 0;
                request_pending_pix <= 1'b1;
            end else if (request_pending_pix) begin
                request_index_pix <= active_index;
                request_alt_pix <= alt_index;
                request_split_pix <= split_words;
                request_sheet_pix <= ENABLE_SHEET && active_sheet;
                request_slide_pix <= {ENABLE_SLIDE && slide_en, slide_left, slide_cols};
                request_dy_pix <= ENABLE_SHAKE ? shake_dy : 5'd0;
                if (ENABLE_REMAP)
                    request_rm_pix <= {rm_en, rm_band_en, rm_win_lo, rm_win_hi, rm_a_bank, rm_a_acc0, rm_a_step};
                // 多位请求数据先稳定一拍再翻转 toggle，存储域同步后整笔采样不会撕裂。
                if (ENABLE_SPLIT || ENABLE_SLIDE || ENABLE_SHAKE || ENABLE_REMAP)
                    request_fire_pix <= 1'b1;
                else
                    request_toggle_pix <= ~request_toggle_pix;
                request_pending_pix <= 1'b0;
                frame_armed_pix <= 1'b1;
            end
            if (request_fire_pix)
                request_toggle_pix <= ~request_toggle_pix;

            if (pixel_consume) begin
                if (prefetch_valid)
                    consumed_count_pix <= consumed_count_pix + 1'b1;
                else if (frame_armed_pix)
                    underflow <= 1'b1;
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            request_sync1_mem <= 1'b0;
            request_sync2_mem <= 1'b0;
            request_seen_mem <= 1'b0;
            index_sync1_mem <= 3'd0;
            index_sync2_mem <= 3'd0;
            reload_pending_mem <= 1'b0;
            reload_index_mem <= 3'd0;
            alt_sync1_mem <= 3'd0;
            alt_sync2_mem <= 3'd0;
            reload_alt_mem <= 3'd0;
            reader_alt_mem <= 3'd0;
            split_sync1_mem <= IMAGE_WORDS;
            split_sync2_mem <= IMAGE_WORDS;
            reload_split_mem <= IMAGE_WORDS;
            reader_split_mem <= IMAGE_WORDS;
            sheet_sync1_mem <= 1'b0;
            sheet_sync2_mem <= 1'b0;
            reload_sheet_mem <= 1'b0;
            reader_sheet_mem <= 1'b0;
            slide_sync1_mem <= {2'b01, FRAME_WIDTH[9:0]};
            slide_sync2_mem <= {2'b01, FRAME_WIDTH[9:0]};
            reload_slide_mem <= {2'b01, FRAME_WIDTH[9:0]};
            reader_slide_mem <= {2'b01, FRAME_WIDTH[9:0]};
            col_mem <= 10'd0;
            dy_sync1_mem <= 5'd0;
            dy_sync2_mem <= 5'd0;
            reload_dy_mem <= 5'd0;
            reader_dy_mem <= 5'd0;
            row_mem <= 10'd0;
            row_off_mem <= {ADDR_WIDTH{1'b0}};
            reload_rm_mem <= {RMW{1'b0}};
            reader_rm_mem <= {RMW{1'b0}};
            rm_acc_a <= 20'sd0;
            rm_win_q <= 1'b0; rm_band_q <= 1'b0; rm_row_a_q <= 10'd0;
            rm_off_a <= {ADDR_WIDTH{1'b0}}; rm_bank_a <= 3'd0;
            burst_base_mem <= {ADDR_WIDTH{1'b0}};
            fifo_reset_count_mem <= 3'd0;
            issued_count_mem <= 0;
            returned_count_mem <= 0;
            inflight_count_mem <= 0;
            inflight_empty_mem <= 1'b1;
            burst_active_mem <= 1'b0;
            burst_issued_mem <= 0;
            burst_target_mem <= 0;
            burst_gap_count_mem <= 0;
            diag_written_count_mem <= 0;
            diag_column_mem <= 0;
            fifo_release_mem <= 2'b00;
            fifo_release_pix_mem <= 2'b00;
            fifo_settle_mem <= 3'b000;
            inflight_window_ok_q <= 1'b1;
            fifo_reservation_ok_q <= 1'b1;
            app_rd_en <= 1'b0;
            app_rd_addr <= 0;
            reader_busy <= 1'b0;
            frame_read_done <= 1'b0;
            reader_index <= 3'd0;
            reader_error <= ERR_NONE;
        end else begin
            if (fifo_reset_request)
                fifo_release_mem <= 2'b00;
            else
                fifo_release_mem <= {fifo_release_mem[0], 1'b1};
            fifo_release_pix_mem <= {fifo_release_pix_mem[0], fifo_release_pix[1]};
            fifo_settle_mem <= {fifo_settle_mem[1:0],
                                !fifo_reset_request && fifo_release_mem[1] &&
                                fifo_release_pix_mem[1]};

            request_sync1_mem <= request_toggle_pix;
            request_sync2_mem <= request_sync1_mem;
            index_sync1_mem <= request_index_pix;
            index_sync2_mem <= index_sync1_mem;
            alt_sync1_mem <= request_alt_pix;
            alt_sync2_mem <= alt_sync1_mem;
            split_sync1_mem <= request_split_pix;
            split_sync2_mem <= split_sync1_mem;
            sheet_sync1_mem <= request_sheet_pix;
            sheet_sync2_mem <= sheet_sync1_mem;
            slide_sync1_mem <= request_slide_pix;
            slide_sync2_mem <= slide_sync1_mem;
            dy_sync1_mem <= request_dy_pix;
            dy_sync2_mem <= dy_sync1_mem;
            // 行号在 burst 内不变，burst 间隔 >= BURST_GAP_CYCLES 拍，寄存一拍的行偏移在下一个 burst 起点前已更新
            row_off_mem <= ENABLE_SHAKE ? shake_diff_ext * FRAME_WIDTH : {ADDR_WIDTH{1'b0}};
            if (ENABLE_REMAP) begin
                rm_win_q   <= rm_in_win;
                rm_band_q  <= rm_band;
                rm_row_a_q <= rm_in_win ? clamp_row(rm_ra) : rm_e_c;
                rm_bank_a  <= rm_band_q ? BAND_BANK : q_a_bank;
                rm_off_a   <= rm_dra_w + (rm_band_q ? BAND_DCOL : 0);
            end
            app_rd_en <= 1'b0;
            frame_read_done <= 1'b0;
            inflight_window_ok_q <= inflight_window_ok;
            fifo_reservation_ok_q <= fifo_reservation_ok;

            if (fifo_reset_count_mem != 0)
                fifo_reset_count_mem <= fifo_reset_count_mem - 1'b1;
            if (burst_gap_count_mem != 0)
                burst_gap_count_mem <= burst_gap_count_mem - 1'b1;

            case ({issue_allowed, sdram_rd_valid})
                2'b10: begin
                    inflight_count_mem <= inflight_count_mem + 1'b1;
                    inflight_empty_mem <= 1'b0;
                end
                2'b01: begin
                    if (!inflight_empty_mem) begin
                        inflight_count_mem <= inflight_count_mem - 1'b1;
                        if (inflight_count_mem == 1)
                            inflight_empty_mem <= 1'b1;
                    end
                end
                default: begin
                    inflight_count_mem <= inflight_count_mem;
                    inflight_empty_mem <= inflight_empty_mem;
                end
            endcase

            if (request_sync2_mem != request_seen_mem) begin
                request_seen_mem <= request_sync2_mem;
                reload_pending_mem <= 1'b1;
                reload_index_mem <= index_sync2_mem;
                reload_alt_mem <= alt_sync2_mem;
                reload_split_mem <= split_sync2_mem;
                reload_sheet_mem <= sheet_sync2_mem;
                reload_slide_mem <= slide_sync2_mem;
                reload_dy_mem <= dy_sync2_mem;
                if (ENABLE_REMAP) reload_rm_mem <= request_rm_pix;
                if (reader_busy || !inflight_empty_mem) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FRAME_OVERRUN;
                end
            end

            if (reload_pending_mem && inflight_empty_mem) begin
                reload_pending_mem <= 1'b0;
                reader_index <= reload_index_mem;
                reader_alt_mem <= reload_alt_mem;
                reader_split_mem <= reload_split_mem;
                reader_sheet_mem <= reload_sheet_mem;
                reader_slide_mem <= reload_slide_mem;
                reader_dy_mem <= reload_dy_mem;
                if (ENABLE_REMAP) begin
                    reader_rm_mem <= reload_rm_mem;
                    // 第 0 个读出行的有效行 e = 1
                    rm_acc_a <= n_a_acc0 + $signed({10'd0, n_a_step});
                end
                col_mem <= 10'd0;
                row_mem <= 10'd0;
                issued_count_mem <= 0;
                returned_count_mem <= 0;
                inflight_count_mem <= 0;
                inflight_empty_mem <= 1'b1;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                diag_written_count_mem <= 0;
                diag_column_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                fifo_settle_mem <= 3'b000;
                reader_busy <= 1'b1;
                reader_error <= ERR_NONE;
            end

            if (start_burst) begin
                burst_active_mem <= 1'b1;
                burst_issued_mem <= 0;
                burst_target_mem <= next_burst_words[BURST_COUNT_W-1:0];
                burst_base_mem <= reader_sheet_mem ? SHEET_BASE :
                                  rm_mode ? bank_base(rm_bank_a) + rm_off_a :
                                  slide_mode ? bank_base(slide_bank) + slide_delta + row_off_mem :
                                  (issued_count_mem < reader_split_mem) ?
                                  bank_base(reader_index) + row_off_mem : bank_base(reader_alt_mem) + row_off_mem;
            end

            if (issue_allowed) begin
                app_rd_en <= 1'b1;
                app_rd_addr <= ((ENABLE_SPLIT || ENABLE_SHEET || ENABLE_SLIDE) ? burst_base_mem : bank_base(reader_index)) +
                               issued_count_mem[ADDR_WIDTH-1:0];
                issued_count_mem <= issued_count_mem + 1'b1;
                col_mem <= (col_mem == FRAME_WIDTH - 1) ? 10'd0 : col_mem + 10'd1;
                if (col_mem == FRAME_WIDTH - 1) begin
                    row_mem <= row_mem + 10'd1;
                    if (ENABLE_REMAP) begin
                        rm_acc_a <= rm_acc_a + $signed({10'd0, q_a_step});
                    end
                end
                burst_issued_mem <= burst_issued_mem + 1'b1;
                if (burst_issued_mem + 1'b1 == burst_target_mem) begin
                    burst_active_mem <= 1'b0;
                    burst_gap_count_mem <= BURST_GAP_CYCLES;
                end
            end

            if (!DIAG_SYNTH_STREAM && sdram_rd_valid) begin
                returned_count_mem <= returned_count_mem + 1'b1;
                if (fifo_full) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FIFO_OVERFLOW;
                end else if (final_return) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end

            if (DIAG_SYNTH_STREAM && diag_stream_write) begin
                diag_written_count_mem <= diag_written_count_mem + 1'b1;
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
                if (diag_written_count_mem == IMAGE_WORDS - 1) begin
                    reader_busy <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end else if (!DIAG_SYNTH_STREAM && DIAG_RETURN_PATTERN &&
                         sdram_rd_valid) begin
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
            end
        end
    end

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(FIFO_COUNT_W), .ADDR_WIDTH_R(FIFO_COUNT_W),
        .AL_FULL_NUM(FIFO_DEPTH-FIFO_MARGIN), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_read_fifo (
        .rst(fifo_reset), .clkw(mem_clk), .clkr(pix_clk),
        .we(fifo_write_enable), .di(fifo_write_data),
        .re(fifo_raw_read_en), .dout(fifo_raw_data), .valid(fifo_raw_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_almost_full), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw()
    );

    // 预取级只在像素域：复位由本域寄存器给出（fifo_reset 异步置位、像素时钟同步释放），
    // 避免存储域组合复位直接打到像素域寄存器异步端（ext_mem_clk->video_clk 仅 5 ns 恢复预算）。
    reg prefetch_rst;
    always @(posedge pix_clk or posedge fifo_reset) begin
        if (fifo_reset) prefetch_rst <= 1'b1;
        else            prefetch_rst <= 1'b0;
    end
    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(pix_clk), .rst(prefetch_rst), .raw_empty(fifo_empty),
        .raw_valid(fifo_raw_valid), .raw_data(fifo_raw_data),
        .raw_read_en(fifo_raw_read_en), .consume(pixel_pop),
        .out_valid(prefetch_valid), .out_empty(), .out_data(prefetch_data)
    );

    assign pixel_rgb = RGB_IN_MSB ? prefetch_data[31:8] : prefetch_data[23:0];
    assign pixel_valid = prefetch_valid;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            // The memory-domain error remains authoritative for controller faults.
        end else if (underflow) begin
            // underflow is exported separately; the Top may merge it as 8'h63.
        end
    end

endmodule
