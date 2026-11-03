// 讲稿装载（SD 控制域）：start 上升后分两遍把有效的 SnPmm.BMP 依次装入页槽 0..MAX_PAGES-1（D16）：
// 第一遍按键序装全部讲稿页（mm=1..15），第二遍装各节总览页（mm=0）。讲稿页因此连续存放在槽 0..scripts-1，
// 翻页/滚动只在其中进行；总览页在其后，只供选页跳转。键 {n-1, mm}（D19：n=1~5，键 0..79）；总览页另记槽号与有效位，
// 不计入该节页数。
// script_slots 为讲稿页（不含总览）槽数。
// 每页：发起文件流 → 校验 1 位 BMP 头（BM、偏移 62、40 字节信息头、640x±480、1 平面 1 位、无压缩、两色调色板亮度不同）
// → 通告页（槽号、行序）→ 像素字节每 4 个拼成一字（首字节在高位，即 bit31 为最左像素），反色使墨迹 = 1，写入异步 FIFO。
// 头不合格、FAT 链出错或看门狗超时的页照样写满 PAGE_WORDS 个 0（空白页），保证槽号与文件顺序一致。
// 每页数据后再补 PAD_WORDS 个填充字（写入器丢弃），使写入器的最后一个 burst 不会卡在预取级；页写完由 page_done 通知。
module prompter_script_loader #(
    parameter integer MAX_PAGES  = 55,
    parameter integer PAGE_WORDS = 9600,
    parameter integer PAD_WORDS  = 2,
    parameter integer FIFO_AW    = 9,
    parameter integer HOLD_LEVEL = 368,      // FIFO 已用 >= 此值时暂停读卡（在途扇区 128 字仍放得下）
    parameter integer STALL_CYCLES = 25_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,                // 电平：预加载完成后保持为高
    input  wire [79:0] script_valid,
    // fat32_bmp_read 讲稿流
    output reg         file_start,
    output reg  [6:0]  file_key,
    output wire        file_hold,
    output reg         file_stop,
    input  wire        file_busy,
    input  wire        file_done,
    input  wire [7:0]  file_error,
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    // 异步 FIFO 写侧
    output reg         fifo_we,
    output reg  [31:0] fifo_di,
    input  wire [FIFO_AW-1:0] fifo_wrusedw,
    // 页通告（翻转）与写完通知（单拍，已同步到本域）
    output reg         page_toggle,
    output reg  [5:0]  page_slot,
    output reg         page_top_down,
    input  wire        page_done,
    // 状态
    output wire        busy,
    output reg         done,
    output reg  [5:0]  pages_loaded,
    output reg  [5:0]  pages_failed,
    output reg  [5:0]  script_slots,      // 讲稿页（不含总览页）槽数；装完时有效
    output reg  [29:0] section_first,        // {s5..s1}，各 6 位：该节首个讲稿页槽号
    output reg  [24:0] section_pages,        // {s5..s1}，各 5 位：该节讲稿页数（不含总览页）
    output reg  [29:0] section_overview,     // {s5..s1}，各 6 位：该节总览页槽号
    output reg  [4:0]  overview_valid        // 各节是否装入了总览页
);
    localparam [3:0] S_IDLE = 4'd0, S_FIND = 4'd1, S_START = 4'd2, S_STREAM = 4'd3, S_STOP = 4'd4,
                     S_FILL = 4'd5, S_WAIT = 4'd6, S_DONE = 4'd7;
    localparam integer HDR_BYTES = 62;
    reg [3:0]  state;
    reg        start_q;
    reg [6:0]  key;                 // 0..80
    reg        pass2;               // 0：装讲稿页；1：装总览页
    reg [15:0] byte_cnt;
    reg [13:0] word_cnt;            // 已写数据字（不含填充）
    reg [1:0]  pad_cnt;
    reg [23:0] acc;
    reg        announced, bad, invert;
    reg [24:0] stall;

    // ---------------- 头解析：字节偏移 0..61，逐字节比对期望值，只保留错误标志、行序与调色板亮度 ----------------
    // 期望：BM、偏移 62、信息头 40、宽 640、高 480（或 -480）、1 平面、1 位、无压缩
    function [7:0] expect_byte;
        input [5:0] a;
        case (a)
            6'd0: expect_byte = "B";   6'd1: expect_byte = "M";
            6'd10: expect_byte = 8'd62; 6'd14: expect_byte = 8'd40;
            6'd18: expect_byte = 8'h80; 6'd19: expect_byte = 8'h02;
            6'd26: expect_byte = 8'd1;  6'd28: expect_byte = 8'd1;
            default: expect_byte = 8'd0;
        endcase
    endfunction
    function checked;      // 需要与期望值相等的偏移（高度 22..25 另判）
        input [5:0] a;
        checked = (a <= 6'd1) || (a >= 6'd10 && a <= 6'd21) || (a >= 6'd26 && a <= 6'd33);
    endfunction
    reg        hdr_err, h_neg;
    reg [9:0]  lum0, lum1;              // B + 2G + R
    wire [5:0] hb = byte_cnt[5:0];
    wire hdr_ok_now = !hdr_err && (lum0 != lum1);
    // 高度字节：480 = e0 01 00 00，-480 = 20 fe ff ff
    wire h_byte_ok = (hb == 6'd22) ? (byte_data == 8'he0 || byte_data == 8'h20) :
                     (hb == 6'd23) ? (h_neg ? byte_data == 8'hfe : byte_data == 8'h01) :
                                     (h_neg ? byte_data == 8'hff : byte_data == 8'h00);

    wire fifo_room = fifo_wrusedw < (1 << FIFO_AW) - 8;
    assign file_hold = fifo_wrusedw >= HOLD_LEVEL;
    assign busy = (state != S_IDLE) && (state != S_DONE);

    always @(posedge clk) begin
        if (state == S_START) begin
            hdr_err <= 1'b0; h_neg <= 1'b0; lum0 <= 10'd0; lum1 <= 10'd0;
        end else if (state == S_STREAM && byte_valid && byte_cnt < HDR_BYTES) begin
            if (checked(hb) && byte_data != expect_byte(hb)) hdr_err <= 1'b1;
            if (hb == 6'd22) h_neg <= byte_data == 8'h20;
            if (hb >= 6'd22 && hb <= 6'd25 && !h_byte_ok) hdr_err <= 1'b1;
            case (hb)
                6'd54, 6'd56: lum0 <= lum0 + {2'b00, byte_data};
                6'd55:        lum0 <= lum0 + {1'b0, byte_data, 1'b0};
                6'd58, 6'd60: lum1 <= lum1 + {2'b00, byte_data};
                6'd59:        lum1 <= lum1 + {1'b0, byte_data, 1'b0};
                default: ;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE; start_q <= 1'b0; key <= 7'd0; pass2 <= 1'b0; script_slots <= 6'd0;
            byte_cnt <= 16'd0; word_cnt <= 14'd0; pad_cnt <= 2'd0; acc <= 24'd0;
            announced <= 1'b0; bad <= 1'b0; invert <= 1'b0; stall <= 25'd0;
            file_start <= 1'b0; file_key <= 7'd0; file_stop <= 1'b0;
            fifo_we <= 1'b0; fifo_di <= 32'd0;
            page_toggle <= 1'b0; page_slot <= 6'd0; page_top_down <= 1'b0;
            done <= 1'b0; pages_loaded <= 6'd0; pages_failed <= 6'd0;
            section_first <= 30'd0; section_pages <= 25'd0;
            section_overview <= 30'd0; overview_valid <= 5'd0;
        end else begin
            start_q <= start;
            file_start <= 1'b0;
            fifo_we <= 1'b0;
            case (state)
                S_IDLE: if (start && !start_q) begin
                    key <= 7'd0; pass2 <= 1'b0; script_slots <= 6'd0;
                    pages_loaded <= 6'd0; pages_failed <= 6'd0;
                    section_first <= 30'd0; section_pages <= 25'd0;
                    section_overview <= 30'd0; overview_valid <= 5'd0;
                    state <= S_FIND;
                end
                // 每拍检查一个键；槽满或键扫完即结束
                S_FIND: begin
                    if (pages_loaded == MAX_PAGES || (key == 7'd80 && pass2)) begin
                        done <= 1'b1;
                        state <= S_DONE;
                    end else if (key == 7'd80) begin
                        key <= 7'd0; pass2 <= 1'b1; script_slots <= pages_loaded;
                    end else if (script_valid[key] && ((key[3:0] == 4'd0) == pass2)) begin
                        file_key <= key;
                        state <= S_START;
                    end else begin
                        key <= key + 7'd1;
                    end
                end
                S_START: if (!file_busy) begin
                    file_start <= 1'b1;
                    byte_cnt <= 16'd0; word_cnt <= 14'd0; pad_cnt <= 2'd0;
                    announced <= 1'b0; bad <= 1'b0; stall <= 25'd0;
                    page_slot <= pages_loaded;
                    page_top_down <= 1'b0;
                    state <= S_STREAM;
                end
                S_STREAM: begin
                    if (byte_valid) begin
                        stall <= 25'd0;
                        byte_cnt <= byte_cnt + 16'd1;
                        if (byte_cnt == HDR_BYTES - 1) begin
                            // 本拍是最后一个头字节（偏移 61，调色板 1 的保留字节），所需字段都已锁存
                            bad <= !hdr_ok_now;
                            invert <= lum0 < lum1;
                            page_top_down <= h_neg;
                            page_toggle <= !page_toggle;
                            announced <= 1'b1;
                        end else if (byte_cnt >= HDR_BYTES && word_cnt != PAGE_WORDS) begin
                            if (byte_cnt[1:0] == 2'd1) begin     // 偏移 62 + 4k + 3：一字凑齐
                                fifo_we <= 1'b1;
                                fifo_di <= bad ? 32'd0 : ({acc, byte_data} ^ {32{invert}});
                                word_cnt <= word_cnt + 14'd1;
                            end else begin
                                acc <= {acc[15:0], byte_data};
                            end
                        end
                    end else if (file_busy && !file_hold && stall != STALL_CYCLES - 1) begin   // 反压期间不计时
                        stall <= stall + 25'd1;
                    end
                    if (file_done) begin
                        if (file_error != 8'd0 || word_cnt != PAGE_WORDS || bad || !announced)
                            pages_failed <= pages_failed + 6'd1;
                        if (word_cnt != PAGE_WORDS || !announced) bad <= 1'b1;
                        if (!announced) page_toggle <= !page_toggle;
                        announced <= 1'b1;
                        state <= S_FILL;
                    end else if (stall == STALL_CYCLES - 1) begin
                        file_stop <= 1'b1;
                        state <= S_STOP;
                    end
                end
                // 看门狗：中止文件流，等读取器空闲后按坏页补齐
                S_STOP: if (!file_busy) begin
                    file_stop <= 1'b0;
                    pages_failed <= pages_failed + 6'd1;
                    bad <= 1'b1;
                    if (!announced) page_toggle <= !page_toggle;
                    announced <= 1'b1;
                    state <= S_FILL;
                end
                // 补齐剩余数据字（坏页为 0）和填充字
                S_FILL: if (fifo_room && !fifo_we) begin
                    fifo_we <= 1'b1;
                    fifo_di <= 32'd0;
                    if (word_cnt != PAGE_WORDS) begin
                        word_cnt <= word_cnt + 14'd1;
                    end else if (pad_cnt == PAD_WORDS - 1) begin
                        state <= S_WAIT;
                    end else begin
                        pad_cnt <= pad_cnt + 2'd1;
                    end
                end
                S_WAIT: if (page_done) begin
                    pages_loaded <= pages_loaded + 6'd1;
                    if (key[3:0] == 4'd0) begin
                        overview_valid[key[6:4]] <= 1'b1;
                        case (key[6:4])
                            3'd0: section_overview[5:0]   <= pages_loaded;
                            3'd1: section_overview[11:6]  <= pages_loaded;
                            3'd2: section_overview[17:12] <= pages_loaded;
                            3'd3: section_overview[23:18] <= pages_loaded;
                            default: section_overview[29:24] <= pages_loaded;
                        endcase
                    end else case (key[6:4])
                        3'd0: begin if (section_pages[4:0] == 5'd0)   section_first[5:0]   <= pages_loaded; section_pages[4:0]   <= section_pages[4:0]   + 5'd1; end
                        3'd1: begin if (section_pages[9:5] == 5'd0)   section_first[11:6]  <= pages_loaded; section_pages[9:5]   <= section_pages[9:5]   + 5'd1; end
                        3'd2: begin if (section_pages[14:10] == 5'd0) section_first[17:12] <= pages_loaded; section_pages[14:10] <= section_pages[14:10] + 5'd1; end
                        3'd3: begin if (section_pages[19:15] == 5'd0) section_first[23:18] <= pages_loaded; section_pages[19:15] <= section_pages[19:15] + 5'd1; end
                        default: begin if (section_pages[24:20] == 5'd0) section_first[29:24] <= pages_loaded; section_pages[24:20] <= section_pages[24:20] + 5'd1; end
                    endcase
                    key <= key + 7'd1;
                    state <= S_FIND;
                end
                S_DONE: if (!start) begin
                    done <= 1'b0;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
