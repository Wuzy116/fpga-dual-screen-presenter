// 讲稿写入（SD 控制域 → SDRAM 存储域）：异步 FIFO + 2 级预取 + 页通告/写完翻转握手 + 按页写 SDRAM。
// 页通告翻转时槽号与行序已稳定（源端在收到写完前不再改动）。每页 PAGE_WORDS 字按 BURST 字一组连续写入
// SCRIPT_BASE + 槽号 * PAGE_WORDS；行序自下而上时第 0 个文件行写到页内最后一行（每行 ROW_WORDS 字）。
// 只在 FIFO 读侧已有 >= BURST 字时发起 burst（预取级另存至多 2 字），保证 burst 内每拍都有数据；
// 页数据后的 PAD_WORDS 个填充字读出丢弃。写完且控制器连续 4 拍不忙后翻转 page_done。
// 仲裁接口与 media_frame_loader 相同：burst_hold=1 时不发起新 burst，已开始的 burst 写完为止。
// 首页之前先用一个 16 字 burst 在 CAL_ADDR 写 4 组校准字 CAL0~CAL3（讲稿区之后的空闲区，每组落在一个 SDRAM bank），
// 供 prompter_script_reader 判定控制器读数据相对 Sdr_rd_en 的超前拍数（板上实测读数据比有效标志早一拍）。
module prompter_script_writer #(
    parameter integer ADDR_WIDTH  = 21,
    parameter [ADDR_WIDTH-1:0] SCRIPT_BASE = 1536000,
    parameter integer PAGE_WORDS  = 9600,
    parameter integer ROW_WORDS   = 20,
    parameter integer ROWS        = 480,
    parameter integer BURST       = 128,
    parameter integer PAD_WORDS   = 2,
    parameter integer FIFO_AW     = 9,
    parameter [ADDR_WIDTH-1:0] CAL_ADDR = SCRIPT_BASE + 58 * PAGE_WORDS
)(
    // 源端（SD 控制域）
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  fifo_we,
    input  wire [31:0]           fifo_di,
    output wire [FIFO_AW-1:0]    fifo_wrusedw,
    input  wire                  page_toggle,
    input  wire [5:0]            page_slot,
    input  wire                  page_top_down,
    output wire                  page_done,          // 单拍，wr_clk 域
    // 存储域
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_busy,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [31:0]           app_wr_data,
    input  wire                  burst_hold,
    output wire                  burst_request,
    output wire                  burst_idle,
    output reg  [5:0]            pages_written,
    output reg                   underrun            // 粘滞：burst 中预取级无数据（不应发生）
);
    localparam [2:0] M_IDLE = 3'd0, M_BASE = 3'd1, M_RUN = 3'd2, M_PAD = 3'd3, M_DRAIN = 3'd4, M_CAL = 3'd5;
    function [31:0] cal_word(input [1:0] i);
        case (i)
            2'd0: cal_word = 32'h5AC3_0F81; 2'd1: cal_word = 32'hA53C_F042;
            2'd2: cal_word = 32'h3C5A_96E3; default: cal_word = 32'hC3A5_6924;
        endcase
    endfunction
    localparam [ADDR_WIDTH-1:0] FLIP_FIRST = (ROWS - 1) * ROW_WORDS;
    localparam [ADDR_WIDTH-1:0] FLIP_JUMP  = ROW_WORDS * 2 - 1;

    // ---------------- 异步 FIFO + 预取 ----------------
    // FIFO 复位专用寄存器（同 media_pixel_cdc）：写域复位异步置位，存储域复位两拍同步进写域后同步置位。
    // 只驱动 FIFO 内两组复位同步器，避免全局复位网经组合门直达读侧同步器（clk->ext_mem_clk 偏斜 1.9 ns）。
    (* ASYNC_REG="TRUE" *) reg [1:0] mem_rst_n_wr;
    reg fifo_rst;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            mem_rst_n_wr <= 2'b00;
            fifo_rst <= 1'b1;
        end else begin
            mem_rst_n_wr <= {mem_rst_n_wr[0], mem_rst_n};
            fifo_rst <= !mem_rst_n_wr[1];
        end
    end
    wire [31:0] raw_data;
    wire        raw_valid, raw_empty, raw_read_en;
    wire [FIFO_AW-1:0] rdusedw;
    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32), .ADDR_WIDTH_W(FIFO_AW), .ADDR_WIDTH_R(FIFO_AW),
        .AL_FULL_NUM((1 << FIFO_AW) - 3), .AL_EMPTY_NUM(2), .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_fifo (
        .rst(fifo_rst), .clkw(wr_clk), .clkr(mem_clk),
        .we(fifo_we), .di(fifo_di), .re(raw_read_en), .dout(raw_data), .valid(raw_valid),
        .full_flag(), .empty_flag(raw_empty), .afull(), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw(rdusedw)
    );
    wire        pf_valid;
    wire [31:0] pf_data;
    wire        pop;
    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(mem_clk), .rst(!mem_rst_n),
        .raw_empty(raw_empty), .raw_valid(raw_valid), .raw_data(raw_data),
        .raw_read_en(raw_read_en), .consume(pop),
        .out_valid(pf_valid), .out_empty(), .out_data(pf_data)
    );

    // ---------------- 页通告同步（翻转 + 两级） ----------------
    reg [2:0] page_sync;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) page_sync <= 3'b000;
        else            page_sync <= {page_sync[1:0], page_toggle};
    end
    wire page_start = page_sync[2] ^ page_sync[1];
    // 页参数在翻转前已稳定多拍：先原样打一拍进 mem 域，跨域路径上不带组合逻辑（地址选择在本域内做）
    reg       top_down_m;
    reg [5:0] slot_m;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin top_down_m <= 1'b0; slot_m <= 6'd0; end
        else            begin top_down_m <= page_top_down; slot_m <= page_slot; end
    end

    reg done_toggle;
    reg [2:0] done_sync;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) done_sync <= 3'b000;
        else           done_sync <= {done_sync[1:0], done_toggle};
    end
    assign page_done = done_sync[2] ^ done_sync[1];

    // ---------------- 写页 ----------------
    reg [2:0]  state;
    reg [5:0]  slot_q, slot_cnt;
    reg        flip;
    reg [ADDR_WIDTH-1:0] addr;          // 下一个写地址（页基址 + 页内偏移，逐拍维护）
    reg [4:0]  col;
    reg [13:0] words_left;
    reg [7:0]  burst_left;
    reg        burst_active;
    reg [1:0]  pad_left;
    reg [2:0]  quiet;
    reg        cal_done, cal_active;
    reg [3:0]  cal_cnt;

    assign burst_request = ((state == M_RUN) && !burst_active && words_left != 0 && rdusedw >= BURST) ||
                           ((state == M_CAL) && !cal_active);
    wire   start_burst = burst_request && !burst_hold;
    assign burst_idle = !burst_active && !cal_active && !app_wr_en;
    assign pop = (burst_active && pf_valid) || (state == M_PAD && pad_left != 2'd0 && pf_valid);

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            state <= M_IDLE; slot_q <= 6'd0; slot_cnt <= 6'd0; flip <= 1'b0;
            addr <= {ADDR_WIDTH{1'b0}}; col <= 5'd0;
            words_left <= 14'd0; burst_left <= 8'd0; burst_active <= 1'b0; pad_left <= 2'd0;
            quiet <= 3'd0; done_toggle <= 1'b0;
            cal_done <= 1'b0; cal_active <= 1'b0; cal_cnt <= 4'd0;
            app_wr_en <= 1'b0; app_wr_addr <= {ADDR_WIDTH{1'b0}}; app_wr_data <= 32'd0;
            pages_written <= 6'd0; underrun <= 1'b0;
        end else begin
            app_wr_en <= 1'b0;
            if (app_wr_en || controller_busy) quiet <= 3'd0;
            else if (quiet != 3'd4)            quiet <= quiet + 3'd1;
            case (state)
                M_IDLE: if (page_start) begin
                    slot_q <= slot_m;
                    flip <= !top_down_m;
                    slot_cnt <= 6'd0;
                    addr <= SCRIPT_BASE + (top_down_m ? {ADDR_WIDTH{1'b0}} : FLIP_FIRST);
                    state <= cal_done ? M_BASE : M_CAL;
                end
                // 首地址 = SCRIPT_BASE + 槽号 * PAGE_WORDS (+ 翻转时最后一行)，逐拍累加，避免乘法器
                M_BASE: if (slot_cnt == slot_q) begin
                    col <= 5'd0;
                    words_left <= PAGE_WORDS;
                    state <= M_RUN;
                end else begin
                    addr <= addr + PAGE_WORDS;
                    slot_cnt <= slot_cnt + 6'd1;
                end
                M_RUN: begin
                    if (start_burst) begin
                        burst_active <= 1'b1;
                        burst_left <= BURST;
                    end
                    if (burst_active) begin
                        if (!pf_valid) underrun <= 1'b1;
                        if (pf_valid) begin
                            app_wr_en <= 1'b1;
                            app_wr_addr <= addr;
                            app_wr_data <= pf_data;
                            words_left <= words_left - 14'd1;
                            col <= (col == ROW_WORDS - 1) ? 5'd0 : col + 5'd1;
                            addr <= (flip && col == ROW_WORDS - 1) ? addr - FLIP_JUMP : addr + 1'b1;
                            if (burst_left == 8'd1) begin
                                burst_active <= 1'b0;
                                if (words_left == 14'd1) begin
                                    pad_left <= PAD_WORDS;
                                    state <= M_PAD;
                                end
                            end
                            burst_left <= burst_left - 8'd1;
                        end
                    end
                end
                M_CAL: begin
                    if (start_burst) begin
                        cal_active <= 1'b1; cal_cnt <= 4'd0;
                    end
                    if (cal_active) begin
                        app_wr_en <= 1'b1;
                        app_wr_addr <= CAL_ADDR + cal_cnt;
                        app_wr_data <= cal_word(cal_cnt[1:0]);
                        cal_cnt <= cal_cnt + 4'd1;
                        if (cal_cnt == 4'd15) begin
                            cal_active <= 1'b0; cal_done <= 1'b1;
                            state <= M_BASE;
                        end
                    end
                end
                M_PAD: if (pad_left == 2'd0) begin
                    state <= M_DRAIN;
                end else if (pf_valid) begin
                    pad_left <= pad_left - 2'd1;
                end
                M_DRAIN: if (quiet == 3'd4) begin
                    done_toggle <= !done_toggle;
                    pages_written <= pages_written + 6'd1;
                    state <= M_IDLE;
                end
                default: state <= M_IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if (PAGE_WORDS % BURST != 0 || PAD_WORDS < 2 || PAD_WORDS > 3 || CAL_ADDR % 16 != 0) begin
        $display("PROMPTER_CONFIG_ERROR %m: PAGE_WORDS must be a multiple of BURST, PAD_WORDS 2..3, CAL_ADDR 16-aligned");
        $finish;
    end
    always @(posedge mem_clk) if (mem_rst_n && burst_active && !pf_valid) begin
        $display("FATAL: %m prefetch empty inside a write burst");
        $finish;
    end
    // synthesis translate_on
endmodule
