`timescale 1ns/1ps

// D30/D32 观众屏特效时间轴（像素域，每帧在场消隐内走一步，随后用串行乘法器算出下一帧给 reader / media_fx_engine 的参数）。
// 每次“进入”某张图（ok 上升，或 ok 期间槽号变化）播放一次；ok=0（转场、总览页、黑场、未播放）立即停止并清零，
// 推进镜头后的两种“保持”状态除外（等换图转场结束、目标图显示后接着播）。
//   第 2 张（槽 1）：ASM 由远到近推近（gst 540 -> 256）、整体从暗渐亮（D32 资源：底板 / 镜头飞入已去掉）->
//     GLINT 高光斜扫 -> SPIN 转一圈（背面 -> 正面 -> 背面，120 帧）-> BACK 停在背面。
//     go_cam：CAM 以背面主摄 (277,48) 为中心放大（越推越快，256 -> 20）并在最后渐暗到黑，翻转 done_tgl；CAMHOLD 保持黑，
//     进入第 3 张时从其主摄位置 (192,218) 圆形展开（跳过远景推入）。（D32 资源：取消镜头里直接露出第 3 张的两图同屏）
//   第 3 张（槽 2）：DOLLY 由远到近（600 -> 256，中心 (250,175)）-> 停 20 帧 -> FLASH 光晕 + 全屏白 + 快门声 -> 停。
//     go_lens：LENS 以主摄 (192,218) 为中心放大并渐暗到黑，翻转 done_tgl；LENSHOLD 保持黑，进入第 4 张时从主摄位置圆形展开。
//   第 4 张（槽 3）：充电（同 D30），经推进进入时同时 iris 展开。第 5 张（槽 4）：画面内部抖动（行重映射，边缘钳位）。
// flash_w / glow_r / charge_on / fill_x / box_w / shake_* 在 frame_tick 更新（同 D30）；其余输出在乘法算完后（fin）一次性更新。
// 圆形展开的圆心固定为第 3 / 4 张主摄 (192,218)，写在 media_fx_engine 的参数里，这里只给半径平方。
module media_fx_ctrl #(
    parameter integer FILL_X0   = 186,
    parameter integer FILL_X1   = 437,
    parameter integer FILL_STEP = 3,
    parameter integer FILL_WAIT = 12
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              frame_tick,
    input  wire              ok,
    input  wire [2:0]        slot,
    input  wire              shake_hold,
    input  wire              go_cam,
    input  wire              go_lens,
    output reg               done_tgl,
    output reg  [2:0]        mode,
    output reg               clamp_oor,
    output reg               band_en,
    output reg  [8:0]        win_lo,
    output reg  [8:0]        win_hi,
    output reg  [2:0]        a_bank,
    output reg signed [19:0] a_acc0,
    output reg signed [19:0] ax0,
    output reg  [9:0]        a_step,
    output reg               circ_on,
    output reg               circ_iris,
    output reg  [19:0]       circ_r2,         // 圆心固定 (192,218)，在 media_fx_engine 参数里
    output reg  [6:0]        spin_k,
    output reg  [3:0]        light,
    output reg               glint_on,
    output reg signed [10:0] glint,
    output reg  [7:0]        alpha,
    output reg               hide,
    output reg signed [4:0]  shake_dx,
    output reg signed [4:0]  shake_dy,
    output reg  [7:0]        flash_w,
    output reg  [6:0]        glow_r,
    output reg               charge_on,
    output reg  [9:0]        fill_x,
    output reg  [7:0]        box_w,
    output reg               click
);
    localparam [3:0] S_NONE = 4'd0, S_ASM = 4'd1, S_GLINT = 4'd2, S_SPIN = 4'd3, S_BACK = 4'd4, S_CAM = 4'd5,
                     S_CAMHOLD = 4'd6, S_DOLLY = 4'd7, S_PAUSE = 4'd8, S_FLASH = 4'd9, S_DONE2 = 4'd10,
                     S_LENS = 4'd11, S_LENSHOLD = 4'd12, S_CHARGE = 4'd13, S_SHAKE = 4'd14;
    localparam [2:0] M_OFF = 3'd0, M_ZOOM = 3'd1, M_CAM = 3'd2, M_SPIN = 3'd3, M_ASM = 3'd4;

    reg  [3:0]  st;
    reg  [7:0]  f;
    reg  [9:0]  z;          // 当前缩放步长（Q8，256 = 原大）
    reg  [9:0]  ir;
    reg         iris_on;
    reg  [7:0]  hold_f;
    reg  [5:0]  sf;
    reg         ok_q, go_cam_p, go_lens_p;
    reg  [2:0]  slot_q;
    wire        start = ok && (!ok_q || slot != slot_q);
    wire [5:0]  sstep = (sf + 6'd1) >> 1;
    wire [4:0]  amp = (sstep < 6'd5) ? 5'd12 : (sstep < 6'd10) ? 5'd8 : (sstep < 6'd16) ? 5'd4 : 5'd0;
    wire [9:0]  fill_next = fill_x + FILL_STEP;
    // 各段缩放的下一值
    wire [9:0]  za_d = (z - 10'd256) >> 5;
    wire [9:0]  z_asm = (z == 10'd256) ? z : z - ((za_d == 10'd0) ? 10'd1 : za_d);
    wire [9:0]  z_cam0 = z - ((z >> 4) + 10'd1);
    wire [9:0]  z_cam = (z_cam0 < 10'd20 || z_cam0 > z) ? 10'd20 : z_cam0;
    wire [9:0]  z_c20 = z - 10'd20;
    wire [9:0]  z_dol = z - (((z - 10'd256) >> 4) + 10'd1);
    wire [9:0]  z_len = z - ((z >> 4) + 10'd1);


    // ---------------- 时间轴（frame_tick） ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_NONE; f <= 8'd0; z <= 10'd256; ir <= 10'd0; iris_on <= 1'b0;
            hold_f <= 8'd0; sf <= 6'd0; ok_q <= 1'b0; slot_q <= 3'd0; go_cam_p <= 1'b0; go_lens_p <= 1'b0;
            done_tgl <= 1'b0; spin_k <= 7'd0; light <= 4'd8; glint <= -11'sd60;
            shake_dx <= 5'sd0; shake_dy <= 5'sd0; flash_w <= 8'd0; glow_r <= 7'd0;
            charge_on <= 1'b0; fill_x <= FILL_X1; box_w <= 8'd0; click <= 1'b0;
        end else begin
            click <= 1'b0;
            if (go_cam) go_cam_p <= 1'b1;
            if (go_lens) go_lens_p <= 1'b1;
            if (frame_tick) begin
                ok_q <= ok;
                slot_q <= slot;
                go_cam_p <= go_cam;      // 与 tick 同拍到达的请求留到下一帧
                go_lens_p <= go_lens;
                // 圆形展开（第 3 / 4 张经推进进入时）：每帧半径 += r/8 + 3，盖满后关闭
                if (iris_on) begin
                    if (ir >= 10'd540) iris_on <= 1'b0;
                    else ir <= ir + (ir >> 3) + 10'd3;
                end
                if (go_cam_p && ok && slot == 3'd1) begin
                    st <= S_CAM; z <= 10'd256;
                end else if (go_lens_p && ok && slot == 3'd2) begin
                    st <= S_LENS; z <= 10'd256; flash_w <= 8'd0; glow_r <= 7'd0;
                end else if (st == S_CAMHOLD || st == S_LENSHOLD) begin
                    if (ok && slot == ((st == S_CAMHOLD) ? 3'd2 : 3'd3)) begin
                        if (st == S_CAMHOLD) begin st <= S_PAUSE; f <= 8'd0; iris_on <= 1'b1; ir <= 10'd0; end
                        else begin
                            st <= S_CHARGE; f <= 8'd0; charge_on <= 1'b1; fill_x <= FILL_X0; box_w <= 8'd0;
                            iris_on <= 1'b1; ir <= 10'd0;
                        end
                    end else if (hold_f == 8'd150) st <= S_NONE;
                    else hold_f <= hold_f + 8'd1;
                end else if (!ok || start) begin
                    st <= S_NONE; f <= 8'd0; iris_on <= 1'b0;
                    shake_dx <= 5'sd0; shake_dy <= 5'sd0; flash_w <= 8'd0; glow_r <= 7'd0;
                    charge_on <= 1'b0; fill_x <= FILL_X1; box_w <= 8'd0;
                    if (start) begin
                        case (slot)
                            3'd1: begin
                                st <= S_ASM; z <= 10'd540; light <= 4'd2; hold_f <= 8'd0;
                            end
                            3'd2: begin st <= S_DOLLY; z <= 10'd600; end
                            3'd3: begin st <= S_CHARGE; charge_on <= 1'b1; fill_x <= FILL_X0; end
                            3'd4: begin st <= S_SHAKE; sf <= 6'd0; end
                            default: ;
                        endcase
                    end
                end else begin
                    case (st)
                        S_ASM: begin
                            if (f != 8'd255) f <= f + 8'd1;
                            z <= z_asm;
                            light <= (f[7:3] >= 5'd6) ? 4'd8 : {1'b0, f[5:3]} + 4'd2;
                            if (z == 10'd256 && f[7:3] >= 5'd6) begin
                                if (hold_f == 8'd10) begin st <= S_GLINT; glint <= -11'sd60; end
                                else hold_f <= hold_f + 8'd1;
                            end
                        end
                        S_GLINT: begin
                            if (glint > 11'sd300) begin st <= S_SPIN; spin_k <= 7'd0; end
                            else glint <= glint + 11'sd7;
                        end
                        S_SPIN: begin
                            if (spin_k == 7'd119) begin st <= S_BACK; spin_k <= 7'd120; end
                            else spin_k <= spin_k + 7'd1;
                        end
                        S_CAM: begin
                            if (z == 10'd20) begin st <= S_CAMHOLD; hold_f <= 8'd0; done_tgl <= !done_tgl; end
                            else z <= z_cam;
                        end
                        S_DOLLY: begin
                            if (z_dol <= 10'd256) begin z <= 10'd256; st <= S_PAUSE; f <= 8'd0; end
                            else z <= z_dol;
                        end
                        S_PAUSE: begin
                            if (f == 8'd19) begin st <= S_FLASH; f <= 8'd0; glow_r <= 7'd12; click <= 1'b1; end
                            else f <= f + 8'd1;
                        end
                        S_FLASH: begin
                            f <= f + 8'd1;
                            if (f + 8'd1 <= 8'd5) glow_r <= glow_r + 7'd10;
                            else if (f + 8'd1 <= 8'd7) begin glow_r <= 7'd0; flash_w <= 8'd255; end
                            else if (flash_w <= 8'd8) begin flash_w <= 8'd0; st <= S_DONE2; end
                            else flash_w <= flash_w - {3'd0, flash_w[7:3]} - 8'd1;
                        end
                        S_LENS: begin
                            if (z_len <= 10'd48) begin z <= 10'd48; st <= S_LENSHOLD; hold_f <= 8'd0; done_tgl <= !done_tgl; end
                            else z <= z_len;
                        end
                        S_CHARGE: begin
                            if (charge_on) begin
                                if (f != 8'd255) f <= f + 8'd1;
                                if (fill_x < FILL_X1) begin
                                    if (f >= FILL_WAIT) begin
                                        if (fill_next >= FILL_X1) begin fill_x <= FILL_X1; box_w <= 8'd128; end
                                        else fill_x <= fill_next;
                                    end
                                end else if (box_w > 8'd8) box_w <= box_w - 8'd8;
                                else begin box_w <= 8'd0; charge_on <= 1'b0; end
                            end
                        end
                        S_SHAKE: begin
                            if (!shake_hold) begin
                                sf <= sf + 6'd1;
                                if (amp == 5'd0) begin shake_dx <= 5'sd0; shake_dy <= 5'sd0; st <= S_NONE; end
                                else begin
                                    shake_dx <= sstep[0] ? -$signed(amp) : $signed(amp);
                                    shake_dy <= sstep[1] ? $signed(amp) : -$signed(amp);
                                end
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

    // ---------------- 本帧参数：一个 11x11 乘法器分 3 拍复用（p0 / p1 缩放不动点偏移，p7 展开半径平方） ----------------
    wire signed [10:0] dz = 11'sd256 - $signed({1'b0, z});
    wire [10:0] mz = dz[10] ? -dz : dz;
    wire        zoom_cat = st == S_DOLLY || st == S_LENS || st == S_CAM;
    wire [9:0]  zc_x = (st == S_LENS) ? 10'd192 : (st == S_CAM) ? 10'd277 : 10'd250;
    wire [9:0]  zc_y = (st == S_LENS) ? 10'd218 : (st == S_CAM) ? 10'd48 : 10'd175;
    reg  [1:0]  pidx;
    reg         busy, fin, tick_q;
    reg  [10:0] ma, mb;
    reg  [21:0] p0, p1, p7;
    wire [21:0] mprod = ma * mb;
    always @* begin
        case (pidx)
            2'd0:    begin ma = zoom_cat ? {1'b0, zc_y} : 11'd160; mb = mz; end
            2'd1:    begin ma = zoom_cat ? {1'b0, zc_x} : 11'd320; mb = mz; end
            default: begin ma = {1'b0, ir}; mb = {1'b0, ir}; end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_q <= 1'b0; busy <= 1'b0; fin <= 1'b0; pidx <= 2'd0;
            p0 <= 22'd0; p1 <= 22'd0; p7 <= 22'd0;
        end else begin
            tick_q <= frame_tick;
            fin <= 1'b0;
            if (tick_q) begin busy <= 1'b1; pidx <= 2'd0; end
            else if (busy) begin
                case (pidx)
                    2'd0: p0 <= mprod; 2'd1: p1 <= mprod; default: p7 <= mprod;
                endcase
                if (pidx == 2'd2) begin busy <= 1'b0; fin <= 1'b1; end
                else pidx <= pidx + 2'd1;
            end
        end
    end

    // ---------------- 输出（fin 拍一次性更新） ----------------
    wire signed [21:0] sp0 = $signed({1'b0, p0[20:0]});
    wire signed [21:0] sp1 = $signed({1'b0, p1[20:0]});
    wire signed [21:0] n_sp0 = -sp0;
    wire signed [21:0] n_sp1 = -sp1;
    wire        dz_neg = dz[10];
    wire [9:0]  zm48 = z - 10'd48;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= M_OFF; clamp_oor <= 1'b0; band_en <= 1'b0; win_lo <= 9'd0; win_hi <= 9'd479;
            a_bank <= 3'd0; a_acc0 <= 20'sd0; ax0 <= 20'sd0; a_step <= 10'd256;
            circ_on <= 1'b0; circ_iris <= 1'b0; circ_r2 <= 20'd0;
            glint_on <= 1'b0; alpha <= 8'd255; hide <= 1'b0;
        end else if (fin) begin
            mode <= M_OFF; clamp_oor <= 1'b0; band_en <= 1'b0; win_lo <= 9'd0; win_hi <= 9'd479;
            a_bank <= 3'd0; a_acc0 <= 20'sd0; ax0 <= 20'sd0; a_step <= 10'd256;
            circ_on <= 1'b0; circ_iris <= 1'b0; glint_on <= 1'b0; alpha <= 8'd255; hide <= 1'b0;
            if (iris_on) begin
                circ_on <= 1'b1; circ_iris <= 1'b1; circ_r2 <= p7[19:0];
            end
            case (st)
                S_ASM, S_GLINT: begin
                    // 160*(256-gst)、320*(256-gst)，gst >= 256
                    mode <= M_ASM; band_en <= 1'b1; win_lo <= 9'd22; win_hi <= 9'd318; a_bank <= 3'd1; a_step <= z;
                    a_acc0 <= n_sp0[19:0]; ax0 <= n_sp1[19:0];
                    glint_on <= st == S_GLINT;
                end
                S_SPIN, S_BACK: begin mode <= M_SPIN; win_lo <= 9'd22; win_hi <= 9'd318; a_bank <= 3'd1; end
                S_CAM: begin
                    // 背面主摄在素材带内：带内行改读第 1 张素材区、手机列外为 BG
                    mode <= M_ZOOM; band_en <= 1'b1; a_bank <= 3'd1; a_step <= z;
                    a_acc0 <= sp0[19:0]; ax0 <= sp1[19:0]; hide <= 1'b1;
                    alpha <= (z_c20 > 10'd63) ? 8'd255 : {z_c20[5:0], 2'b00};
                end
                S_CAMHOLD: begin alpha <= 8'd0; hide <= 1'b1; end
                S_DOLLY, S_LENS: begin
                    mode <= M_ZOOM; a_bank <= 3'd2; a_step <= z;
                    a_acc0 <= dz_neg ? n_sp0[19:0] : sp0[19:0];
                    ax0 <= dz_neg ? n_sp1[19:0] : sp1[19:0];
                    if (st == S_LENS) begin
                        hide <= 1'b1;
                        alpha <= (zm48 > 10'd63) ? 8'd255 : {zm48[5:0], 2'b00};
                    end
                end
                S_LENSHOLD: begin alpha <= 8'd0; hide <= 1'b1; end
                S_SHAKE: begin
                    if (shake_dx != 5'sd0 || shake_dy != 5'sd0) begin
                        mode <= M_ZOOM; clamp_oor <= 1'b1; a_bank <= 3'd4;
                        a_acc0 <= {{7{shake_dy[4]}}, shake_dy, 8'd0};
                        ax0 <= -{{7{shake_dx[4]}}, shake_dx, 8'd0};
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
