`timescale 1ns/1ps

// 第 13 课加载时缩放：任意 W x H（1..MAX）源像素流 -> 固定 OUT_W x OUT_H 输出流，等比居中、黑边填充。
// 行序与输入相同（文件顺序）；top_down 只决定先输出哪一侧的黑边，垂直翻转由写端口完成。
// 采样点（中心对齐）：p(d) = (d + 0.5) * step - 0.5，step = floor(src * 65536 / dst)（Q16）。
// BILINEAR=0 最近邻：idx = round(p) = floor((d + 0.5) * step)。
// BILINEAR=1 双线性（先水平后垂直，各自舍入）：取 floor(p) 与其右/下邻点，按 p 的 8 位小数 f 加权，
//   lerp(a, b, f) = a + floor(((b - a) * f + 128) / 256)；p < 0 或 floor(p) >= 末像素时钳位、f = 0。
// 640x480 源 step=1.0、f 恒 0，两种模式输出都与输入逐像素相同。
// 结构：源 FIFO -> 水平映射（插值）写行缓冲 -> 垂直 + 黑边 -> 每 OUT_INTERVAL 拍一个像素。
// 垂直最近邻：两行乒乓，每源行复制 k 次（k 可为 0）；双线性：三行环形，每像素先后读上下两行，四级流水后插值，
// 要求 OUT_INTERVAL >= 2。
// start 单拍：锁存几何并清空全部状态；abort 电平：清空并停止输出。src_hold 为 FIFO 余量不足，
// 上游须停止发起新扇区（在途扇区照常送达，故 HOLD_LEVEL 须留出 >= 一个扇区的像素）。
module media_image_scaler #(
    parameter integer OUT_W        = 640,
    parameter integer OUT_H        = 480,
    parameter integer FIFO_AW      = 9,
    parameter integer HOLD_LEVEL   = 256,
    parameter integer OUT_INTERVAL = 16,
    parameter integer BILINEAR     = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        abort,
    input  wire [11:0] src_w,
    input  wire [11:0] src_h,
    input  wire        src_top_down,
    input  wire        in_valid,
    input  wire [23:0] in_rgb,
    output reg         src_hold,
    output reg         out_valid,
    output reg  [23:0] out_rgb,
    output wire        busy,
    output reg         frame_done,
    output reg         overflow
);
    localparam [9:0] OW = OUT_W;
    localparam [8:0] OH = OUT_H;
    localparam integer FIFO_DEPTH = 1 << FIFO_AW;
    // synthesis translate_off
    initial if (BILINEAR && OUT_INTERVAL < 2) begin
        $display("MEDIA_CONFIG_ERROR media_image_scaler %m: BILINEAR requires OUT_INTERVAL >= 2");
        $finish;
    end
    // synthesis translate_on

    function [7:0] lerp8;
        input [7:0] a, b, f;
        reg signed [9:0]  d;
        reg signed [18:0] t;
        begin
            d = $signed({2'b00, b}) - $signed({2'b00, a});
            t = d * $signed({1'b0, f}) + 19'sd128;
            lerp8 = a + t[15:8];
        end
    endfunction
    function [23:0] lerp24;
        input [23:0] a, b;
        input [7:0]  f;
        lerp24 = {lerp8(a[23:16], b[23:16], f), lerp8(a[15:8], b[15:8], f), lerp8(a[7:0], b[7:0], f)};
    endfunction

    // ---------------- 源 FIFO（单时钟，寄存读） ----------------
    reg [23:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW-1:0] fifo_wp, fifo_rp;
    reg [FIFO_AW:0] fifo_cnt;
    reg [23:0] fifo_q;
    wire fifo_empty = (fifo_cnt == 0);
    wire fifo_full = fifo_cnt[FIFO_AW];
    wire fifo_rd;
    wire clear = start || abort;
    wire fifo_wr = in_valid && !fifo_full && !clear;

    always @(posedge clk) begin
        if (fifo_wr) fifo_mem[fifo_wp] <= in_rgb;
        if (fifo_rd) fifo_q <= fifo_mem[fifo_rp];
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fifo_wp <= 0; fifo_rp <= 0; fifo_cnt <= 0;
            src_hold <= 1'b0; overflow <= 1'b0;
        end else if (clear) begin
            fifo_wp <= 0; fifo_rp <= 0; fifo_cnt <= 0;
            src_hold <= 1'b0;
            if (start) overflow <= 1'b0;
        end else begin
            if (fifo_wr) fifo_wp <= fifo_wp + 1'b1;
            if (fifo_rd) fifo_rp <= fifo_rp + 1'b1;
            case ({fifo_wr, fifo_rd})
                2'b10: fifo_cnt <= fifo_cnt + 1'b1;
                2'b01: fifo_cnt <= fifo_cnt - 1'b1;
                default: ;
            endcase
            src_hold <= (fifo_cnt >= HOLD_LEVEL);
            if (in_valid && fifo_full) overflow <= 1'b1;
        end
    end

    // ---------------- 几何：一个顺序除法器，三次相除 ----------------
    // wide：W*OH >= H*OW 时以宽为准 dw=OW、dh=round(H*OW/W)；否则 dh=OH、dw=round(W*OH/H)。
    reg [11:0] W, H;
    reg        top_down;
    reg [9:0]  dw;
    reg [8:0]  dh;
    reg [19:0] step_x, step_y;
    reg [9:0]  ox;
    reg [8:0]  lead_rows, trail_rows;
    reg        wide;
    reg [2:0]  g_state;
    localparam G_IDLE = 3'd0, G_CMP = 3'd1, G_D1 = 3'd2, G_D2 = 3'd3, G_D3 = 3'd4, G_RUN = 3'd5;
    wire g_ready = (g_state == G_RUN);

    reg [27:0] div_num, div_q;
    reg [11:0] div_den;
    reg [12:0] div_rem;
    reg [4:0]  div_cnt;
    reg        div_busy;
    wire [12:0] div_shift = {div_rem[11:0], div_num[27]};
    wire        div_ge = div_shift >= {1'b0, div_den};
    wire [27:0] div_result = {div_q[26:0], div_ge};
    wire        div_last = div_busy && (div_cnt == 5'd27);

    wire [23:0] w_x_oh = W * OH;
    wire [23:0] h_x_ow = H * OW;
    wire        wide_c = (w_x_oh >= h_x_ow);
    wire [8:0]  dh_q = (div_result == 0) ? 9'd1 : div_result[8:0];
    wire [9:0]  dw_q = (div_result == 0) ? 10'd1 : div_result[9:0];
    wire [8:0]  oy_w = (OH - dh) >> 1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            g_state <= G_IDLE; W <= 12'd1; H <= 12'd1; top_down <= 1'b0; wide <= 1'b0;
            dw <= OW; dh <= OH; step_x <= 20'd0; step_y <= 20'd0; ox <= 10'd0;
            lead_rows <= 9'd0; trail_rows <= 9'd0;
            div_num <= 0; div_q <= 0; div_den <= 12'd1; div_rem <= 0; div_cnt <= 0; div_busy <= 1'b0;
        end else if (abort) begin
            g_state <= G_IDLE; div_busy <= 1'b0;
        end else if (start) begin
            W <= src_w; H <= src_h; top_down <= src_top_down;
            div_busy <= 1'b0;
            g_state <= G_CMP;
        end else begin
            if (div_busy) begin
                div_rem <= div_ge ? (div_shift - {1'b0, div_den}) : div_shift;
                div_q <= div_result;
                div_num <= {div_num[26:0], 1'b0};
                div_cnt <= div_cnt + 1'b1;
                if (div_last) div_busy <= 1'b0;
            end
            case (g_state)
                G_CMP: begin
                    wide <= wide_c;
                    div_num <= wide_c ? {4'd0, h_x_ow} + {17'd0, W[11:1]}
                                      : {4'd0, w_x_oh} + {17'd0, H[11:1]};
                    div_den <= wide_c ? W : H;
                    div_rem <= 0; div_q <= 0; div_cnt <= 0; div_busy <= 1'b1;
                    g_state <= G_D1;
                end
                G_D1: if (div_last) begin
                    dw <= wide ? OW : ((dw_q > OW) ? OW : dw_q);
                    dh <= wide ? ((dh_q > OH) ? OH : dh_q) : OH;
                    div_num <= {W, 16'd0};
                    div_den <= wide ? {2'd0, OW} : {2'd0, ((dw_q > OW) ? OW : dw_q)};
                    div_rem <= 0; div_q <= 0; div_cnt <= 0; div_busy <= 1'b1;
                    g_state <= G_D2;
                end
                G_D2: if (div_last) begin
                    step_x <= div_result[19:0];
                    div_num <= {H, 16'd0};
                    div_den <= {3'd0, dh};
                    div_rem <= 0; div_q <= 0; div_cnt <= 0; div_busy <= 1'b1;
                    g_state <= G_D3;
                end
                G_D3: if (div_last) begin
                    step_y <= div_result[19:0];
                    ox <= (OW - dw) >> 1;
                    // 文件首行在下方（自下而上）时先输出下侧黑边；下侧比上侧多出的奇数行在下方。
                    lead_rows <= top_down ? oy_w : (OH - dh - oy_w);
                    trail_rows <= top_down ? (OH - dh - oy_w) : oy_w;
                    g_state <= G_RUN;
                end
                default: ;
            endcase
        end
    end

    // ---------------- 行缓冲：{选择位, 列} ----------------
    reg [23:0] lb_mem [0:2047];
    reg        lb_we;
    reg [10:0] lb_waddr, lb_raddr;
    reg [23:0] lb_wdata, lb_q;
    always @(posedge clk) begin
        if (lb_we) lb_mem[lb_waddr] <= lb_wdata;
        lb_q <= lb_mem[lb_raddr];
    end

    // ---------------- 水平：每个源像素写出所有以它为采样点（双线性为右邻点）的输出列 ----------------
    reg [1:0]  h_state;
    localparam H_IDLE = 2'd0, H_POP = 2'd1, H_CAP = 2'd2, H_EMIT = 2'd3;
    reg        wsel;
    reg [1:0]  wslot;
    reg [10:0] wbase;
    reg [11:0] h_x, h_cnt, h_row;
    reg [9:0]  h_d;
    reg [27:0] acc_x;
    reg [23:0] cur_pix, prev_pix;
    reg        h_row_done;
    wire       h_allow;
    wire [11:0] nn_x = acc_x[27:16];
    wire        bx_neg = (acc_x < 28'h0008000);
    wire [27:0] bx_p = acc_x - 28'h0008000;
    wire [11:0] bx_i0 = bx_neg ? 12'd0 : bx_p[27:16];
    wire        bx_last = (bx_i0 >= W - 1'b1);
    wire [11:0] bx_t = bx_last ? (W - 1'b1) : (bx_i0 + 1'b1);
    wire [7:0]  bx_f = (bx_neg || bx_last) ? 8'd0 : bx_p[15:8];
    wire        h_hit = BILINEAR ? (bx_t == h_x) : (nn_x == h_x);
    // 写行缓冲分两拍：H_EMIT 只锁存左右像素、权重与地址，lerp（含乘法）放到下一拍，否则 acc_x→lb_wdata 一拍约 19.5 ns。
    // 行结束脉冲随之晚一拍，保证通告时整行已写完；clear 丢弃在途的一拍。
    reg        hp_we, hp_done;
    reg [10:0] hp_addr;
    reg [23:0] hp_a, hp_b;
    reg [7:0]  hp_f;
    assign fifo_rd = (h_state == H_POP) && !fifo_empty && !clear;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            h_state <= H_IDLE; wsel <= 1'b0; wslot <= 2'd0; wbase <= 11'd0;
            h_x <= 0; h_cnt <= 0; h_row <= 0; h_d <= 0;
            acc_x <= 0; cur_pix <= 0; prev_pix <= 0; lb_we <= 1'b0; lb_waddr <= 0; lb_wdata <= 0;
            h_row_done <= 1'b0;
            hp_we <= 1'b0; hp_done <= 1'b0; hp_addr <= 0; hp_a <= 0; hp_b <= 0; hp_f <= 0;
        end else begin
            hp_we <= 1'b0;
            hp_done <= 1'b0;
            lb_we <= hp_we && !clear;
            lb_waddr <= hp_addr;
            lb_wdata <= BILINEAR ? lerp24(hp_a, hp_b, hp_f) : hp_b;
            h_row_done <= hp_done && !clear;
            if (clear) begin
                h_state <= H_IDLE; wsel <= 1'b0; wslot <= 2'd0; wbase <= 11'd0; h_row <= 0;
            end else case (h_state)
                H_IDLE: if (g_ready && h_allow && h_row != H) begin
                    h_cnt <= 0; h_d <= 0; acc_x <= {8'd0, step_x[19:1]};
                    h_state <= H_POP;
                end
                H_POP: if (!fifo_empty) h_state <= H_CAP;
                H_CAP: begin
                    prev_pix <= cur_pix;
                    cur_pix <= fifo_q;
                    h_x <= h_cnt;
                    h_cnt <= h_cnt + 1'b1;
                    h_state <= H_EMIT;
                end
                H_EMIT: begin
                    if (h_d != dw && h_hit) begin
                        hp_we <= 1'b1;
                        hp_addr <= BILINEAR ? (wbase + {1'b0, h_d}) : {wsel, h_d};
                        hp_a <= bx_last ? cur_pix : prev_pix;
                        hp_b <= cur_pix;
                        hp_f <= bx_f;
                        h_d <= h_d + 1'b1;
                        acc_x <= acc_x + {8'd0, step_x};
                    end else if (h_x == W - 1'b1) begin
                        hp_done <= 1'b1;
                        wsel <= ~wsel;
                        wslot <= (wslot == 2'd2) ? 2'd0 : wslot + 2'd1;
                        wbase <= (wslot == 2'd2) ? 11'd0 : wbase + {1'b0, OW};
                        h_row <= h_row + 1'b1;
                        h_state <= H_IDLE;
                    end else begin
                        h_state <= H_POP;
                    end
                end
            endcase
        end
    end

    generate if (!BILINEAR) begin : g_vnn
    // ---------------- 垂直（最近邻）：黑边行 -> 每源行复制 k 次（k 可为 0）-> 黑边行 ----------------
    reg [1:0]  lb_full;
    assign h_allow = !lb_full[wsel];
    reg [2:0]  v_state;
    localparam V_IDLE = 3'd0, V_NEXT = 3'd1, V_LINE = 3'd2, V_FLUSH = 3'd3, V_DONE = 3'd4;
    reg [1:0]  v_phase;   // 0 前黑边 1 图像 2 后黑边
    reg        rsel;
    reg [11:0] v_row;
    reg [8:0]  v_e, v_pad;
    reg [27:0] acc_y;
    wire [11:0] idx_y = acc_y[27:16];
    reg        line_black;
    reg [9:0]  v_px;
    reg [7:0]  pace;
    reg        s1_valid, s1_black, s2_valid, s2_black;
    reg        v_release;
    wire       tick = (pace == 0);
    wire [9:0] col = v_px - ox;
    wire       in_col = (v_px >= ox) && (v_px < ox + dw);
    assign busy = (g_state != G_IDLE) && (v_state != V_DONE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            v_state <= V_IDLE; v_phase <= 2'd0; rsel <= 1'b0; v_row <= 0; v_e <= 0; v_pad <= 0;
            acc_y <= 0; line_black <= 1'b1; v_px <= 0; pace <= 0;
            s1_valid <= 1'b0; s1_black <= 1'b1; s2_valid <= 1'b0; s2_black <= 1'b1;
            lb_raddr <= 0; out_valid <= 1'b0; out_rgb <= 0; frame_done <= 1'b0; v_release <= 1'b0;
        end else begin
            out_valid <= s2_valid;
            out_rgb <= s2_black ? 24'd0 : lb_q;
            s2_valid <= s1_valid;
            s2_black <= s1_black;
            s1_valid <= 1'b0;
            frame_done <= 1'b0;
            v_release <= 1'b0;
            if (pace != 0) pace <= pace - 1'b1;
            if (clear) begin
                v_state <= V_IDLE; s1_valid <= 1'b0; s2_valid <= 1'b0; out_valid <= 1'b0;
                rsel <= 1'b0; pace <= 0;
            end else case (v_state)
                V_IDLE: if (g_ready) begin
                    v_phase <= 2'd0; v_row <= 0; v_e <= 0; v_pad <= lead_rows;
                    acc_y <= {8'd0, step_y[19:1]};
                    v_state <= V_NEXT;
                end
                V_NEXT: begin
                    case (v_phase)
                        2'd0: if (v_pad != 0) begin
                            v_pad <= v_pad - 1'b1; line_black <= 1'b1; v_px <= 0; v_state <= V_LINE;
                        end else v_phase <= 2'd1;
                        2'd1: if (v_row == H) begin
                            v_phase <= 2'd2; v_pad <= trail_rows;
                        end else if (lb_full[rsel]) begin
                            if (v_e != dh && idx_y == v_row) begin
                                v_e <= v_e + 1'b1;
                                acc_y <= acc_y + {8'd0, step_y};
                                line_black <= 1'b0; v_px <= 0; v_state <= V_LINE;
                            end else begin
                                v_release <= 1'b1;
                                rsel <= ~rsel;
                                v_row <= v_row + 1'b1;
                            end
                        end
                        default: if (v_pad != 0) begin
                            v_pad <= v_pad - 1'b1; line_black <= 1'b1; v_px <= 0; v_state <= V_LINE;
                        end else v_state <= V_FLUSH;
                    endcase
                end
                V_LINE: if (tick) begin
                    pace <= OUT_INTERVAL - 1;
                    lb_raddr <= {rsel, col};
                    s1_valid <= 1'b1;
                    s1_black <= line_black || !in_col;
                    if (v_px == OW - 1'b1) v_state <= V_NEXT;
                    else v_px <= v_px + 1'b1;
                end
                V_FLUSH: if (!s1_valid && !s2_valid && !out_valid && tick) begin
                    frame_done <= 1'b1;
                    v_state <= V_DONE;
                end
                default: ;
            endcase
        end
    end

    // 行缓冲占用：水平写满置位，垂直用完清除（同一缓冲不会同拍置位又清除）
    always @(posedge clk or posedge rst) begin
        if (rst) lb_full <= 2'b00;
        else if (clear) lb_full <= 2'b00;
        else begin
            if (h_row_done) lb_full[~wsel] <= 1'b1;
            if (v_release) lb_full[~rsel] <= 1'b0;
        end
    end
    end else begin : g_vbl
    // ---------------- 垂直（双线性）----------------
    // 源行 r 写入环形槽 r mod 3；base = 仍需保留的最低源行，写侧只在 h_row < base + 3 时开新行。
    // 输出行 e：q = (e + 0.5) * sy - 0.5，j0 = floor(q)（钳位），j1 = min(j0 + 1, H - 1)，fy = q 的 8 位小数。
    // 每个像素 tick 拍发 j0 行地址、下一拍发 j1 行地址；四级流水后插值，黑边像素同样走流水、末级置黑。
    reg [11:0] rows_done, base, j0, j1;
    reg [1:0]  base_slot;
    reg [7:0]  fy;
    reg [10:0] a_base, b_base;
    reg [3:0]  v_state;
    localparam B_IDLE = 4'd0, B_LEAD = 4'd1, B_CALC = 4'd2, B_ADV = 4'd3, B_WAIT = 4'd4, B_LINE = 4'd5,
               B_BLACK = 4'd6, B_DRAIN = 4'd7, B_TRAIL = 4'd8, B_FLUSH = 4'd9, B_DONE = 4'd10;
    reg [8:0]  v_e, v_pad;
    reg [27:0] acc_y;
    reg        from_trail;
    reg [9:0]  v_px, rd_col;
    reg [7:0]  pace;
    reg        rd2;
    reg [3:0]  pv, pblk;
    // fy 每行恒定且换行至少隔 B_CALC/B_ADV/B_WAIT 三拍，权重流水只需保证行末像素不取到下一行的 fy
    reg [7:0]  pf1, pf2, pf3, pf4;
    reg [23:0] top_q, pa, pb;
    wire       tick = (pace == 0);
    wire [9:0] col = v_px - ox;
    wire       in_col = (v_px >= ox) && (v_px < ox + dw);
    wire        by_neg = (acc_y < 28'h0008000);
    wire [27:0] by_p = acc_y - 28'h0008000;
    wire [11:0] by_i0 = by_neg ? 12'd0 : by_p[27:16];
    wire        by_last = (by_i0 >= H - 1'b1);
    wire [11:0] by_j0 = by_last ? (H - 1'b1) : by_i0;
    wire [7:0]  by_f = (by_neg || by_last) ? 8'd0 : by_p[15:8];
    wire [1:0]  next_slot = (base_slot == 2'd2) ? 2'd0 : base_slot + 2'd1;
    wire [10:0] base_addr = (base_slot == 2'd0) ? 11'd0 : (base_slot == 2'd1) ? {1'b0, OW} : {OW, 1'b0};
    wire [10:0] next_addr = (next_slot == 2'd0) ? 11'd0 : (next_slot == 2'd1) ? {1'b0, OW} : {OW, 1'b0};
    assign h_allow = ({1'b0, h_row} < {1'b0, base} + 13'd3);
    assign busy = (g_state != G_IDLE) && (v_state != B_DONE);

    always @(posedge clk or posedge rst) begin
        if (rst) rows_done <= 0;
        else if (clear) rows_done <= 0;
        else if (h_row_done) rows_done <= rows_done + 1'b1;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            v_state <= B_IDLE; base <= 0; base_slot <= 2'd0; j0 <= 0; j1 <= 0; fy <= 0;
            a_base <= 0; b_base <= 0; v_e <= 0; v_pad <= 0; acc_y <= 0; from_trail <= 1'b0;
            v_px <= 0; rd_col <= 0; pace <= 0; rd2 <= 1'b0;
            pv <= 4'd0; pblk <= 4'hf; pf1 <= 0; pf2 <= 0; pf3 <= 0; pf4 <= 0;
            top_q <= 0; pa <= 0; pb <= 0;
            lb_raddr <= 0; out_valid <= 1'b0; out_rgb <= 0; frame_done <= 1'b0;
        end else begin
            // pv[0]：已发 j0 地址；[1]：lb_q=j0 行、已发 j1 地址；[2]：top_q=j0、lb_q=j1；[3]：pa/pb 就绪
            pv <= {pv[2:0], 1'b0};
            pblk <= {pblk[2:0], 1'b1};
            pf2 <= pf1; pf3 <= pf2; pf4 <= pf3;
            top_q <= lb_q;
            pa <= top_q;
            pb <= lb_q;
            out_valid <= pv[3];
            out_rgb <= pblk[3] ? 24'd0 : lerp24(pa, pb, pf4);
            frame_done <= 1'b0;
            rd2 <= 1'b0;
            if (rd2) lb_raddr <= b_base + {1'b0, rd_col};
            if (pace != 0) pace <= pace - 1'b1;
            if (clear) begin
                v_state <= B_IDLE; pv <= 4'd0; out_valid <= 1'b0; pace <= 0; rd2 <= 1'b0;
                base <= 0; base_slot <= 2'd0;
            end else case (v_state)
                B_IDLE: if (g_ready) begin
                    v_e <= 0; v_pad <= lead_rows; base <= 0; base_slot <= 2'd0;
                    acc_y <= {8'd0, step_y[19:1]};
                    from_trail <= 1'b0;
                    v_state <= B_LEAD;
                end
                B_LEAD: if (v_pad != 0) begin
                    v_pad <= v_pad - 1'b1; v_px <= 0; v_state <= B_BLACK;
                end else v_state <= B_CALC;
                B_CALC: if (v_e == dh) begin
                    base <= H;              // 放行写侧读完（丢弃）剩余源行
                    v_state <= B_DRAIN;
                end else begin
                    j0 <= by_j0;
                    j1 <= by_last ? (H - 1'b1) : (by_j0 + 1'b1);
                    fy <= by_f;
                    v_state <= B_ADV;
                end
                B_ADV: if (base != j0) begin
                    base <= base + 1'b1;
                    base_slot <= next_slot;
                end else begin
                    a_base <= base_addr;
                    b_base <= (j1 == j0) ? base_addr : next_addr;
                    v_state <= B_WAIT;
                end
                B_WAIT: if (rows_done > j1) begin
                    v_px <= 0; v_state <= B_LINE;
                end
                B_LINE, B_BLACK: if (tick) begin
                    pace <= OUT_INTERVAL - 1;
                    lb_raddr <= a_base + {1'b0, col};
                    rd_col <= col;
                    rd2 <= 1'b1;
                    pv[0] <= 1'b1;
                    pblk[0] <= (v_state == B_BLACK) || !in_col;
                    pf1 <= fy;
                    if (v_px == OW - 1'b1) begin
                        if (v_state == B_BLACK) v_state <= from_trail ? B_TRAIL : B_LEAD;
                        else begin
                            v_e <= v_e + 1'b1;
                            acc_y <= acc_y + {8'd0, step_y};
                            v_state <= B_CALC;
                        end
                    end else v_px <= v_px + 1'b1;
                end
                B_DRAIN: if (rows_done == H) begin
                    v_pad <= trail_rows; from_trail <= 1'b1; v_state <= B_TRAIL;
                end
                B_TRAIL: if (v_pad != 0) begin
                    v_pad <= v_pad - 1'b1; v_px <= 0; v_state <= B_BLACK;
                end else v_state <= B_FLUSH;
                B_FLUSH: if (pv == 4'd0 && !out_valid && tick) begin
                    frame_done <= 1'b1;
                    v_state <= B_DONE;
                end
                default: ;
            endcase
        end
    end
    end endgenerate
endmodule
