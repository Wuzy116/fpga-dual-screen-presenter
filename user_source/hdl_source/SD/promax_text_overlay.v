`timescale 1ns/1ps

// 第 9 课参数行 + 滚动字幕。相对讲义版：参数行改为本工程真实参数 "VOLxxx P:xx M:A/M  Bxxx  Cxxx"
// （周期为真实秒数；不带 S 单位，因讲义字库 S 与 5 仅差一点）；字幕底带按讲义 2.4 节 Alpha 公式与图片半透明混合，文字不透明。
// D20：字幕改为 subtitle_rom（脚本由 SD/subtitle.txt 生成的 16 行点阵，比例字宽），整条从右向左循环滚动。
// 第 14 课：B/C 为亮度/对比度（128=原图）。D18：参数行 ">VOLxxx >P:xx M:A >Bxxx >Cxxx"，
// adjust_sel = {参数模式, 对象}（对象 0 周期 1 音量 2 亮度 3 对比度），参数模式下在当前对象前显示 ">"。
module promax_text_overlay #(
    parameter integer PARAM_X = 8,
    parameter integer PARAM_Y = 40,
    parameter integer SUBTITLE_Y = 72,
    parameter integer H_ACTIVE = 640,
    parameter [23:0]  BAND_COLOR = 24'he8eef2,
    parameter [7:0]   BAND_ALPHA = 8'd96
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        subtitle_enable,
    input  wire        param_enable,       // 参数行开关；同 enable 只在帧消隐内变化
    input  wire [7:0]  volume,
    input  wire [6:0]  period_s,
    input  wire        auto_enabled,
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire [2:0]  adjust_sel,
    output wire [23:0] rgb_out,
    output wire        overlay_active
);
    localparam integer CELL_W = 12;
    localparam integer CELL_H = 16;
    localparam integer PARAM_CHARS = 29;
    localparam integer SUBTITLE_BAND_Y = SUBTITLE_Y;
    localparam integer SUBTITLE_BAND_BOTTOM = SUBTITLE_Y + 20;      // 底带 20 行，文字在其中第 2..17 行
    localparam integer SUBTITLE_TEXT_Y = SUBTITLE_Y + 2;
    // 字幕点阵（常量）：整条宽 subtitle_width 列；滚动一圈 = 屏宽 + 字幕宽，文字从右边进、完全移出左边后再进
    wire [10:0] subtitle_width;
    wire [15:0] subtitle_col;
    reg  [10:0] sub_rom_x;
    subtitle_rom u_subtitle_rom (.x(sub_rom_x), .width(subtitle_width), .col(subtitle_col));
    wire [10:0] scroll_cycle = H_ACTIVE + subtitle_width;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    reg [10:0] scroll_pos;
    reg [1:0] scroll_div;
    reg [7:0] volume_frame;
    reg [6:0] period_frame;
    reg auto_frame;
    reg [7:0] bright_frame;
    reg [7:0] contrast_frame;
    reg [2:0] sel_frame;
    wire frame_start = vs_q && !vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            scroll_pos <= 11'd0;
            scroll_div <= 2'd0;
            volume_frame <= 8'd255;
            period_frame <= 7'd5;
            auto_frame <= 1'b0;
            bright_frame <= 8'd128;
            contrast_frame <= 8'd128;
            sel_frame <= 3'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                volume_frame <= volume;
                period_frame <= period_s;
                auto_frame <= auto_enabled;
                bright_frame <= brightness;
                contrast_frame <= contrast;
                sel_frame <= adjust_sel;
                if (scroll_div == 2'd2) begin
                    scroll_div <= 2'd0;
                    scroll_pos <= (scroll_pos >= scroll_cycle - 11'd1) ?
                                  11'd0 : scroll_pos + 11'd1;
                end else begin
                    scroll_div <= scroll_div + 1'b1;
                end
            end
        end
    end


    // ---------------- 串行二进制转 BCD（移位加 3），frame_start 后启动 ----------------
    // 复位值与 *_frame 的复位值一致（255/5/128/128），首个 frame_start 前显示也不变。
    reg [11:0] vol_bcd, bri_bcd, con_bcd;
    reg [7:0]  per_bcd;
    reg [2:0]  conv_sel;            // 0..3 正在转换，4 空闲
    reg [3:0]  conv_bit;            // 0 装载，1..8 移位
    reg [19:0] dd;
    wire [3:0] dd0 = dd[11:8], dd1 = dd[15:12], dd2 = dd[19:16];
    wire [19:0] dd_adj = {(dd2 >= 4'd5) ? dd2 + 4'd3 : dd2, (dd1 >= 4'd5) ? dd1 + 4'd3 : dd1,
                          (dd0 >= 4'd5) ? dd0 + 4'd3 : dd0, dd[7:0]};
    wire [19:0] dd_next = {dd_adj[18:0], 1'b0};
    reg  [7:0]  conv_val;
    always @* begin
        case (conv_sel)
            3'd0:    conv_val = volume_frame;
            3'd1:    conv_val = {1'b0, period_frame};
            3'd2:    conv_val = bright_frame;
            default: conv_val = contrast_frame;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vol_bcd <= 12'h255; per_bcd <= 8'h05; bri_bcd <= 12'h128; con_bcd <= 12'h128;
            conv_sel <= 3'd4; conv_bit <= 4'd0; dd <= 20'd0;
        end else if (frame_start) begin
            conv_sel <= 3'd0; conv_bit <= 4'd0;
        end else if (conv_sel != 3'd4) begin
            if (conv_bit == 4'd0) begin
                dd <= {12'd0, conv_val};
                conv_bit <= 4'd1;
            end else begin
                dd <= dd_next;
                if (conv_bit == 4'd8) begin
                    case (conv_sel)
                        3'd0:    vol_bcd <= dd_next[19:8];
                        3'd1:    per_bcd <= dd_next[15:8];   // 周期 0..127：与原 %100 取十位、个位一致
                        3'd2:    bri_bcd <= dd_next[19:8];
                        default: con_bcd <= dd_next[19:8];
                    endcase
                    conv_bit <= 4'd0;
                    conv_sel <= conv_sel + 3'd1;
                end else begin
                    conv_bit <= conv_bit + 4'd1;
                end
            end
        end
    end

    // 十进制数字：帧锁存后在场消隐内由下方串行转换器逐个算出（每值 9 拍，共 36 拍），参数行在第 PARAM_Y 行才开始显示。
    function [7:0] dig;
        input [3:0] d;
        dig = "0" + d;
    endfunction

    function [7:0] param_char;
        input integer index;
        begin
            case (index)
                0: param_char = (sel_frame == 3'd5) ? ">" : " ";
                1: param_char = "V";  2: param_char = "O";
                3: param_char = "L";
                4: param_char = dig(vol_bcd[11:8]);
                5: param_char = dig(vol_bcd[7:4]);
                6: param_char = dig(vol_bcd[3:0]);
                8: param_char = (sel_frame == 3'd4) ? ">" : " ";
                9: param_char = "P";  10: param_char = ":";
                11: param_char = dig(per_bcd[7:4]);
                12: param_char = dig(per_bcd[3:0]);
                14: param_char = "M"; 15: param_char = ":";
                16: param_char = auto_frame ? "A" : "M";
                18: param_char = (sel_frame == 3'd6) ? ">" : " ";
                19: param_char = "B";
                20: param_char = dig(bri_bcd[11:8]);
                21: param_char = dig(bri_bcd[7:4]);
                22: param_char = dig(bri_bcd[3:0]);
                24: param_char = (sel_frame == 3'd7) ? ">" : " ";
                25: param_char = "C";
                26: param_char = dig(con_bcd[11:8]);
                27: param_char = dig(con_bcd[7:4]);
                28: param_char = dig(con_bcd[3:0]);
                default: param_char = " ";
            endcase
        end
    endfunction

    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0;endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "I": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "J": case(row) 0:glyph_row=5'b00111;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00010;4:glyph_row=5'b10010;5:glyph_row=5'b10010;6:glyph_row=5'b01100;default:glyph_row=0;endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "Q": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10101;5:glyph_row=5'b10010;6:glyph_row=5'b01101;default:glyph_row=0;endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "V": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b01010;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "W": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10101;4:glyph_row=5'b10101;5:glyph_row=5'b10101;6:glyph_row=5'b01010;default:glyph_row=0;endcase
                "X": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b01010;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "Z": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                ":": case(row) 1:glyph_row=5'b00100;2:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                ".": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                ",": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "!": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "?": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "-": case(row) 3:glyph_row=5'b11111;default:glyph_row=0;endcase
                ">": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b01000;2:glyph_row=5'b00100;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "_": case(row) 6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "/": case(row) 0:glyph_row=5'b00001;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    // 两级提前：A 级在 pixel_x+2 定位（区域、格号、列号），B 级在 pixel_x+1 选字符查字形，命中标志寄存；
    // 本拍只与 de 相与并选色。pixel_x 在消隐期同样连续计数（10 位回绕），line_y 只在 de 下降沿变化，
    // 参数/滚动/enable 只在帧消隐内变化，故两级看到的是同一行、同一帧的输入，输出逐位不变。
    // 低功耗：定位逻辑只在参数行与字幕底带行内看到 pixel_x，其余行输入冻结为 0；底带混合只在底带行输入背景色。
    // 行标志晚 line_y 一拍，落在行消隐内。
    reg text_row_q, band_row_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            text_row_q <= 1'b0;
            band_row_q <= 1'b0;
        end else begin
            band_row_q <= enable && subtitle_enable &&
                          line_y >= SUBTITLE_BAND_Y && line_y < SUBTITLE_BAND_BOTTOM;
            text_row_q <= enable && ((param_enable && line_y >= PARAM_Y && line_y < PARAM_Y + CELL_H) ||
                          (subtitle_enable && line_y >= SUBTITLE_BAND_Y && line_y < SUBTITLE_BAND_BOTTOM));
        end
    end
    wire [9:0] xa = text_row_q ? pixel_x + 10'd2 : 10'd0;
    wire [23:0] band_bg = band_row_q ? rgb_in : 24'd0;

    // ---------------- A 级：pixel_x+2 定位 ----------------
    reg [9:0]  param_local_x;       // xa < PARAM_X 时回绕，但此时 a_param 为假、结果不用
    reg [5:0]  param_cell;
    reg [11:0] subtitle_stream_x;   // xa + scroll_pos < 640 + 2*1024
    reg a_param, a_band, a_sub;
    reg [4:0] a_param_cell;
    reg [2:0] a_param_col;
    reg [10:0] a_sub_x;

    always @* begin
        param_local_x = xa - PARAM_X;
        param_cell = param_local_x / CELL_W;
        subtitle_stream_x = {2'b00, xa} + {1'b0, scroll_pos};
        if (subtitle_stream_x >= {1'b0, scroll_cycle})
            subtitle_stream_x = subtitle_stream_x - {1'b0, scroll_cycle};
        a_param = enable && param_enable && xa >= PARAM_X && xa < PARAM_X + PARAM_CHARS*CELL_W &&
                  line_y >= PARAM_Y && line_y < PARAM_Y + CELL_H;
        a_param_cell = a_param ? param_cell : 0;
        a_param_col = a_param ? (param_local_x % CELL_W) >> 1 : 0;
        a_band = enable && subtitle_enable && xa >= 8 && xa < H_ACTIVE-8 &&
                 line_y >= SUBTITLE_BAND_Y && line_y < SUBTITLE_BAND_BOTTOM;
        a_sub = enable && subtitle_enable && xa >= 8 && xa < H_ACTIVE-8 &&
                line_y >= SUBTITLE_TEXT_Y && line_y < SUBTITLE_TEXT_Y + 16 &&
                subtitle_stream_x < {1'b0, subtitle_width};
        a_sub_x = a_sub ? subtitle_stream_x[10:0] : 11'd0;
    end

    reg pa_q, band_a_q, sa_q;
    reg [4:0] pa_cell_q;
    reg [2:0] pa_col_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pa_q <= 1'b0; band_a_q <= 1'b0; sa_q <= 1'b0;
            pa_cell_q <= 5'd0; pa_col_q <= 3'd0; sub_rom_x <= 11'd0;
        end else begin
            pa_q <= a_param; band_a_q <= a_band; sa_q <= a_sub;
            pa_cell_q <= a_param_cell; pa_col_q <= a_param_col;
            sub_rom_x <= a_sub_x;
        end
    end

    // ---------------- B 级：pixel_x+1 选字符、查字形 ----------------
    reg [7:0] param_sel_char;
    reg [4:0] param_row_bits;
    reg b_param, b_sub;
    wire [3:0] sub_row = line_y - SUBTITLE_TEXT_Y;
    always @* begin
        param_sel_char = " ";
        param_row_bits = 5'b00000;
        b_param = 1'b0;
        b_sub = sa_q && subtitle_col[4'd15 - sub_row];
        if (pa_q && pa_col_q < 5 && ((line_y-PARAM_Y) >> 1) < 7) begin
            param_sel_char = param_char(pa_cell_q);
            param_row_bits = glyph_row(param_sel_char, (line_y-PARAM_Y) >> 1);
            b_param = param_row_bits[4-pa_col_q];
        end
    end

    reg param_q, sub_q, band_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            param_q <= 1'b0; sub_q <= 1'b0; band_q <= 1'b0;
        end else begin
            param_q <= b_param; sub_q <= b_sub; band_q <= band_a_q;
        end
    end

    // ---------------- 本拍：与 de 相与 ----------------
    wire param_pixel = param_q && de;
    wire subtitle_pixel = sub_q && de;
    wire subtitle_band_pixel = band_q && de;

    // 最终颜色 = 前景*a/255 + 背景*(255-a)/255；/255 用 (t+128+((t+128)>>8))>>8 精确四舍五入。
    function [7:0] blend_channel;
        input [7:0] bg;
        input [7:0] fg;
        input [7:0] alpha;
        reg [16:0] t;
        begin
            t = fg * alpha + bg * (8'd255 - alpha) + 17'd128;
            blend_channel = (t + (t >> 8)) >> 8;
        end
    endfunction

    function [23:0] alpha_blend;
        input [23:0] bg;
        input [23:0] fg;
        input [7:0]  alpha;
        begin
            alpha_blend = {blend_channel(bg[23:16], fg[23:16], alpha),
                           blend_channel(bg[15:8],  fg[15:8],  alpha),
                           blend_channel(bg[7:0],   fg[7:0],   alpha)};
        end
    endfunction

    assign overlay_active = param_pixel || subtitle_pixel || subtitle_band_pixel;
    assign rgb_out = subtitle_pixel ? 24'h000000 :
                     param_pixel ? 24'hfff080 :
                     subtitle_band_pixel ? alpha_blend(band_bg, BAND_COLOR, BAND_ALPHA) : rgb_in;
endmodule
