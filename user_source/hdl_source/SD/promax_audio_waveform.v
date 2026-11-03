`timescale 1ns/1ps

// 第 12 课音频波形（美化版）：淡白底板 + 灰色虚线基准 + 多色渐变连续波形（D26 起去掉右侧 dB 峰值条以节省资源）。
// 自动增益：样本先 <<< gain（0..GAIN_MAX，饱和到 16 位）再取高 8 位 s8；每帧按整帧原始 |pcm| 峰值 praw 选目标
// （praw <= GAIN_LIMIT>>g 的最大 g）：变响立即降档，变轻连续 GAIN_HOLD 帧才升 1 档，praw < GAIN_FLOOR 时保持。
// 采集：帧开始后过零触发（先低于 -TRIG_HYST 再回到 >=0；TRIG_TIMEOUT 个样本内未触发则直接开始），
// 每 DECIMATE 个样本取 1 点共 65 点，存储值 = (上屏值 + 新值) >>> 1；帧开始时采满才交换双缓冲。
// 显示：读出点经 127*(|v|/127)^0.6 压缩后相邻两点线性插值（1/8 px），每列竖向覆盖本列到下一列的 y 范围，
// 线宽 2 px + 上下 1 px 半透明软边。色号 cyc = (横向 32 px 段号*2 + 振幅级) mod 32，镜像查 16 级色表，安静时也多色。
// 读点/压缩/插值在 pixel_x+2 寄存，类型与色号在 pixel_x+1 寄存，本拍只做底板混合与选色；对外仍为同拍组合输出、不改变 hs/vs/de 对齐。
// pcm_tap_valid 必须是每个样本一拍的提交脉冲（不是 ready/valid 电平）。
// LITE=1（D32 精简版）：256x32、33 点，线性幅度（不做 ^0.6 压缩），固定绿色 LINE_RGB，底板为背景压暗一半（适合暗场）；
//   省去色表、压缩表与色号计算，其余（自动增益、触发、平滑、插值、线宽与软边）不变。
// LITE=2（D32 资源再精简）：在 LITE=1 基础上固定增益 FIXED_GAIN（不做整帧峰值 / 自动增益）、不等过零触发（帧开始即采）、
//   不做两帧平滑；相邻两点间不插值：每列只画本点到下一点之间的竖直范围（台阶连线），线宽 2 px，无软边、无基准虚线。
module promax_audio_waveform #(
    parameter integer LITE = 0,
    parameter [23:0]  LINE_RGB = 24'h34d399,
    parameter integer WAVE_X = 64,
    parameter integer WAVE_Y = 400,
    parameter integer WAVE_WIDTH = 512,
    parameter integer WAVE_HEIGHT = 64,
    parameter integer DECIMATE = 6,
    parameter integer TRIG_HYST = 2,
    parameter integer TRIG_TIMEOUT = 256,
    parameter integer GAIN_MAX = 5,
    parameter integer GAIN_LIMIT = 24575,
    parameter integer GAIN_FLOOR = 32,
    parameter integer GAIN_HOLD = 32,
    parameter integer FIXED_GAIN = 2
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out,
    output wire        waveform_active
);
    localparam integer NPTS = LITE ? 33 : 65;
    localparam integer MIN = (LITE == 2);
    localparam integer CENTER_Y = WAVE_Y + WAVE_HEIGHT/2;
    localparam integer WAVE_BOTTOM = WAVE_Y + WAVE_HEIGHT;
    localparam integer PANEL_X0 = WAVE_X - 4;
    localparam integer PANEL_X1 = WAVE_X + WAVE_WIDTH + 4;
    localparam integer PANEL_Y0 = WAVE_Y - 4;
    localparam integer PANEL_Y1 = WAVE_BOTTOM + 4;
    localparam [1:0] CAP_WAIT = 2'd0, CAP_RUN = 2'd1, CAP_DONE = 2'd2;
    // synthesis translate_off
    initial begin
        if ((MIN && (FIXED_GAIN < 0 || FIXED_GAIN > 7)) || (LITE ? (WAVE_WIDTH != 256 || WAVE_HEIGHT != 32) : (WAVE_WIDTH != 512 || WAVE_HEIGHT != 64)) || DECIMATE < 2 || DECIMATE > 256 ||
            TRIG_HYST < 0 || TRIG_HYST > 127 || TRIG_TIMEOUT < 2 || TRIG_TIMEOUT > 512 ||
            GAIN_MAX < 0 || GAIN_MAX > 7 || GAIN_LIMIT < 1 || GAIN_LIMIT > 32767 ||
            GAIN_FLOOR < 0 || GAIN_FLOOR > 32767 || GAIN_HOLD < 1 || GAIN_HOLD > 255 ||
            WAVE_X < 4 || PANEL_X1 > 1024) begin
            $display("MEDIA_CONFIG_ERROR audio waveform %m: 512x64 (LITE 256x32) area, points of 8 px, gain 0..7, DECIMATE/TRIG_TIMEOUT >= 2 required");
            $finish;
        end
    end
    // synthesis translate_on

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // ---------------- 自动增益与整帧峰值 ----------------
    reg [2:0] gain;
    reg [7:0] gain_hold;
    reg [14:0] praw;
    wire [15:0] pcm_abs_raw = pcm_tap_left[15] ? (~pcm_tap_left + 16'd1) : pcm_tap_left;
    wire [14:0] pcm_abs = pcm_abs_raw[15] ? 15'd32767 : pcm_abs_raw[14:0];
    wire [2:0] gain_use = MIN ? FIXED_GAIN : gain;
    wire signed [23:0] pcm_shift = $signed(pcm_tap_left) <<< gain_use;
    wire pcm_over = pcm_shift > 24'sd32767;
    wire pcm_under = pcm_shift < -24'sd32768;
    wire [15:0] pcm_g = pcm_over ? 16'h7fff : pcm_under ? 16'h8000 : pcm_shift[15:0];

    // praw <= GAIN_LIMIT >> g 的最大 g（g <= GAIN_MAX）
    reg [2:0] gain_req;
    integer gi;
    always @* begin
        gain_req = 3'd0;
        for (gi = 1; gi <= GAIN_MAX; gi = gi + 1)
            if ({17'd0, praw} <= (GAIN_LIMIT >> gi)) gain_req = gi;
    end

    // 偶数点 0,2..64 与奇数点 1,3..63 分存：相邻两点各在一块，每块只需一个显示读口。
    reg [7:0] even_mem [0:127];
    reg [7:0] odd_mem  [0:63];
    reg write_bank, display_bank, display_valid;
    reg [1:0] cap_state;
    reg armed;
    reg [8:0] trig_count;
    reg [6:0] cap_count;
    reg [7:0] dec_count;

    wire [7:0] s8 = pcm_g[15:8];
    wire below_hyst = $signed(s8) < -TRIG_HYST;
    wire trig_start = MIN || (trig_count == TRIG_TIMEOUT - 1) || (armed && !s8[7]);
    wire point_now = (cap_state == CAP_WAIT && trig_start) || (cap_state == CAP_RUN && dec_count == 8'd0);
    wire point_store = !frame_start && pcm_tap_valid && point_now;

    // 两块各为一块 RAM（同步读）。A 口 = 采集：存点当拍写 write_bank，其余时间读 display_bank 的同一点（平滑用旧值）；
    // B 口 = 显示读点（见下方 A 级）。A 口读出晚一拍：采集序号只在存点时变化，相邻存点至少隔 DECIMATE(>=2) 个样本，
    // 帧开始后首个存点至少在第 2 个样本（TRIG_TIMEOUT>=2，armed 帧开始清零），所以存点当拍读到的总是本序号的旧值。
    wire we_even = point_store && !cap_count[0];
    wire we_odd = point_store && cap_count[0];
    wire [6:0] a_even = {we_even ? write_bank : display_bank, cap_count[6:1]};
    wire [5:0] a_odd = {we_odd ? write_bank : display_bank, cap_count[5:1]};
    reg  [7:0] old_even, old_odd;
    wire [7:0] old_pt = cap_count[0] ? old_odd : old_even;
    wire [8:0] avg_sum = {old_pt[7], old_pt} + {s8[7], s8};
    wire [7:0] wr_data = (display_valid && !MIN) ? avg_sum[8:1] : s8;

    always @(posedge clk) begin
        if (we_even) even_mem[a_even] <= wr_data;
        old_even <= even_mem[a_even];
    end
    always @(posedge clk) begin
        if (we_odd) odd_mem[a_odd] <= wr_data;
        old_odd <= odd_mem[a_odd];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            write_bank <= 1'b0;
            display_bank <= 1'b1;
            display_valid <= 1'b0;
            cap_state <= CAP_WAIT;
            armed <= 1'b0;
            trig_count <= 9'd0;
            cap_count <= 7'd0;
            dec_count <= 8'd0;
            gain <= 3'd0;
            gain_hold <= 8'd0;
            praw <= 15'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                if (cap_state == CAP_DONE) begin
                    display_bank <= write_bank;
                    write_bank <= ~write_bank;
                    display_valid <= 1'b1;
                end
                if (praw >= GAIN_FLOOR) begin
                    if (gain_req < gain) begin
                        gain <= gain_req;
                        gain_hold <= 8'd0;
                    end else if (gain_req > gain) begin
                        if (gain_hold == GAIN_HOLD - 1) begin
                            gain <= gain + 1'b1;
                            gain_hold <= 8'd0;
                        end else begin
                            gain_hold <= gain_hold + 1'b1;
                        end
                    end else begin
                        gain_hold <= 8'd0;
                    end
                end
                praw <= 15'd0;
                cap_state <= CAP_WAIT;
                armed <= 1'b0;
                trig_count <= 9'd0;
                cap_count <= 7'd0;
                dec_count <= 8'd0;
            end else if (pcm_tap_valid) begin
                if (pcm_abs > praw) praw <= pcm_abs;
                case (cap_state)
                    CAP_WAIT: begin
                        if (trig_start) begin
                            cap_state <= CAP_RUN;
                            cap_count <= 7'd1;
                            dec_count <= DECIMATE - 1;
                        end else begin
                            trig_count <= trig_count + 1'b1;
                            if (below_hyst) armed <= 1'b1;
                        end
                    end
                    CAP_RUN: begin
                        if (dec_count == 8'd0) begin
                            cap_count <= cap_count + 1'b1;
                            dec_count <= DECIMATE - 1;
                            if (cap_count == NPTS - 1) cap_state <= CAP_DONE;
                        end else begin
                            dec_count <= dec_count - 1'b1;
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end

    // 127*(i/127)^0.6 四舍五入
    function [6:0] comp_lut;
        input [6:0] i;
        begin
            case (i)
            7'd0: comp_lut = 7'd0;
            7'd1: comp_lut = 7'd7;
            7'd2: comp_lut = 7'd11;
            7'd3: comp_lut = 7'd13;
            7'd4: comp_lut = 7'd16;
            7'd5: comp_lut = 7'd18;
            7'd6: comp_lut = 7'd20;
            7'd7: comp_lut = 7'd22;
            7'd8: comp_lut = 7'd24;
            7'd9: comp_lut = 7'd26;
            7'd10: comp_lut = 7'd28;
            7'd11: comp_lut = 7'd29;
            7'd12: comp_lut = 7'd31;
            7'd13: comp_lut = 7'd32;
            7'd14: comp_lut = 7'd34;
            7'd15: comp_lut = 7'd35;
            7'd16: comp_lut = 7'd37;
            7'd17: comp_lut = 7'd38;
            7'd18: comp_lut = 7'd39;
            7'd19: comp_lut = 7'd41;
            7'd20: comp_lut = 7'd42;
            7'd21: comp_lut = 7'd43;
            7'd22: comp_lut = 7'd44;
            7'd23: comp_lut = 7'd46;
            7'd24: comp_lut = 7'd47;
            7'd25: comp_lut = 7'd48;
            7'd26: comp_lut = 7'd49;
            7'd27: comp_lut = 7'd50;
            7'd28: comp_lut = 7'd51;
            7'd29: comp_lut = 7'd52;
            7'd30: comp_lut = 7'd53;
            7'd31: comp_lut = 7'd54;
            7'd32: comp_lut = 7'd56;
            7'd33: comp_lut = 7'd57;
            7'd34: comp_lut = 7'd58;
            7'd35: comp_lut = 7'd59;
            7'd36: comp_lut = 7'd60;
            7'd37: comp_lut = 7'd61;
            7'd38: comp_lut = 7'd62;
            7'd39: comp_lut = 7'd63;
            7'd40: comp_lut = 7'd63;
            7'd41: comp_lut = 7'd64;
            7'd42: comp_lut = 7'd65;
            7'd43: comp_lut = 7'd66;
            7'd44: comp_lut = 7'd67;
            7'd45: comp_lut = 7'd68;
            7'd46: comp_lut = 7'd69;
            7'd47: comp_lut = 7'd70;
            7'd48: comp_lut = 7'd71;
            7'd49: comp_lut = 7'd72;
            7'd50: comp_lut = 7'd73;
            7'd51: comp_lut = 7'd73;
            7'd52: comp_lut = 7'd74;
            7'd53: comp_lut = 7'd75;
            7'd54: comp_lut = 7'd76;
            7'd55: comp_lut = 7'd77;
            7'd56: comp_lut = 7'd78;
            7'd57: comp_lut = 7'd79;
            7'd58: comp_lut = 7'd79;
            7'd59: comp_lut = 7'd80;
            7'd60: comp_lut = 7'd81;
            7'd61: comp_lut = 7'd82;
            7'd62: comp_lut = 7'd83;
            7'd63: comp_lut = 7'd83;
            7'd64: comp_lut = 7'd84;
            7'd65: comp_lut = 7'd85;
            7'd66: comp_lut = 7'd86;
            7'd67: comp_lut = 7'd87;
            7'd68: comp_lut = 7'd87;
            7'd69: comp_lut = 7'd88;
            7'd70: comp_lut = 7'd89;
            7'd71: comp_lut = 7'd90;
            7'd72: comp_lut = 7'd90;
            7'd73: comp_lut = 7'd91;
            7'd74: comp_lut = 7'd92;
            7'd75: comp_lut = 7'd93;
            7'd76: comp_lut = 7'd93;
            7'd77: comp_lut = 7'd94;
            7'd78: comp_lut = 7'd95;
            7'd79: comp_lut = 7'd96;
            7'd80: comp_lut = 7'd96;
            7'd81: comp_lut = 7'd97;
            7'd82: comp_lut = 7'd98;
            7'd83: comp_lut = 7'd98;
            7'd84: comp_lut = 7'd99;
            7'd85: comp_lut = 7'd100;
            7'd86: comp_lut = 7'd101;
            7'd87: comp_lut = 7'd101;
            7'd88: comp_lut = 7'd102;
            7'd89: comp_lut = 7'd103;
            7'd90: comp_lut = 7'd103;
            7'd91: comp_lut = 7'd104;
            7'd92: comp_lut = 7'd105;
            7'd93: comp_lut = 7'd105;
            7'd94: comp_lut = 7'd106;
            7'd95: comp_lut = 7'd107;
            7'd96: comp_lut = 7'd107;
            7'd97: comp_lut = 7'd108;
            7'd98: comp_lut = 7'd109;
            7'd99: comp_lut = 7'd109;
            7'd100: comp_lut = 7'd110;
            7'd101: comp_lut = 7'd111;
            7'd102: comp_lut = 7'd111;
            7'd103: comp_lut = 7'd112;
            7'd104: comp_lut = 7'd113;
            7'd105: comp_lut = 7'd113;
            7'd106: comp_lut = 7'd114;
            7'd107: comp_lut = 7'd115;
            7'd108: comp_lut = 7'd115;
            7'd109: comp_lut = 7'd116;
            7'd110: comp_lut = 7'd117;
            7'd111: comp_lut = 7'd117;
            7'd112: comp_lut = 7'd118;
            7'd113: comp_lut = 7'd118;
            7'd114: comp_lut = 7'd119;
            7'd115: comp_lut = 7'd120;
            7'd116: comp_lut = 7'd120;
            7'd117: comp_lut = 7'd121;
            7'd118: comp_lut = 7'd122;
            7'd119: comp_lut = 7'd122;
            7'd120: comp_lut = 7'd123;
            7'd121: comp_lut = 7'd123;
            7'd122: comp_lut = 7'd124;
            7'd123: comp_lut = 7'd125;
            7'd124: comp_lut = 7'd125;
            7'd125: comp_lut = 7'd126;
            7'd126: comp_lut = 7'd126;
            default: comp_lut = 7'd127;
            endcase
        end
    endfunction
    function [7:0] compress;
        input [7:0] v;
        reg [7:0] m;
        reg [6:0] c;
        begin
            m = v[7] ? (~v + 8'd1) : v;
            c = LITE ? (m[7] ? 7'd127 : m[6:0]) : comp_lut(m[7] ? 7'd127 : m[6:0]);
            compress = v[7] ? (~{1'b0, c} + 8'd1) : {1'b0, c};
        end
    endfunction

    // ---------------- 两级提前：A 级为 pixel_x+2 读点/压缩/插值，B 级为 pixel_x+1 判定类型与色号 ----------------
    // pixel_x 在消隐期间同样连续计数，line_y 只在 de 下降沿变化（远离底板区），两级看到的是同一行。
    // 低功耗：A 级只在波形行内且 enable=1 时工作，否则输入冻结为 0、tc/tn 与 k_idx 保持（行外 draw_wave=0、
    // enable=0 时 act=0，都不使用它们）；顶层 enable 只在帧边界变化，整帧一致。
    // 底板混合只在 act 时输入背景色，其余像素原样透传。行标志晚 line_y 一拍，落在行消隐内。
    reg wave_row_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wave_row_q <= 1'b0;
        else        wave_row_q <= enable && line_y >= WAVE_Y && line_y < WAVE_BOTTOM;
    end
    wire [9:0] px_a = wave_row_q ? pixel_x : 10'd0;
    wire [10:0] xa = {1'b0, px_a} + 11'd2;
    wire [10:0] ua = xa - WAVE_X;
    wire [5:0] seg_a = ua[8:3];
    wire [2:0] frac_a = ua[2:0];
    // B 口读点提前一拍（pixel_x+3 发地址，下一拍即 pixel_x+2 处取数）。pixel_x 只在行尾回绕时不连续，那几拍在波形区外。
    wire [10:0] ur = {1'b0, px_a} + 11'd3 - WAVE_X;
    wire [5:0] seg_r = ur[8:3];
    wire [6:0] seg1_r = {1'b0, seg_r} + 7'd1;
    reg  [7:0] rd_even, rd_odd;
    always @(posedge clk) rd_even <= even_mem[{display_bank, seg1_r[6:1]}];
    always @(posedge clk) rd_odd <= odd_mem[{display_bank, seg_r[5:1]}];
    wire signed [7:0] pa = compress(seg_a[0] ? rd_odd : rd_even);
    wire signed [7:0] pb = compress(seg_a[0] ? rd_even : rd_odd);
    // 相对中心的 y（1/8 px，向下为正）：ra = -2*pa，rb = -2*pb（LITE 高度减半：-pa、-pb）
    wire signed [10:0] ra = LITE ? -($signed({{3{pa[7]}}, pa})) : -($signed({{2{pa[7]}}, pa, 1'b0}));
    wire signed [10:0] rb = LITE ? -($signed({{3{pb[7]}}, pb})) : -($signed({{2{pb[7]}}, pb, 1'b0}));
    wire signed [10:0] dlt = rb - ra;
    wire signed [14:0] prod_c = dlt * $signed({1'b0, frac_a});
    wire signed [14:0] prod_n = dlt * $signed({1'b0, {1'b0, frac_a} + 4'd1});
    wire signed [11:0] tc_a = MIN ? {ra[10], ra} : ra + (prod_c >>> 3);
    wire signed [11:0] tn_a = MIN ? {rb[10], rb} : ra + (prod_n >>> 3);
    reg  signed [11:0] tc, tn;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tc <= 12'sd0;
            tn <= 12'sd0;
        end else if (wave_row_q) begin
            tc <= tc_a;
            tn <= tn_a;
        end
    end

    wire [10:0] xn = {1'b0, pixel_x} + 11'd1;
    wire in_panel_n = xn >= PANEL_X0 && xn < PANEL_X1 && line_y >= PANEL_Y0 && line_y < PANEL_Y1;
    wire in_wave_x = xn >= WAVE_X && xn < WAVE_X + WAVE_WIDTH;
    wire in_wave_y = line_y >= WAVE_Y && line_y < WAVE_BOTTOM;
    wire [10:0] u = xn - WAVE_X;
    wire signed [8:0] yc = tc >>> 3;
    wire signed [8:0] yn = tn >>> 3;
    wire signed [8:0] lo = (yc < yn) ? yc : yn;
    wire signed [8:0] hi = (yc < yn) ? yn : yc;
    wire signed [12:0] y_rel = $signed({1'b0, line_y}) - CENTER_Y;
    wire signed [12:0] lo_e = lo;
    wire signed [12:0] hi_e = hi;
    wire solid_n = (y_rel >= lo_e) && (y_rel <= hi_e + 13'sd1);
    wire soft_n = !MIN && ((y_rel == lo_e - 13'sd1) || (y_rel == hi_e + 13'sd2));
    wire [11:0] amp_c = tc[11] ? -tc : tc;
    wire [11:0] amp_n = tn[11] ? -tn : tn;
    wire [11:0] amp8 = (amp_c > amp_n) ? amp_c : amp_n;
    wire [13:0] amp3 = {2'b00, amp8} + {1'b0, amp8, 1'b0};
    wire [3:0] amp_idx = (amp3[13:4] > 10'd15) ? 4'd15 : amp3[7:4];
    wire [4:0] cyc = {u[8:5], 1'b0} + {1'b0, amp_idx};
    wire [3:0] wave_idx = cyc[4] ? ~cyc[3:0] : cyc[3:0];
    wire draw_wave = in_wave_x && in_wave_y && display_valid;

    reg k_panel, k_dash, k_solid, k_soft;
    reg [3:0] k_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_panel <= 1'b0;
            k_dash <= 1'b0;
            k_solid <= 1'b0;
            k_soft <= 1'b0;
            k_idx <= 4'd0;
        end else begin
            k_panel <= enable && in_panel_n;
            k_dash <= !MIN && in_wave_x && line_y == CENTER_Y && !u[2];
            k_solid <= draw_wave && solid_n;
            k_soft <= draw_wave && !solid_n && soft_n;
            if (wave_row_q && !LITE) k_idx <= wave_idx;
        end
    end

    // ---------------- 本拍：底板/虚线混合与选色 ----------------
    function [23:0] mix_half;
        input [23:0] a, b;
        begin
            mix_half = {{1'b0, a[23:17]} + {1'b0, b[23:17]},
                        {1'b0, a[15:9]}  + {1'b0, b[15:9]},
                        {1'b0, a[7:1]}   + {1'b0, b[7:1]}};
        end
    endfunction
    // 淡白底板 = 背景/4 + #F5F8FC*3/4
    function [23:0] frost;
        input [23:0] c;
        begin
            frost = {{2'b00, c[23:18]} + 8'd184, {2'b00, c[15:10]} + 8'd186, {2'b00, c[7:2]} + 8'd189};
        end
    endfunction
    // 淡底 16 级：#0891B2 -> #2563EB -> #7C3AED -> #DB2777 -> #EA580C
    function [23:0] light_pal;
        input [3:0] i;
        begin
            case (i)
            4'd0: light_pal = 24'h0891b2;
            4'd1: light_pal = 24'h1085c1;
            4'd2: light_pal = 24'h1778d0;
            4'd3: light_pal = 24'h1f6ce0;
            4'd4: light_pal = 24'h2b60eb;
            4'd5: light_pal = 24'h4255ec;
            4'd6: light_pal = 24'h594aec;
            4'd7: light_pal = 24'h703fed;
            4'd8: light_pal = 24'h8937dd;
            4'd9: light_pal = 24'ha232be;
            4'd10: light_pal = 24'hbb2d9e;
            4'd11: light_pal = 24'hd5287f;
            4'd12: light_pal = 24'hde3162;
            4'd13: light_pal = 24'he23e45;
            4'd14: light_pal = 24'he64b29;
            default: light_pal = 24'hea580c;
            endcase
        end
    endfunction

    wire act = enable && de && k_panel;
    wire [23:0] act_rgb = act ? rgb_in : 24'd0;
    wire [23:0] panel_rgb = LITE ? {1'b0, act_rgb[23:17], 1'b0, act_rgb[15:9], 1'b0, act_rgb[7:1]} : frost(act_rgb);
    wire [23:0] base_rgb = k_dash ? mix_half(panel_rgb, LITE ? 24'h3f6f5a : 24'h94a3b8) : panel_rgb;
    wire [23:0] line_rgb = LITE ? LINE_RGB : light_pal(k_idx);
    wire [23:0] over_rgb = k_solid ? line_rgb :
                           k_soft ? mix_half(line_rgb, base_rgb) : base_rgb;
    assign waveform_active = act;
    assign rgb_out = act ? over_rgb : rgb_in;
endmodule
