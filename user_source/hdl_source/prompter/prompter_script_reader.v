// 提词屏讲稿读取 + 显示（阶段 2.4）。讲稿区每行 ROW_WORDS 个 32 位字，bit31 为最左像素，1 = 墨迹。
// 像素域：两行乒乓缓冲，提前两行请求。场同步下降沿锁存 enable / 窗口起点并请求第 0 行（缓冲 0），
//   第 0 行读回后再请求第 1 行（缓冲 1），两次请求串行；行 y 显示完后请求行 y+2 装入刚空出的缓冲 y[0]，每行有一整行时间。
//   讲稿行号 = 窗口起点 + 屏幕行（17 位求和），超出 TOTAL_ROWS 的行显示为空白（BG）。
// 存储域：每个请求用一次 4 + ROW_WORDS 字读 burst 取回（校准字 + 本行，见下）；burst 经仲裁器写方通道发起（burst_request/hold/idle），
//   因此只在帧读取器空闲（无进行中 burst、在途读已返回）时插入。从发起到全部返回字收到，
//   rd_steal=1 且 burst_idle=0：顶层据此把 SDRAM 返回数据只交给本模块，仲裁器也不会提前交回总线。
// 跨域：请求/完成用翻转握手；行号、槽号等多位量在目的域先无条件寄存一拍，翻转到达时早已稳定。
//   每个请求带 4 位序号，完成时回带；只有序号等于该缓冲最近一次请求的序号才置就绪。带宽不足时迟到的
//   完成（缓冲已改派给后面的行）因此被丢弃，迟到行显示为空白而不是别的行（late_row 置位）。
// enable=0 的帧不发任何读请求（讲稿装好前不访问 SDRAM）。
// 读数据对齐自校准：板上控制器的 Sdr_rd_dout 比 Sdr_rd_en 早一拍（仿真模型则对齐）。每次 burst 先读 CAL_ADDR 处
//   由 prompter_script_writer 写好的一组 4 个校准字，再读本行 ROW_WORDS 字；按首个校准字出现在有效拍还是前一拍
//   选定本 burst 取当拍数据或前一拍数据，其余校准字须全部吻合，否则本行作废（显示空白、late_row 置位）。
//   校准字共 4 组、分处 4 个 bank；取行首 4 字组所在 bank 的前一个 bank 那组，使访问顺序与连续地址相同
//   （bank b-1, b, b+1, ...）。控制器每组用 ACT + 自动预充电读，同 bank 紧接着换行会读到旧行（板上实测）。
// 输出比输入晚 1 拍（与 prompter_test_pattern 相同）：墨迹 ink_rgb，其余 bg_rgb；enable=0 时透传 rgb_in。
// 选页焦点框（D20/D21）：box_on=1 时在 box_grid x box_grid 格（2..5，每格 (640/G)x(480/G)）第 box_cell 格四周 2 像素内
//   墨迹/背景互换，帧边界锁存；
//   迟到行仍整行空白。
// 逐行高亮（D24，HIGHLIGHT=1）：屏幕第 HL_ROW 行为固定阅读线。讲稿按 script_to_bmp 的排版（每页第 LINE_TOP 行起、行距 LINE_PITCH、
//   LINES 行）分成行槽，槽 = 文字行上方 BAND_OFS 行起的 LINE_PITCH 行；阅读线所在的行槽整条显示为 HL_INK 字、HL_BG 底。
//   阅读线落在页上 / 下边距时高亮本页 / 下一页的第 1 行。滚动时文字上移，高亮随之逐行跳到下一行。帧边界锁存窗口后在场消隐内
//   用逐次减法算出高亮槽的屏幕起始行（不用除法器）；选页（box_on）与 enable=0 时不高亮。
module prompter_script_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter [ADDR_WIDTH-1:0] SCRIPT_BASE = 1536000,
    parameter integer ROW_WORDS = 20,
    parameter integer ROWS = 480,
    parameter integer TOTAL_ROWS = 58 * 480,
    parameter [ADDR_WIDTH-1:0] CAL_ADDR = SCRIPT_BASE + TOTAL_ROWS * ROW_WORDS,
    parameter integer HIGHLIGHT = 0,
    parameter integer HL_ROW = 160,
    parameter integer LINE_TOP = 40,
    parameter integer LINE_PITCH = 40,
    parameter integer LINES = 10,
    parameter integer BAND_OFS = 4,
    parameter [23:0] HL_INK = 24'hffd400,
    parameter [23:0] HL_BG = 24'h303030
)(
    // 像素域
    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  enable,               // 帧边界锁存：1 显示讲稿，0 透传
    input  wire [15:0]           window_row,           // 窗口起点（讲稿区行号），帧边界锁存
    input  wire [23:0]           ink_rgb,
    input  wire [23:0]           bg_rgb,
    input  wire                  hs_in,                // 低有效
    input  wire                  vs_in,                // 低有效
    input  wire                  de_in,
    input  wire [23:0]           rgb_in,
    input  wire                  box_on,
    input  wire [4:0]            box_cell,       // 0..G*G-1，按行编号
    input  wire [2:0]            box_grid,       // 总览网格边长 2..5
    output reg                   hs_out,
    output reg                   vs_out,
    output reg                   de_out,
    output reg  [23:0]           rgb_out,
    output reg                   late_row,             // 粘滞：某行开始显示时其数据尚未读回
    // 存储域
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,
    input  wire                  burst_hold,
    output wire                  burst_request,
    output wire                  burst_idle,
    output wire                  rd_steal
);
    // ---------------- 像素域：坐标、帧锁存、行请求 ----------------
    reg        vs_q, de_q;
    reg [9:0]  x;                   // 本行已过的有效像素数
    reg [8:0]  y;
    reg        en_f, pre1;
    reg [15:0] win_f;
    reg        req_toggle;
    reg [15:0] req_row;             // 讲稿区行号；16'hffff 表示空白行
    reg        req_slot;
    reg [3:0]  req_tag, tag0, tag1;     // 本次请求序号；各缓冲最近一次请求的序号
    reg        done_toggle, done_slot, done_bad;  // 存储域：每装好一行翻转一次，及其槽号、校准失败标志、序号
    reg [3:0]  done_tag;
    wire frame_edge = vs_q && !vs_in;
    wire line_end = de_q && !de_in;
    function [15:0] clip(input [16:0] r);
        clip = (r < TOTAL_ROWS) ? r[15:0] : 16'hffff;
    endfunction
    // 完成翻转同步（done_slot/done_tag 在翻转前已稳定，先寄存一拍）
    reg [2:0] done_sync;
    reg       done_slot_p;
    reg [3:0] done_tag_p;
    reg       done_bad_p;
    reg [1:0] ready;                // 两半缓冲各自是否装好当前帧的对应行
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            done_sync <= 3'b000; done_slot_p <= 1'b0; done_tag_p <= 4'd0; done_bad_p <= 1'b0;
        end else begin
            done_sync <= {done_sync[1:0], done_toggle};
            done_slot_p <= done_slot; done_tag_p <= done_tag; done_bad_p <= done_bad;
        end
    end
    wire done_ok = (done_sync[2] ^ done_sync[1]) && (done_tag_p == (done_slot_p ? tag1 : tag0));
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            vs_q <= 1'b1; de_q <= 1'b0; x <= 10'd0; y <= 9'd0;
            en_f <= 1'b0; pre1 <= 1'b0; win_f <= 16'd0;
            req_toggle <= 1'b0; req_row <= 16'd0; req_slot <= 1'b0;
            req_tag <= 4'd0; tag0 <= 4'd0; tag1 <= 4'd0;
        end else begin
            vs_q <= vs_in; de_q <= de_in;
            x <= de_in ? x + 10'd1 : 10'd0;
            if (frame_edge) begin
                en_f <= enable; win_f <= window_row; y <= 9'd0; pre1 <= enable;
                if (enable) begin
                    req_row <= clip({1'b0, window_row}); req_slot <= 1'b0; req_toggle <= !req_toggle;
                    req_tag <= req_tag + 4'd1; tag0 <= req_tag + 4'd1;
                end
            end else if (pre1 && done_ok) begin
                pre1 <= 1'b0;
                req_row <= clip({1'b0, win_f} + 17'd1); req_slot <= 1'b1; req_toggle <= !req_toggle;
                req_tag <= req_tag + 4'd1; tag1 <= req_tag + 4'd1;
            end else if (line_end) begin
                y <= y + 9'd1;
                if (en_f && y < ROWS - 2) begin
                    req_row <= clip({1'b0, win_f} + {8'd0, y} + 17'd2); req_slot <= y[0]; req_toggle <= !req_toggle;
                    req_tag <= req_tag + 4'd1;
                    if (y[0]) tag1 <= req_tag + 4'd1; else tag0 <= req_tag + 4'd1;
                end
            end
        end
    end

    // ---------------- 存储域：请求同步与行读 ----------------
    reg [2:0]  req_sync;
    reg [15:0] req_row_m;
    reg        req_slot_m;
    reg [3:0]  req_tag_m;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            req_sync <= 3'b000; req_row_m <= 16'd0; req_slot_m <= 1'b0; req_tag_m <= 4'd0;
        end else begin
            req_sync <= {req_sync[1:0], req_toggle};
            req_row_m <= req_row; req_slot_m <= req_slot; req_tag_m <= req_tag;
        end
    end
    wire req_new = req_sync[2] ^ req_sync[1];
    reg        pending, slot_m;
    reg [3:0]  tag_m;
    reg [ADDR_WIDTH-1:0] row_addr;
    reg [15:0] row_cnt;
    reg [2:0]  m_state;
    localparam [2:0] M_IDLE = 3'd0, M_ADDR = 3'd1, M_REQ = 3'd2, M_ISSUE = 3'd3, M_WAIT = 3'd4, M_BLANK = 3'd5;
    localparam integer CAL_WORDS = 4;
    localparam integer RD_WORDS = ROW_WORDS + CAL_WORDS;
    function [31:0] cal_word(input [1:0] i);   // 与 prompter_script_writer 相同
        case (i)
            2'd0: cal_word = 32'h5AC3_0F81; 2'd1: cal_word = 32'hA53C_F042;
            2'd2: cal_word = 32'h3C5A_96E3; default: cal_word = 32'hC3A5_6924;
        endcase
    endfunction
    reg [4:0]  issued, returned;
    reg [31:0] rd_data_q;           // 前一拍的读数据
    reg        lead, cal_bad;
    wire [31:0] rd_sel = lead ? rd_data_q : sdram_rd_data;
    wire       cal_ok0 = (sdram_rd_data == cal_word(2'd0));
    wire       cal_ok1 = (rd_data_q == cal_word(2'd0));
    wire [4:0] word_idx = returned - 5'd4;              // 本行字号（返回序号去掉 4 个校准字）
    wire [4:0] issue_row = issued - 5'd4;
    wire [1:0] row_bank = row_addr[3:2];
    wire [ADDR_WIDTH-1:0] cal_base = CAL_ADDR + {row_bank - 2'd1, 2'b00};
    // 行缓冲 {槽, 字}：存储域写、像素域寄存读
    reg [31:0] line_mem [0:63] /* fehdl force_ram=1, ram_style="bram" */;
    reg        wr_en_m;
    reg [5:0]  wr_addr_m;
    reg [31:0] wr_data_m;
    always @(posedge mem_clk) if (wr_en_m) line_mem[wr_addr_m] <= wr_data_m;

    assign burst_request = (m_state == M_REQ);
    wire   start_burst = burst_request && !burst_hold;
    assign rd_steal = (m_state == M_ISSUE) || (m_state == M_WAIT);
    assign burst_idle = !rd_steal && !app_rd_en;

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            pending <= 1'b0; slot_m <= 1'b0; tag_m <= 4'd0; row_addr <= {ADDR_WIDTH{1'b0}}; row_cnt <= 16'd0;
            m_state <= M_IDLE; issued <= 5'd0; returned <= 5'd0;
            done_toggle <= 1'b0; done_slot <= 1'b0; done_tag <= 4'd0; done_bad <= 1'b0;
            rd_data_q <= 32'd0; lead <= 1'b0; cal_bad <= 1'b0;
            app_rd_en <= 1'b0; app_rd_addr <= {ADDR_WIDTH{1'b0}};
            wr_en_m <= 1'b0; wr_addr_m <= 6'd0; wr_data_m <= 32'd0;
        end else begin
            app_rd_en <= 1'b0;
            wr_en_m <= 1'b0;
            rd_data_q <= sdram_rd_data;
            if (req_new) pending <= 1'b1;
            case (m_state)
                M_IDLE: if (pending) begin
                    pending <= req_new;
                    slot_m <= req_slot_m; tag_m <= req_tag_m;
                    row_addr <= SCRIPT_BASE;
                    row_cnt <= req_row_m;
                    m_state <= (req_row_m == 16'hffff) ? M_BLANK : M_ADDR;
                    issued <= 5'd0; returned <= 5'd0;
                end
                // 行地址 = SCRIPT_BASE + 行号 * ROW_WORDS：行号按 512/32/1 分解逐拍累加，避免乘法器
                M_ADDR: begin
                    if (row_cnt == 16'd0) begin
                        m_state <= M_REQ;
                    end else if (row_cnt >= 16'd512) begin
                        row_addr <= row_addr + 512 * ROW_WORDS; row_cnt <= row_cnt - 16'd512;
                    end else if (row_cnt >= 16'd32) begin
                        row_addr <= row_addr + 32 * ROW_WORDS; row_cnt <= row_cnt - 16'd32;
                    end else begin
                        row_addr <= row_addr + ROW_WORDS; row_cnt <= row_cnt - 16'd1;
                    end
                end
                M_REQ: if (start_burst) m_state <= M_ISSUE;
                M_ISSUE: begin
                    app_rd_en <= 1'b1;
                    app_rd_addr <= (issued < CAL_WORDS) ? cal_base + issued : row_addr + issue_row;
                    issued <= issued + 5'd1;
                    if (issued == RD_WORDS - 1) m_state <= M_WAIT;
                end
                M_WAIT: ;
                M_BLANK: begin
                    wr_en_m <= 1'b1; wr_addr_m <= {slot_m, issued}; wr_data_m <= 32'd0;
                    issued <= issued + 5'd1;
                    if (issued == ROW_WORDS - 1) begin
                        done_toggle <= !done_toggle; done_slot <= slot_m; done_tag <= tag_m; done_bad <= 1'b0;
                        m_state <= M_IDLE;
                    end
                end
                default: m_state <= M_IDLE;
            endcase
            if (rd_steal && sdram_rd_valid) begin
                returned <= returned + 5'd1;
                if (returned == 5'd0) begin
                    lead <= !cal_ok0 && cal_ok1;
                    cal_bad <= !cal_ok0 && !cal_ok1;
                end else if (returned < CAL_WORDS) begin
                    if (rd_sel != cal_word(returned[1:0])) cal_bad <= 1'b1;
                end else begin
                    wr_en_m <= 1'b1; wr_addr_m <= {slot_m, word_idx}; wr_data_m <= rd_sel;
                end
                if (returned == RD_WORDS - 1) begin
                    done_toggle <= !done_toggle; done_slot <= slot_m; done_tag <= tag_m; done_bad <= cal_bad;
                    m_state <= M_IDLE;
                end
            end
        end
    end
    // synthesis translate_off
    initial if (ROW_WORDS + CAL_WORDS > 32 || ROW_WORDS % 4 != 0 || ROWS > 512 || ROWS < 2 || CAL_ADDR % 16 != 0 || SCRIPT_BASE % 4 != 0) begin
        $display("PROMPTER_CONFIG_ERROR %m: ROW_WORDS <= 28 and a multiple of 4, 2 <= ROWS <= 512, CAL_ADDR 16-aligned");
        $finish;
    end
    // synthesis translate_on

    // ---------------- 像素域：显示 ----------------
    wire       cur_slot = y[0];
    wire [9:0] x_next = de_in ? x + 10'd1 : 10'd0;
    // 焦点框：格左上角 (cx, cy)，框为格内 2 像素边带；行内判定只用比较器
    // 格宽/高与格号 -> 行列：G 只有 2..5 四种，按 G 查常数表；帧边界寄存，行内只用比较器
    reg        box_f;
    reg [9:0]  bx0, bw;
    reg [8:0]  by0, bh;
    reg [2:0]  b_col, b_row;
    reg [9:0]  b_w;
    reg [8:0]  b_h;
    reg [4:0]  b_cells;
    always @* begin
        case (box_grid)
            3'd2:    begin b_w = 10'd320; b_h = 9'd240; b_cells = 5'd4;  b_col = {2'd0, box_cell[0]};  b_row = {1'b0, box_cell[2:1]}; end
            3'd3:    begin b_w = 10'd213; b_h = 9'd160; b_cells = 5'd9;  b_col = box_cell % 5'd3;      b_row = box_cell / 5'd3; end
            3'd4:    begin b_w = 10'd160; b_h = 9'd120; b_cells = 5'd16; b_col = {1'b0, box_cell[1:0]}; b_row = box_cell[4:2]; end
            default: begin b_w = 10'd128; b_h = 9'd96;  b_cells = 5'd25; b_col = box_cell % 5'd5;      b_row = box_cell / 5'd5; end
        endcase
    end
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin box_f <= 1'b0; bx0 <= 10'd0; by0 <= 9'd0; bw <= 10'd128; bh <= 9'd96; end
        else if (frame_edge) begin
            box_f <= box_on && box_cell < b_cells;
            bx0 <= b_col * b_w; by0 <= b_row * b_h; bw <= b_w; bh <= b_h;
        end
    end
    wire       in_cx = (x >= bx0) && (x < bx0 + bw);
    wire       in_cy = (y >= by0) && (y < by0 + bh);
    wire       edge_x = (x < bx0 + 10'd2) || (x >= bx0 + bw - 10'd2);
    wire       edge_y = (y < by0 + 9'd2) || (y >= by0 + bh - 9'd2);
    wire       on_box = box_f && in_cx && in_cy && (edge_x || edge_y);
    // ---------------- 逐行高亮：场消隐内算高亮槽的屏幕起始行 ----------------
    localparam integer SLOT0 = LINE_TOP - BAND_OFS;            // 页内第 1 个行槽的起始行
    localparam integer SLOT_END = SLOT0 + LINE_PITCH * LINES;  // 页内行槽区的结束行
    reg [16:0] hl_acc;
    reg [1:0]  hl_st;              // 0 空闲，1 求页内行号（减 ROWS），2 求槽内偏移（减 LINE_PITCH）
    reg [9:0]  hl_y0;              // 高亮槽屏幕起始行
    reg        hl_f;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            hl_acc <= 17'd0; hl_st <= 2'd0; hl_y0 <= 10'd0; hl_f <= 1'b0;
        end else if (!HIGHLIGHT) begin
            hl_f <= 1'b0;
        end else if (frame_edge) begin
            hl_acc <= {1'b0, window_row} + HL_ROW; hl_st <= 2'd1; hl_f <= 1'b0;
        end else case (hl_st)
            2'd1: if (hl_acc >= ROWS) hl_acc <= hl_acc - ROWS;
                  else if (hl_acc < SLOT0) begin hl_y0 <= HL_ROW + SLOT0 - hl_acc[9:0]; hl_st <= 2'd0; hl_f <= en_f && !box_f; end
                  else if (hl_acc >= SLOT_END) begin hl_y0 <= HL_ROW + ROWS + SLOT0 - hl_acc[9:0]; hl_st <= 2'd0; hl_f <= en_f && !box_f; end
                  else begin hl_acc <= hl_acc - SLOT0; hl_st <= 2'd2; end
            2'd2: if (hl_acc >= LINE_PITCH) hl_acc <= hl_acc - LINE_PITCH;
                  else begin hl_y0 <= HL_ROW - hl_acc[9:0]; hl_st <= 2'd0; hl_f <= en_f && !box_f; end
            default: ;
        endcase
    end
    // 行内恒定：y 只在行尾变化，寄存一拍落在行消隐内
    reg        band_q;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) band_q <= 1'b0;
        else band_q <= hl_f && ({1'b0, y} >= hl_y0) && ({1'b0, y} < hl_y0 + LINE_PITCH);
    end
    wire [23:0] ink_c = band_q ? HL_INK : ink_rgb;
    wire [23:0] bg_c  = band_q ? HL_BG : bg_rgb;
    reg [31:0] word_q;              // 恒为像素 x 所在的字：上一拍按 x_next 预读
    always @(posedge pix_clk) word_q <= line_mem[{cur_slot, x_next[9:5]}];
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            ready <= 2'b00; late_row <= 1'b0;
            hs_out <= 1'b1; vs_out <= 1'b1; de_out <= 1'b0; rgb_out <= 24'd0;
        end else begin
            if (frame_edge) ready <= 2'b00;
            else begin
                if (done_ok && !done_bad_p) ready[done_slot_p] <= 1'b1;
                if (line_end) ready[cur_slot] <= 1'b0;
            end
            if (de_in && x == 10'd0 && en_f && !ready[cur_slot]) late_row <= 1'b1;
            hs_out <= hs_in; vs_out <= vs_in; de_out <= de_in;
            rgb_out <= !de_in ? 24'd0 :
                       !en_f ? rgb_in :
                       (ready[cur_slot] && (word_q[5'd31 - x[4:0]] ^ on_box)) ? ink_c : bg_c;   // 迟到行整行空白（不画框）
        end
    end
endmodule
