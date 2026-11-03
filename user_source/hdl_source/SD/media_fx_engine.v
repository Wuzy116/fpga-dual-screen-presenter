`timescale 1ns/1ps

// D32 观众屏重映射特效引擎（像素域，位于 reader 与亮度 / 对比度调整之间；输出与输入同拍，不改时序）。
// mode 0（直通）：rgb_in 原样输出，只叠遮罩：第 1 张右下素材区填 BG（常态 / 淡变 / 滑动段 / 总览页格 0），
//   进入第 2 张的转场中第 2 张手机窗口填 BG（hide_win），circ_iris 时圆外为黑。三种 BG 遮罩只在 demo=1（5 张演示卡）时生效。
// mode 1..4（行缓存）：reader 按“有效行 = 读出行 + 1”取源，本模块把每行写入两行乒乓缓存、下一行按列重映射读出，
//   屏幕第 y 行显示有效行 y 的结果（第 0 行无数据，显示黑）：
//   1 ZOOM：列 sx = (ax0 + x*a_step) >> 8，缓存下标 sx；越界为黑（clamp_oor=1 时钳位，用于抖动）。
//   ZOOM 时 band_en=1：A 段源行落在背面素材带内、源列不在手机列 [FX0, FX0+PW) 的像素为 BG（推进背面主摄用）。
//   3 SPIN：背面素材带行内，手机列按 spin_tab 横向缩放（压暗 1/8..3/8、侧面高光 +80），其余为 BG；带外行原样。
//   4 ASM：窗口行内由远到近推近（行列同为 a_step，源为背面素材带，手机列外为 BG），整体按 light/8 从 BG 渐亮，
//          glint_on 时斜向高光带 +70。窗口外行原样。（D32 资源：底板 / 镜头飞入已去掉）
// BG 判定：与 BG 每通道相差 <= 2。几何参数按演示素材（.workflow/.scratchpad/card_d32/make_pics_v4.py）写死。
module media_fx_engine #(
    parameter [23:0]  BG = 24'h141216,
    parameter integer FX0 = 251,
    parameter integer PW  = 138,
    parameter integer CX  = 320,
    parameter integer BAND_LO = 22,
    parameter integer BAND_HI = 318,
    parameter integer WX0 = 160,
    parameter integer WX1 = 479,
    parameter integer GL_X0 = 251,
    parameter integer GL_Y0 = 26,
    parameter integer SX0 = 491,
    parameter integer SX1 = 628,
    parameter integer SY0 = 160,
    parameter integer SY1 = 456,
    parameter integer TX0 = 202,
    parameter integer TX1 = 237,
    parameter integer TY0 = 160,
    parameter integer TY1 = 234,
    parameter integer CIRC_CX = 192,     // 圆形展开圆心：第 3 / 4 张主摄
    parameter integer CIRC_CY = 218
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        latch,
    input  wire [2:0]  mode,
    input  wire        clamp_oor,
    input  wire [8:0]  win_lo,
    input  wire [8:0]  win_hi,
    input  wire        band_en,
    input  wire signed [19:0] a_acc0,
    input  wire signed [19:0] ax0,
    input  wire [9:0]  a_step,
    input  wire        circ_on,
    input  wire        circ_iris,
    input  wire [19:0] circ_r2,
    input  wire [6:0]  spin_k,
    output wire        spin_back,        // 本帧转一圈显示背面（给 reader 选背面素材带）
    input  wire [3:0]  light,
    input  wire        glint_on,
    input  wire signed [10:0] glint,
    input  wire [2:0]  f_index,
    input  wire [2:0]  f_alt,
    input  wire        f_sheet,
    input  wire        f_slide,
    input  wire        f_slide_left,
    input  wire [9:0]  f_slide_cols,
    input  wire [18:0] f_split,
    input  wire        hide_win,
    input  wire        demo,
    output wire [23:0] rgb_out
);
    localparam [2:0] M_OFF = 3'd0, M_ZOOM = 3'd1, M_SPIN = 3'd3, M_ASM = 3'd4;

    function [24:0] spin_tab;   // {back, lead, shade[1:0], hs[6:0], inv[13:0]}
        input [6:0] k;
        begin
            case (k)
            7'd0: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd1: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd2: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd3: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd4: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd5: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd6: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd7: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd8: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd9: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd10: spin_tab = {1'b1, 1'b0, 2'd0, 7'd68, 14'd260};
            7'd11: spin_tab = {1'b1, 1'b0, 2'd0, 7'd68, 14'd260};
            7'd12: spin_tab = {1'b1, 1'b0, 2'd0, 7'd68, 14'd260};
            7'd13: spin_tab = {1'b1, 1'b0, 2'd0, 7'd68, 14'd260};
            7'd14: spin_tab = {1'b1, 1'b0, 2'd0, 7'd67, 14'd264};
            7'd15: spin_tab = {1'b1, 1'b0, 2'd0, 7'd66, 14'd268};
            7'd16: spin_tab = {1'b1, 1'b0, 2'd0, 7'd66, 14'd268};
            7'd17: spin_tab = {1'b1, 1'b0, 2'd0, 7'd65, 14'd272};
            7'd18: spin_tab = {1'b1, 1'b0, 2'd0, 7'd64, 14'd276};
            7'd19: spin_tab = {1'b1, 1'b0, 2'd0, 7'd63, 14'd280};
            7'd20: spin_tab = {1'b1, 1'b0, 2'd0, 7'd62, 14'd285};
            7'd21: spin_tab = {1'b1, 1'b0, 2'd0, 7'd60, 14'd294};
            7'd22: spin_tab = {1'b1, 1'b0, 2'd0, 7'd59, 14'd299};
            7'd23: spin_tab = {1'b1, 1'b0, 2'd0, 7'd57, 14'd310};
            7'd24: spin_tab = {1'b1, 1'b0, 2'd1, 7'd55, 14'd321};
            7'd25: spin_tab = {1'b1, 1'b0, 2'd1, 7'd53, 14'd333};
            7'd26: spin_tab = {1'b1, 1'b0, 2'd1, 7'd50, 14'd353};
            7'd27: spin_tab = {1'b1, 1'b0, 2'd1, 7'd48, 14'd368};
            7'd28: spin_tab = {1'b1, 1'b0, 2'd1, 7'd45, 14'd393};
            7'd29: spin_tab = {1'b1, 1'b0, 2'd1, 7'd42, 14'd421};
            7'd30: spin_tab = {1'b1, 1'b0, 2'd1, 7'd38, 14'd465};
            7'd31: spin_tab = {1'b1, 1'b0, 2'd2, 7'd35, 14'd505};
            7'd32: spin_tab = {1'b1, 1'b0, 2'd2, 7'd31, 14'd570};
            7'd33: spin_tab = {1'b1, 1'b0, 2'd2, 7'd27, 14'd654};
            7'd34: spin_tab = {1'b1, 1'b0, 2'd2, 7'd23, 14'd768};
            7'd35: spin_tab = {1'b1, 1'b0, 2'd3, 7'd19, 14'd930};
            7'd36: spin_tab = {1'b1, 1'b0, 2'd3, 7'd14, 14'd1262};
            7'd37: spin_tab = {1'b1, 1'b0, 2'd3, 7'd10, 14'd1766};
            7'd38: spin_tab = {1'b1, 1'b0, 2'd3, 7'd5, 14'd3533};
            7'd39: spin_tab = {1'b1, 1'b0, 2'd3, 7'd2, 14'd8832};
            7'd40: spin_tab = {1'b0, 1'b0, 2'd3, 7'd5, 14'd3533};
            7'd41: spin_tab = {1'b0, 1'b0, 2'd3, 7'd10, 14'd1766};
            7'd42: spin_tab = {1'b0, 1'b0, 2'd3, 7'd15, 14'd1178};
            7'd43: spin_tab = {1'b0, 1'b0, 2'd3, 7'd20, 14'd883};
            7'd44: spin_tab = {1'b0, 1'b0, 2'd2, 7'd25, 14'd707};
            7'd45: spin_tab = {1'b0, 1'b0, 2'd2, 7'd30, 14'd589};
            7'd46: spin_tab = {1'b0, 1'b0, 2'd2, 7'd34, 14'd520};
            7'd47: spin_tab = {1'b0, 1'b0, 2'd1, 7'd39, 14'd453};
            7'd48: spin_tab = {1'b0, 1'b0, 2'd1, 7'd43, 14'd411};
            7'd49: spin_tab = {1'b0, 1'b0, 2'd1, 7'd47, 14'd376};
            7'd50: spin_tab = {1'b0, 1'b0, 2'd1, 7'd51, 14'd346};
            7'd51: spin_tab = {1'b0, 1'b0, 2'd1, 7'd55, 14'd321};
            7'd52: spin_tab = {1'b0, 1'b0, 2'd0, 7'd58, 14'd305};
            7'd53: spin_tab = {1'b0, 1'b0, 2'd0, 7'd61, 14'd290};
            7'd54: spin_tab = {1'b0, 1'b0, 2'd0, 7'd63, 14'd280};
            7'd55: spin_tab = {1'b0, 1'b0, 2'd0, 7'd65, 14'd272};
            7'd56: spin_tab = {1'b0, 1'b0, 2'd0, 7'd67, 14'd264};
            7'd57: spin_tab = {1'b0, 1'b0, 2'd0, 7'd68, 14'd260};
            7'd58: spin_tab = {1'b0, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd59: spin_tab = {1'b0, 1'b0, 2'd0, 7'd69, 14'd256};
            7'd60: spin_tab = {1'b0, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd61: spin_tab = {1'b0, 1'b1, 2'd0, 7'd68, 14'd260};
            7'd62: spin_tab = {1'b0, 1'b1, 2'd0, 7'd67, 14'd264};
            7'd63: spin_tab = {1'b0, 1'b1, 2'd0, 7'd65, 14'd272};
            7'd64: spin_tab = {1'b0, 1'b1, 2'd0, 7'd63, 14'd280};
            7'd65: spin_tab = {1'b0, 1'b1, 2'd0, 7'd61, 14'd290};
            7'd66: spin_tab = {1'b0, 1'b1, 2'd0, 7'd58, 14'd305};
            7'd67: spin_tab = {1'b0, 1'b1, 2'd1, 7'd55, 14'd321};
            7'd68: spin_tab = {1'b0, 1'b1, 2'd1, 7'd51, 14'd346};
            7'd69: spin_tab = {1'b0, 1'b1, 2'd1, 7'd47, 14'd376};
            7'd70: spin_tab = {1'b0, 1'b1, 2'd1, 7'd43, 14'd411};
            7'd71: spin_tab = {1'b0, 1'b1, 2'd1, 7'd39, 14'd453};
            7'd72: spin_tab = {1'b0, 1'b1, 2'd2, 7'd34, 14'd520};
            7'd73: spin_tab = {1'b0, 1'b1, 2'd2, 7'd30, 14'd589};
            7'd74: spin_tab = {1'b0, 1'b1, 2'd2, 7'd25, 14'd707};
            7'd75: spin_tab = {1'b0, 1'b1, 2'd3, 7'd20, 14'd883};
            7'd76: spin_tab = {1'b0, 1'b1, 2'd3, 7'd15, 14'd1178};
            7'd77: spin_tab = {1'b0, 1'b1, 2'd3, 7'd10, 14'd1766};
            7'd78: spin_tab = {1'b0, 1'b1, 2'd3, 7'd5, 14'd3533};
            7'd79: spin_tab = {1'b0, 1'b1, 2'd3, 7'd2, 14'd8832};
            7'd80: spin_tab = {1'b1, 1'b1, 2'd3, 7'd5, 14'd3533};
            7'd81: spin_tab = {1'b1, 1'b1, 2'd3, 7'd10, 14'd1766};
            7'd82: spin_tab = {1'b1, 1'b1, 2'd3, 7'd14, 14'd1262};
            7'd83: spin_tab = {1'b1, 1'b1, 2'd3, 7'd19, 14'd930};
            7'd84: spin_tab = {1'b1, 1'b1, 2'd2, 7'd23, 14'd768};
            7'd85: spin_tab = {1'b1, 1'b1, 2'd2, 7'd27, 14'd654};
            7'd86: spin_tab = {1'b1, 1'b1, 2'd2, 7'd31, 14'd570};
            7'd87: spin_tab = {1'b1, 1'b1, 2'd2, 7'd35, 14'd505};
            7'd88: spin_tab = {1'b1, 1'b1, 2'd1, 7'd38, 14'd465};
            7'd89: spin_tab = {1'b1, 1'b1, 2'd1, 7'd42, 14'd421};
            7'd90: spin_tab = {1'b1, 1'b1, 2'd1, 7'd45, 14'd393};
            7'd91: spin_tab = {1'b1, 1'b1, 2'd1, 7'd48, 14'd368};
            7'd92: spin_tab = {1'b1, 1'b1, 2'd1, 7'd50, 14'd353};
            7'd93: spin_tab = {1'b1, 1'b1, 2'd1, 7'd53, 14'd333};
            7'd94: spin_tab = {1'b1, 1'b1, 2'd1, 7'd55, 14'd321};
            7'd95: spin_tab = {1'b1, 1'b1, 2'd0, 7'd57, 14'd310};
            7'd96: spin_tab = {1'b1, 1'b1, 2'd0, 7'd59, 14'd299};
            7'd97: spin_tab = {1'b1, 1'b1, 2'd0, 7'd60, 14'd294};
            7'd98: spin_tab = {1'b1, 1'b1, 2'd0, 7'd62, 14'd285};
            7'd99: spin_tab = {1'b1, 1'b1, 2'd0, 7'd63, 14'd280};
            7'd100: spin_tab = {1'b1, 1'b1, 2'd0, 7'd64, 14'd276};
            7'd101: spin_tab = {1'b1, 1'b1, 2'd0, 7'd65, 14'd272};
            7'd102: spin_tab = {1'b1, 1'b1, 2'd0, 7'd66, 14'd268};
            7'd103: spin_tab = {1'b1, 1'b1, 2'd0, 7'd66, 14'd268};
            7'd104: spin_tab = {1'b1, 1'b1, 2'd0, 7'd67, 14'd264};
            7'd105: spin_tab = {1'b1, 1'b1, 2'd0, 7'd68, 14'd260};
            7'd106: spin_tab = {1'b1, 1'b1, 2'd0, 7'd68, 14'd260};
            7'd107: spin_tab = {1'b1, 1'b1, 2'd0, 7'd68, 14'd260};
            7'd108: spin_tab = {1'b1, 1'b1, 2'd0, 7'd68, 14'd260};
            7'd109: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd110: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd111: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd112: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd113: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd114: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd115: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd116: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd117: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd118: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd119: spin_tab = {1'b1, 1'b1, 2'd0, 7'd69, 14'd256};
            7'd120: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            default: spin_tab = {1'b1, 1'b0, 2'd0, 7'd69, 14'd256};
            endcase
        end
    endfunction
    function [11:0] absd;
        input signed [11:0] v;
        absd = v[11] ? -v : v;
    endfunction
    function is_bg;
        input [23:0] p;
        reg [8:0] dr, dg, db;
        begin
            dr = {1'b0, p[23:16]} - {1'b0, BG[23:16]};
            dg = {1'b0, p[15:8]}  - {1'b0, BG[15:8]};
            db = {1'b0, p[7:0]}   - {1'b0, BG[7:0]};
            is_bg = (dr[8] ? (dr >= 9'h1fe) : (dr <= 9'd2)) && (dg[8] ? (dg >= 9'h1fe) : (dg <= 9'd2)) &&
                    (db[8] ? (db >= 9'h1fe) : (db <= 9'd2));
        end
    endfunction
    function [7:0] sat_add;
        input [7:0] c;
        input [7:0] a;
        reg [8:0] s;
        begin
            s = {1'b0, c} + {1'b0, a};
            sat_add = s[8] ? 8'hff : s[7:0];
        end
    endfunction
    function [7:0] dim;
        input [7:0] c;
        input [1:0] lv;
        begin
            case (lv)
                2'd1: dim = c - {3'd0, c[7:3]};
                2'd2: dim = c - {2'd0, c[7:2]};
                2'd3: dim = c - {2'd0, c[7:2]} - {3'd0, c[7:3]};
                default: dim = c;
            endcase
        end
    endfunction

    // ---------------- 帧参数锁存（与 reader 请求同拍） ----------------
    reg [2:0]  q_mode;
    reg        q_clamp, q_band_en, q_circ_on, q_circ_iris, q_glint_on;
    reg        q_sheet, q_slide, q_slide_left, q_hide_win, q_demo;
    reg [8:0]  q_win_lo, q_win_hi;
    reg signed [19:0] q_a_acc0, q_ax0;
    reg [9:0]  q_a_step, q_l1;
    reg [19:0] q_r2;
    reg [24:0] q_tab;
    reg [2:0]  q_index, q_alt;
    reg [3:0]  q_light;
    reg signed [10:0] q_glint;
    reg [10:0] q_bgl_r, q_bgl_g, q_bgl_b;
    reg [18:0] q_split;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_mode <= M_OFF; q_clamp <= 1'b0; q_band_en <= 1'b0; q_circ_on <= 1'b0; q_circ_iris <= 1'b0;
            q_glint_on <= 1'b0;
            q_sheet <= 1'b0; q_slide <= 1'b0; q_slide_left <= 1'b0; q_hide_win <= 1'b0; q_demo <= 1'b0;
            q_win_lo <= 9'd0; q_win_hi <= 9'd479;
            q_a_acc0 <= 20'sd0; q_ax0 <= 20'sd0;
            q_a_step <= 10'd256; q_l1 <= 10'd640;
            q_r2 <= 20'd0; q_tab <= 25'd0;
            q_index <= 3'd0; q_alt <= 3'd0;
            q_light <= 4'd8; q_glint <= 11'sd0;
            q_bgl_r <= 11'd0; q_bgl_g <= 11'd0; q_bgl_b <= 11'd0; q_split <= 19'h7ffff;
        end else if (latch) begin
            q_split <= f_split;
            q_mode <= mode; q_clamp <= clamp_oor; q_band_en <= band_en; q_circ_on <= circ_on; q_circ_iris <= circ_iris;
            q_glint_on <= glint_on;
            q_sheet <= f_sheet; q_slide <= f_slide; q_slide_left <= f_slide_left; q_hide_win <= hide_win; q_demo <= demo;
            q_win_lo <= win_lo; q_win_hi <= win_hi;
            q_a_acc0 <= a_acc0; q_ax0 <= ax0;
            q_a_step <= a_step; q_l1 <= f_slide_cols;
            q_r2 <= circ_r2; q_tab <= spin_tab(spin_k);
            q_index <= f_index; q_alt <= f_alt;
            q_light <= light; q_glint <= glint;
            q_bgl_r <= BG[23:16] * (4'd8 - light);
            q_bgl_g <= BG[15:8]  * (4'd8 - light);
            q_bgl_b <= BG[7:0]   * (4'd8 - light);
        end
    end
    wire [24:0] spin_now = spin_tab(spin_k);
    assign spin_back = spin_now[24];
    wire        buffered = q_mode != M_OFF;
    wire        t_back  = q_tab[24];
    wire        t_lead  = q_tab[23];
    wire [1:0]  t_shade = q_tab[22:21];
    wire [9:0]  t_hs    = {3'd0, q_tab[20:14]};
    wire [13:0] t_inv   = q_tab[13:0];

    // ---------------- 行级：行累加器、圆的纵向平方、组装几何 ----------------
    reg  [11:0] y_q;
    reg  signed [19:0] acc_a;
    reg  signed [11:0] dyv;
    reg  [19:0] dy2;
    localparam signed [11:0] CX_NEG = -CIRC_CX, CY_NEG = -CIRC_CY;
    localparam [19:0] CX2 = CIRC_CX * CIRC_CX, CY2 = CIRC_CY * CIRC_CY;
    wire row_new = y != y_q;
    wire signed [20:0] dy2_step = {{8{dyv[11]}}, dyv, 1'b1};   // 2*dyv + 1
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_q <= 12'd0; acc_a <= 20'sd0; dyv <= 12'sd0; dy2 <= 20'd0;
        end else begin
            y_q <= y;
            if (row_new) begin
                if (y == 12'd0) begin
                    acc_a <= q_a_acc0;
                    dyv <= CY_NEG; dy2 <= CY2;
                end else if (y < 12'd480) begin
                    acc_a <= acc_a + $signed({10'd0, q_a_step});
                    dy2 <= dy2 + dy2_step[19:0];
                    dyv <= dyv + 12'sd1;
                end
            end
        end
    end
    wire signed [11:0] ra = acc_a >>> 8;
    reg  r_win, r_va, r_band, r_bandrow, r_row0, r_active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_win <= 1'b0; r_va <= 1'b0; r_band <= 1'b0; r_bandrow <= 1'b0; r_row0 <= 1'b0; r_active <= 1'b0;
        end else begin
            r_active  <= y < 12'd480;
            r_row0    <= y == 12'd0;
            r_win     <= y >= {3'd0, q_win_lo} && y <= {3'd0, q_win_hi};
            r_va      <= ra >= 0 && ra <= 479;
            r_band    <= q_band_en && ra >= BAND_LO && ra <= BAND_HI &&
                         y >= {3'd0, q_win_lo} && y <= {3'd0, q_win_hi};
            r_bandrow <= y >= BAND_LO && y <= BAND_HI;
        end
    end

    // ---------------- 像素级（提前两拍为像素 nx = x+2 准备：第 1 拍读缓存与标志，第 2 拍合成并寄存） ----------------
    wire [11:0] nx = x + 12'd2;
    wire        x_pre = x == 12'd4093;             // 下一拍 nx = 0：装入行首值
    reg  signed [19:0] ax_q;
    reg  signed [11:0] dxv;
    reg  [19:0] dx2;
    reg  [15:0] sp_acc;
    wire [9:0]  sp_l = CX[9:0] - t_hs;
    wire [9:0]  sp_r = CX[9:0] + t_hs;
    wire        sp_in = nx >= {2'b00, sp_l} && nx < {2'b00, sp_r};
    wire [15:0] sp_cur = (nx == {2'b00, sp_l}) ? {3'd0, t_inv[13:1]} : sp_acc;
    wire signed [20:0] dx2_step = {{8{dxv[11]}}, dxv, 1'b1};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ax_q <= 20'sd0; dxv <= 12'sd0; dx2 <= 20'd0; sp_acc <= 16'd0;
        end else if (x_pre) begin
            ax_q <= q_ax0; dxv <= CX_NEG; dx2 <= CX2; sp_acc <= 16'd0;
        end else begin
            ax_q <= ax_q + $signed({10'd0, q_a_step});
            dx2  <= dx2 + dx2_step[19:0];
            dxv  <= dxv + 12'sd1;
            if (sp_in) sp_acc <= sp_cur + {2'd0, t_inv};
        end
    end
    wire signed [11:0] sxa = ax_q >>> 8;
    wire [20:0] d2 = {1'b0, dx2} + {1'b0, dy2};
    wire        c_in   = q_circ_on && d2 < {1'b0, q_r2};
    wire        nx_act = nx < 12'd640;
    wire        in_wcol = nx >= WX0 && nx <= WX1;

    // ---- 直通遮罩 ----
    wire [9:0]  nxs = nx[9:0];
    wire        seg1 = nxs < q_l1;
    // 本像素读的 bank：滑动按段，Wipe 按字序号（y*640 + x < split 读 index，其余读 alt）
    wire [18:0] widx = {y[8:0], 9'd0} + {2'b00, y[8:0], 7'd0} + {9'd0, nxs};
    wire [2:0]  sbank = q_slide ? ((seg1 ^ !q_slide_left) ? q_alt : q_index) : (widx < q_split) ? q_index : q_alt;
    wire [11:0] scol = !q_slide ? nx : seg1 ? nx + 12'd640 - {2'b00, q_l1} : nx - {2'b00, q_l1};
    wire        m_stash = !q_sheet && sbank == 3'd0 && scol >= SX0 && scol <= SX1 && y >= SY0 && y <= SY1;
    wire        m_win   = !q_sheet && q_hide_win && sbank == 3'd1 && scol >= WX0 && scol <= WX1 && y >= BAND_LO && y <= BAND_HI;
    wire        m_thumb = q_sheet && nx >= TX0 && nx <= TX1 && y >= TY0 && y <= TY1;
    wire        m_iris  = q_circ_iris && !c_in;

    // ---- ZOOM ----
    wire signed [11:0] sxa_c = (sxa < 0) ? 12'sd0 : (sxa > 639) ? 12'sd639 : sxa;
    wire        a_ok = q_clamp || (r_va && sxa >= 0 && sxa <= 639);
    wire        a_phone = sxa >= FX0 && sxa < FX0 + PW;

    // ---- SPIN ----
    wire [15:0] sp_colf = sp_cur >> 8;
    wire [9:0]  sp_col = (sp_colf > PW - 1) ? PW - 1 : sp_colf[9:0];
    wire        sp_edge = t_shade != 2'd0 && (t_lead ? nx == {2'b00, sp_l} : nx == {2'b00, sp_r} - 12'd1);

    // ---- 下标与标志（寄存后与读数对齐） ----
    localparam [2:0] K_PIX = 3'd0, K_BG = 3'd1, K_BLACK = 3'd2;
    reg  [9:0] idx;
    reg  [2:0] kind;
    reg  [7:0] add;
    reg        blend, shade_on, bgk;
    always @* begin
        idx = nx[9:0]; kind = K_PIX; add = 8'd0; blend = 1'b0; shade_on = 1'b0; bgk = 1'b0;
        case (q_mode)
            M_ZOOM: begin
                idx = sxa_c[9:0];
                if (!a_ok) kind = K_BLACK;
                else if (r_band && !a_phone) kind = K_BG;
            end
            M_SPIN: begin
                if (r_bandrow) begin
                    if (sp_in) begin
                        idx = FX0 + sp_col; shade_on = 1'b1; bgk = 1'b1;
                        if (sp_edge) add = 8'd80;
                    end else kind = K_BG;
                end
            end
            M_ASM: begin
                if (r_win) begin
                    if (!in_wcol || !r_band || !a_phone) kind = K_BG;
                    else begin blend = 1'b1; bgk = 1'b1; idx = sxa[9:0]; end
                end
            end
            default: ;
        endcase
        if (buffered && r_row0) kind = K_BLACK;
    end

    // ---------------- 两行乒乓缓存（写当前行，读上一行） ----------------
    reg [23:0] lbuf [0:2047];
    reg [23:0] lq;
    always @(posedge clk) begin
        if (de && buffered) lbuf[{y[0], x[9:0]}] <= rgb_in;
        lq <= lbuf[{~y[0], idx}];
    end
    reg  [2:0] k_q;
    reg  [7:0] add_q;
    reg        blend_q, shade_q, bgk_q, m_bg_q, m_black_q, glint_q;
    // 高光带坐标：12 位运算（只用于组装窗口内的手机像素，blend=1）
    localparam [11:0] GLX = GL_X0, GLY = GL_Y0;
    wire [11:0] gdx = nx - GLX;
    wire [11:0] gdy = y - GLY;
    wire [11:0] gu = gdx + {1'b0, gdy[11:1]};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_q <= K_PIX; add_q <= 8'd0; blend_q <= 1'b0; shade_q <= 1'b0; bgk_q <= 1'b0;
            m_bg_q <= 1'b0; m_black_q <= 1'b0; glint_q <= 1'b0;
        end else begin
            k_q <= kind; add_q <= add; blend_q <= blend; shade_q <= shade_on; bgk_q <= bgk;
            m_bg_q <= !buffered && q_demo && (m_stash || m_win || m_thumb);
            m_black_q <= !buffered && m_iris;
            glint_q <= q_glint_on && blend && $signed(gu) >= q_glint && $signed(gu) < q_glint + 11'sd14;
        end
    end
    // ---------------- 本拍：取色与合成 ----------------
    wire        p_bg = is_bg(lq);
    // 渐亮混合 = c*light + BG*(8-light)（light <= 8，和 <= 2040）；乘法交给 DSP
    wire [11:0] mr = lq[23:16] * q_light, mg = lq[15:8] * q_light, mb = lq[7:0] * q_light;
    wire [10:0] pr = mr[10:0] + q_bgl_r;
    wire [10:0] pg = mg[10:0] + q_bgl_g;
    wire [10:0] pb = mb[10:0] + q_bgl_b;
    wire [23:0] c_bl = blend_q ? {pr[10:3], pg[10:3], pb[10:3]} : lq;
    wire [23:0] c_sh = shade_q ? {dim(c_bl[23:16], t_shade), dim(c_bl[15:8], t_shade), dim(c_bl[7:0], t_shade)} : c_bl;
    wire [7:0]  a2 = glint_q ? ((add_q > 8'd185) ? 8'd255 : add_q + 8'd70) : add_q;
    wire [23:0] c_ad = {sat_add(c_sh[23:16], a2), sat_add(c_sh[15:8], a2), sat_add(c_sh[7:0], a2)};
    wire [23:0] buf_rgb = (k_q == K_BG || (bgk_q && p_bg)) ? BG :
                          (k_q == K_BLACK) ? 24'h000000 : c_ad;
    // 第 2 拍：合成结果寄存，切断行缓存读出到下游亮度 / 对比度乘法的长组合路径
    reg  [23:0] out_q;
    reg         use_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_q <= 24'd0; use_q <= 1'b0; end
        else begin
            out_q <= buffered ? buf_rgb : m_black_q ? 24'h000000 : BG;
            use_q <= buffered || m_black_q || m_bg_q;
        end
    end
    assign rgb_out = (de && use_q) ? out_q : rgb_in;
endmodule
