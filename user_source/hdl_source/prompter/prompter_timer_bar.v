// 提词屏计时条：总用时、剩余倒计时（到 0 后变红并转为 "+" 正计超时时长），均为 MM:SS，99:59 封顶；
// 最后一栏为讲稿页码“页 NN/NN”（D21：当前页 / 总页数，两位十进制，总页数为 0 时空白）。
// 只叠加在提词屏视频流上（应放在整行镜像之前）；输入 hs/vs/de/rgb，输出整体晚 3 拍。
// 计数按 CLK_HZ 拍为 1 秒，直接以 BCD 计数；显示值在输入场同步下降沿锁存，一帧内不变。
// run 为高时计时（低电平暂停且保留不足 1 秒的部分）；clear 清零全部并重装倒计时目标。page_no/page_total 按帧锁存。
// SHOW_STAGE=1 时最前面 3 格显示时期名（stage 0 = 预备、1 = 演讲）和一个空格，底框加宽 48 像素，stage 同样按帧锁存。
// loading=1（P-12，讲稿后台装载中，同样按帧锁存）时整行改为“载入 NN 页”（NN = load_pages，十进制两位），
// 计时照常进行、只是不显示；SHOW_STAGE=0 时无此功能。
module prompter_timer_bar #(
    parameter integer CLK_HZ    = 25_000_000,
    parameter integer TARGET_MM = 10,          // 倒计时目标 分（0..99）
    parameter integer TARGET_SS = 0,           // 倒计时目标 秒（0..59）
    parameter integer BOX_X     = 288,         // 底框左上角（有效区坐标）；底框 344x24，文字 21 格 x 16 像素
    parameter integer BOX_Y     = 4,
    parameter [23:0]  BOX_RGB    = 24'h000000,
    parameter [23:0]  TEXT_RGB   = 24'hffffff,
    parameter [23:0]  REMAIN_RGB = 24'h40ff40,
    parameter [23:0]  OVER_RGB   = 24'hff3030,
    parameter integer SHOW_STAGE = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run,
    input  wire        clear,
    input  wire [5:0]  page_no,      // 当前页（1 起）
    input  wire [5:0]  page_total,
    input  wire        stage,
    input  wire        loading,
    input  wire [5:0]  load_pages,
    input  wire        hs_in,      // 低有效
    input  wire        vs_in,      // 低有效
    input  wire        de_in,
    input  wire [23:0] rgb_in,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out     // 消隐期恒 0
);
    localparam integer SC = SHOW_STAGE ? 3 : 0;   // 阶段名占用的格数
    localparam integer BOX_W = 344 + 16 * SC, BOX_H = 24;
    localparam integer TEXT_X = BOX_X + 4, TEXT_Y = BOX_Y + 4;
    localparam integer CELLS = 21 + SC;
    localparam [15:0] TARGET_BCD = (TARGET_MM / 10) * 4096 + (TARGET_MM % 10) * 256 +
                                   (TARGET_SS / 10) * 16 + (TARGET_SS % 10);
    localparam [24:0] DIV_LAST = CLK_HZ - 1;

    // synthesis translate_off
    initial begin
        if (TARGET_MM < 0 || TARGET_MM > 99 || TARGET_SS < 0 || TARGET_SS > 59 || CLK_HZ < 1 || CLK_HZ > 33554432) begin
            $display("PROMPTER_CONFIG_ERROR timer %m: TARGET_MM 0..99, TARGET_SS 0..59, CLK_HZ 1..2^25 required");
            $finish;
        end
    end
    // synthesis translate_on

    // ---------------- BCD MM:SS ----------------
    function [15:0] mmss_inc;
        input [15:0] v;
        begin
            mmss_inc = v;
            if (v != 16'h9959) begin
                if (v[3:0] != 4'd9)        mmss_inc[3:0] = v[3:0] + 4'd1;
                else begin
                    mmss_inc[3:0] = 4'd0;
                    if (v[7:4] != 4'd5)    mmss_inc[7:4] = v[7:4] + 4'd1;
                    else begin
                        mmss_inc[7:4] = 4'd0;
                        if (v[11:8] != 4'd9) mmss_inc[11:8] = v[11:8] + 4'd1;
                        else begin
                            mmss_inc[11:8] = 4'd0;
                            mmss_inc[15:12] = v[15:12] + 4'd1;
                        end
                    end
                end
            end
        end
    endfunction
    function [15:0] mmss_dec;   // 调用方保证 v != 0
        input [15:0] v;
        begin
            mmss_dec = v;
            if (v[3:0] != 4'd0)        mmss_dec[3:0] = v[3:0] - 4'd1;
            else begin
                mmss_dec[3:0] = 4'd9;
                if (v[7:4] != 4'd0)    mmss_dec[7:4] = v[7:4] - 4'd1;
                else begin
                    mmss_dec[7:4] = 4'd5;
                    if (v[11:8] != 4'd0) mmss_dec[11:8] = v[11:8] - 4'd1;
                    else begin
                        mmss_dec[11:8] = 4'd9;
                        mmss_dec[15:12] = v[15:12] - 4'd1;
                    end
                end
            end
        end
    endfunction

    // ---------------- 计数 ----------------
    reg [24:0] div;
    reg [15:0] total, remain;
    reg        over;
    wire tick      = run && (div == DIV_LAST);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div <= 25'd0;
            total <= 16'h0000; remain <= TARGET_BCD; over <= 1'b0;
        end else if (clear) begin
            div <= 25'd0;
            total <= 16'h0000; remain <= TARGET_BCD; over <= 1'b0;
        end else begin
            if (run) div <= tick ? 25'd0 : div + 25'd1;
            if (tick) begin
                total <= mmss_inc(total);
                if (over)                 remain <= mmss_inc(remain);
                else if (remain == 16'h0) begin over <= 1'b1; remain <= 16'h0001; end
                else                      remain <= mmss_dec(remain);
            end
        end
    end

    // ---------------- 帧锁存 + 坐标 ----------------
    reg [15:0] total_f, remain_f;
    reg        stage_f, loading_f, page_on_f;
    reg [7:0]  load_bcd_f, pno_bcd_f, ptot_bcd_f;
    function [7:0] bcd2;   // 0..63 -> 两位 BCD
        input [5:0] v;
        reg [5:0] t, o;
        begin t = v / 6'd10; o = v % 6'd10; bcd2 = {t[3:0], o[3:0]}; end
    endfunction
    reg        over_f, vs_q, de_q;
    reg [9:0]  x;
    reg [8:0]  y;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_f <= 16'h0000; remain_f <= TARGET_BCD; over_f <= 1'b0; stage_f <= 1'b0;
            loading_f <= 1'b0; load_bcd_f <= 8'd0; page_on_f <= 1'b0; pno_bcd_f <= 8'd0; ptot_bcd_f <= 8'd0;
            vs_q <= 1'b1; de_q <= 1'b0; x <= 10'd0; y <= 9'd0;
        end else begin
            vs_q <= vs_in; de_q <= de_in;
            if (vs_q && !vs_in) begin
                total_f <= total; remain_f <= remain; over_f <= over; stage_f <= stage;
                loading_f <= SHOW_STAGE && loading; load_bcd_f <= bcd2(load_pages);
                page_on_f <= page_total != 6'd0; pno_bcd_f <= bcd2(page_no); ptot_bcd_f <= bcd2(page_total);
            end
            // 低功耗：列计数只在计时框所在行内走，其他行保持 0（框与文字都只在这些行内命中，输出不变）
            x <= (de_in && y >= BOX_Y && y < BOX_Y + BOX_H) ? x + 10'd1 : 10'd0;
            if (!vs_in)              y <= 9'd0;
            else if (de_q && !de_in) y <= y + 9'd1;
        end
    end

    // ---------------- 第 1 拍：定位 ----------------
    wire [9:0] lx = x - TEXT_X;
    wire [8:0] ly = y - TEXT_Y;
    reg        hs1, vs1, de1, box1, text1;
    reg [23:0] rgb1;
    reg [4:0]  cell1;
    reg [3:0]  col1, row1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs1 <= 1'b1; vs1 <= 1'b1; de1 <= 1'b0; box1 <= 1'b0; text1 <= 1'b0;
            rgb1 <= 24'd0; cell1 <= 5'd0; col1 <= 4'd0; row1 <= 4'd0;
        end else begin
            hs1 <= hs_in; vs1 <= vs_in; de1 <= de_in; rgb1 <= rgb_in;
            box1  <= de_in && x >= BOX_X && x < BOX_X + BOX_W && y >= BOX_Y && y < BOX_Y + BOX_H;
            text1 <= de_in && lx < CELLS * 16 && ly < 16;
            cell1 <= lx[8:4]; col1 <= lx[3:0]; row1 <= ly[3:0];
        end
    end

    // ---------------- 第 2 拍：选字符与颜色 ----------------
    // 字符码：0..9 数字，10 ':'，11 '+'，12 空格，13 '/'，16/17/18 = 总/剩/页，19..22 = 预备演讲，23/24 = 载入
    reg [4:0] code;
    reg [23:0] color;
    wire [4:0] tcell = cell1 - SC[4:0];   // 计时部分的格号；阶段格回绕到 29..31，落入 default
    always @* begin
        color = TEXT_RGB;
        case (tcell)
            5'd0:  code = 5'd16;
            5'd1:  code = {1'b0, total_f[15:12]};
            5'd2:  code = {1'b0, total_f[11:8]};
            5'd3:  code = 5'd10;
            5'd4:  code = {1'b0, total_f[7:4]};
            5'd5:  code = {1'b0, total_f[3:0]};
            5'd7:  code = 5'd17;
            5'd8:  code = over_f ? 5'd11 : 5'd12;
            5'd9:  code = {1'b0, remain_f[15:12]};
            5'd10: code = {1'b0, remain_f[11:8]};
            5'd11: code = 5'd10;
            5'd12: code = {1'b0, remain_f[7:4]};
            5'd13: code = {1'b0, remain_f[3:0]};
            5'd15: code = 5'd18;
            5'd16: code = page_on_f ? {1'b0, pno_bcd_f[7:4]} : 5'd12;
            5'd17: code = page_on_f ? {1'b0, pno_bcd_f[3:0]} : 5'd12;
            5'd18: code = page_on_f ? 5'd13 : 5'd12;
            5'd19: code = page_on_f ? {1'b0, ptot_bcd_f[7:4]} : 5'd12;
            5'd20: code = page_on_f ? {1'b0, ptot_bcd_f[3:0]} : 5'd12;
            default: code = 5'd12;
        endcase
        if (tcell >= 5'd7 && tcell <= 5'd13) color = over_f ? OVER_RGB : REMAIN_RGB;
        if (SHOW_STAGE && cell1 < 5'd2) code = 5'd19 + {3'b000, stage_f, cell1[0]};
        if (loading_f) begin
            color = TEXT_RGB;
            case (cell1)
                5'd0: code = 5'd23;
                5'd1: code = 5'd24;
                5'd3: code = (load_bcd_f[7:4] == 4'd0) ? 5'd12 : {1'b0, load_bcd_f[7:4]};
                5'd4: code = {1'b0, load_bcd_f[3:0]};
                5'd6: code = 5'd18;
                default: code = 5'd12;
            endcase
        end
    end
    // 16x16 宋体点阵（PIL 渲染 simsun.ttc），行优先、bit255 为第 0 行第 0 列
    localparam [255:0] CN_0 = 256'b0001000000010000000010000010000000000100010000000000000000000000000111111111000000010000000100000001000000010000000100000001000000011111111100000001000000010000000000010000000000001000100001000100100010010010010010000001001010000111111100000000000000000000;  // 总
    localparam [255:0] CN_1 = 256'b0000011100000010011110000000001000001000000000101111111110000010001010100001001000101010100100101110101100010010001010101001001001101010100100101010100110010010000111000001001000101010000100100100100100000010100010001000001000001000000010100000100000000100;  // 剩
    localparam [255:0] CN_2 = 256'b0000000000000000011111111111110000000010000000000000010000000000000111111111000000010000000100000001000100010000000100010001000000010001000100000001000100010000000100010001000000010010100100000000001001000000000001000010000000011000000100000110000000001000;  // 页
    localparam [255:0] CN_3 = 256'b0000000000000000111110011111111000001000001000000101000001000000001000011111110000010001000001001111110100100100001001010010010000101001001001000010000100100100001000010010010000100001010001000010000001010000001000001000100010100001000001000100001000000010;  // 预
    localparam [255:0] CN_4 = 256'b0000010000000000000001000000000000001111111100000001100000100000011001000100000000000011100000000001110001110000111000000000111000011111111100000001000100010000000100010001000000011111111100000001000100010000000100010001000000011111111100000001000000010000;  // 备
    localparam [255:0] CN_5 = 256'b0000000010000000001000000100000000010111111111000001010000000100100000000000000001000011111110000100000001000000000100111111100000010010010010000010001111111000111000100100100000100011111110000010000000000000001000010001000000100010000010000000010000000100;  // 演
    localparam [255:0] CN_6 = 256'b0000000100010000001000010001000000010001000100000001000100010000000001111111110000000001000100001111000100010000000100010001000000011111111111100001000100010000000100010001000000010101000100000001100100010000000100100001000000000010000100000000010000010000;  // 讲
    localparam [255:0] CN_7 = 256'b0000100000100000000010000010100001111111001001000000100000100000111111111111111000010000001000000001000000100100111111110010010000100000001001000100100000101000011111110010100000001000000100000000111100010010111110000010101000001000010001100000100010000010;  // 载
    localparam [255:0] CN_8 = 256'b0000010000000000000000100000000000000001000000000000000100000000000000010000000000000010100000000000001010000000000000101000000000000100010000000000010001000000000010000010000000001000001000000001000000010000001000000001000001000000000010001000000000000110;  // 入
    // 汉字点阵 ROM（BRAM，寄存读）：地址 {字号, row1} 在第 1→2 拍读出，与 code2/row2 同拍可用。
    // 字号 = code - 16（总剩页 = 0..2，预备演讲 = 3..6，载入 = 7..8）；非汉字读出的值不使用。
    localparam integer CN_DEPTH = SHOW_STAGE ? 144 : 48;
    reg [15:0] cn_rom [0:CN_DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [15:0] cn_q;
    wire [3:0] cn_idx = code[3:0];   // code 16..24 → 0..8
    wire [7:0] cn_addr = SHOW_STAGE ? {cn_idx, row1} : {2'b00, code[1:0], row1};
    integer cn_i;
    initial begin
        for (cn_i = 0; cn_i < CN_DEPTH; cn_i = cn_i + 1) cn_rom[cn_i] = 16'h0000;
        for (cn_i = 0; cn_i < 16; cn_i = cn_i + 1) begin
            cn_rom[cn_i]      = CN_0[255 - 16 * cn_i -: 16];
            cn_rom[16 + cn_i] = CN_1[255 - 16 * cn_i -: 16];
            cn_rom[32 + cn_i] = CN_2[255 - 16 * cn_i -: 16];
            if (SHOW_STAGE) begin
                cn_rom[48 + cn_i] = CN_3[255 - 16 * cn_i -: 16];
                cn_rom[64 + cn_i] = CN_4[255 - 16 * cn_i -: 16];
                cn_rom[80 + cn_i] = CN_5[255 - 16 * cn_i -: 16];
                cn_rom[96 + cn_i] = CN_6[255 - 16 * cn_i -: 16];
                cn_rom[112 + cn_i] = CN_7[255 - 16 * cn_i -: 16];
                cn_rom[128 + cn_i] = CN_8[255 - 16 * cn_i -: 16];
            end
        end
    end
    always @(posedge clk)
        cn_q <= cn_rom[cn_addr];
    reg        hs2, vs2, de2, box2, text2;
    reg [23:0] rgb2, color2;
    reg [4:0]  code2;
    reg [3:0]  col2, row2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs2 <= 1'b1; vs2 <= 1'b1; de2 <= 1'b0; box2 <= 1'b0; text2 <= 1'b0;
            rgb2 <= 24'd0; color2 <= 24'd0; code2 <= 5'd12; col2 <= 4'd0; row2 <= 4'd0;
        end else begin
            hs2 <= hs1; vs2 <= vs1; de2 <= de1; box2 <= box1; text2 <= text1;
            rgb2 <= rgb1; color2 <= color; code2 <= code; col2 <= col1; row2 <= row1;
        end
    end

    // ---------------- 第 3 拍：字形 ----------------
    function [4:0] font5;      // 5x7，行 0..6；数字与 ':' 同 promax_text_overlay
        input [4:0] c;
        input [2:0] r;
        begin
            font5 = 5'b00000;
            case (c)
                5'd0: case(r) 0:font5=5'b01110;1:font5=5'b10001;2:font5=5'b10011;3:font5=5'b10101;4:font5=5'b11001;5:font5=5'b10001;6:font5=5'b01110;default:font5=0;endcase
                5'd1: case(r) 0:font5=5'b00100;1:font5=5'b01100;2:font5=5'b00100;3:font5=5'b00100;4:font5=5'b00100;5:font5=5'b00100;6:font5=5'b01110;default:font5=0;endcase
                5'd2: case(r) 0:font5=5'b01110;1:font5=5'b10001;2:font5=5'b00001;3:font5=5'b00010;4:font5=5'b00100;5:font5=5'b01000;6:font5=5'b11111;default:font5=0;endcase
                5'd3: case(r) 0:font5=5'b11110;1:font5=5'b00001;2:font5=5'b00001;3:font5=5'b01110;4:font5=5'b00001;5:font5=5'b00001;6:font5=5'b11110;default:font5=0;endcase
                5'd4: case(r) 0:font5=5'b00010;1:font5=5'b00110;2:font5=5'b01010;3:font5=5'b10010;4:font5=5'b11111;5:font5=5'b00010;6:font5=5'b00010;default:font5=0;endcase
                5'd5: case(r) 0:font5=5'b11111;1:font5=5'b10000;2:font5=5'b10000;3:font5=5'b11110;4:font5=5'b00001;5:font5=5'b00001;6:font5=5'b11110;default:font5=0;endcase
                5'd6: case(r) 0:font5=5'b01110;1:font5=5'b10000;2:font5=5'b10000;3:font5=5'b11110;4:font5=5'b10001;5:font5=5'b10001;6:font5=5'b01110;default:font5=0;endcase
                5'd7: case(r) 0:font5=5'b11111;1:font5=5'b00001;2:font5=5'b00010;3:font5=5'b00100;4:font5=5'b01000;5:font5=5'b01000;6:font5=5'b01000;default:font5=0;endcase
                5'd8: case(r) 0:font5=5'b01110;1:font5=5'b10001;2:font5=5'b10001;3:font5=5'b01110;4:font5=5'b10001;5:font5=5'b10001;6:font5=5'b01110;default:font5=0;endcase
                5'd9: case(r) 0:font5=5'b01110;1:font5=5'b10001;2:font5=5'b10001;3:font5=5'b01111;4:font5=5'b00001;5:font5=5'b00001;6:font5=5'b01110;default:font5=0;endcase
                5'd10: case(r) 1:font5=5'b00100;2:font5=5'b00100;4:font5=5'b00100;5:font5=5'b00100;default:font5=0;endcase
                5'd11: case(r) 1:font5=5'b00100;2:font5=5'b00100;3:font5=5'b11111;4:font5=5'b00100;5:font5=5'b00100;default:font5=0;endcase
                5'd13: case(r) 0:font5=5'b00001;1:font5=5'b00010;2:font5=5'b00010;3:font5=5'b00100;4:font5=5'b01000;5:font5=5'b01000;6:font5=5'b10000;default:font5=0;endcase
                default: font5 = 5'b00000;
            endcase
        end
    endfunction
    reg [4:0]   ascii_row;
    reg         ink;
    wire [3:0]  acol = col2 - 4'd3;   // 数字放大 2 倍占列 3..12、行 1..14
    wire [3:0]  arow = row2 - 4'd1;
    always @* begin
        ascii_row = font5(code2, arow[3:1]);
        if (code2[4])
            ink = cn_q[4'd15 - col2];
        else
            ink = (col2 >= 4'd3) && (col2 <= 4'd12) && (row2 >= 4'd1) && (row2 <= 4'd14) && ascii_row[4 - acol[3:1]];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs_out <= 1'b1; vs_out <= 1'b1; de_out <= 1'b0; rgb_out <= 24'd0;
        end else begin
            hs_out <= hs2; vs_out <= vs2; de_out <= de2;
            rgb_out <= !de2 ? 24'd0 : (text2 && ink) ? color2 : box2 ? BOX_RGB : rgb2;
        end
    end
endmodule
