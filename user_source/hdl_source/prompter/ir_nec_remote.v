// 红外遥控（控制域）：VS1838B 输出（空闲高、载波期间低）→ NEC 解码 → 按键事件（每位单拍）。
// 帧 = 9 ms 低 + 4.5 ms 高 + 32 位（每位 0.56 ms 低 + 0.56 / 1.69 ms 高）+ 结束低脉冲；按住时约每 108 ms 一个
// 重复码（9 ms 低 + 2.25 ms 高）。32 位按收到顺序从高位移入（与常见 Arduino 库打印值一致，如按键 1 = 00FFA25D），
// 只接受地址 00FF 且命令字节与反码相符的帧，其余遥控器或误码丢弃。
// 时长按 10 µs 节拍计数、各类 ±约 25% 容差；输入两级同步后连续 2 个节拍相同才认为电平变化（滤掉 < 20 µs 毛刺）。
// 按住判定：最近 HOLD_MS 内收到过帧或重复码；按住期间同一键的整帧也算重复（兼容不发重复码的遥控器）。
// 事件 events：
//   [0] 上  [1] 下  [2] 左  [3] 右  [4] *        —— 只在按下时发一次
//   [8:5]  1/2/3/4 = 周期/音量/亮度/对比度 加；[12:9] 5/6/7/8 = 同四项 减 —— 按下发一次，按住约 0.5 s 后每 2 个重复码再发一次
//   [13] OK 按住约 1 s（第 9 个重复码）发一次（保存参数），短按不发
//   [14] 9 只在按下时发一次（D32：开关“声音控制讲稿滚动”）
// rx_pulse：每收到一个有效帧或重复码单拍（板测指示灯用）。
module ir_nec_remote #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer HOLD_MS = 150
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ir_in,
    output reg  [14:0] events,
    output reg         rx_pulse
);
    localparam integer TICK_DIV = CLK_HZ / 100_000;              // 10 µs
    localparam integer TW = (TICK_DIV <= 2) ? 1 : $clog2(TICK_DIV);
    localparam integer HOLD_T = HOLD_MS * 100;                   // 节拍数
    localparam integer HW = $clog2(HOLD_T + 1);
    // 时长窗口（节拍）
    localparam [11:0] LEAD_LO = 12'd700, LEAD_HI = 12'd1100;     // 9 ms
    localparam [11:0] SP_HDR_LO = 12'd350, SP_HDR_HI = 12'd560;  // 4.5 ms
    localparam [11:0] SP_REP_LO = 12'd170, SP_REP_HI = 12'd290;  // 2.25 ms
    localparam [11:0] BIT_LO = 12'd35, BIT_HI = 12'd85;          // 0.56 ms
    localparam [11:0] ONE_LO = 12'd130, ONE_HI = 12'd220;        // 1.69 ms

    // ---- 采样与滤波 ----
    (* ASYNC_REG="TRUE" *) reg s1, s2;
    reg [TW-1:0] div;
    wire tick = (div == TICK_DIV - 1);
    reg  cand, lvl;                     // lvl：滤波后电平（1 = 空闲 / 间隔）
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1 <= 1'b1; s2 <= 1'b1; div <= 0; cand <= 1'b1; lvl <= 1'b1;
        end else begin
            s1 <= ir_in; s2 <= s1;
            div <= tick ? {TW{1'b0}} : div + 1'b1;
            if (tick) begin
                cand <= s2;
                if (s2 == cand) lvl <= cand;
            end
        end
    end

    // ---- 段长测量与帧解码 ----
    reg [11:0] cnt;                     // 当前电平已持续的节拍数（饱和）
    reg [11:0] mark;                    // 上一个低段长度
    reg        in_frame;
    reg [5:0]  nbits;
    reg [31:0] data;
    reg        lvl_q;
    reg        frame_ok, rep_ok;        // 单拍：本拍收到有效帧 / 重复码
    wire       mark_lead = mark >= LEAD_LO && mark <= LEAD_HI;
    wire       mark_bit  = mark >= BIT_LO && mark <= BIT_HI;
    wire       fall = lvl_q && !lvl;    // 间隔结束（新的低段开始）
    wire       rise = !lvl_q && lvl;    // 低段结束
    wire       sp_hdr = cnt >= SP_HDR_LO && cnt <= SP_HDR_HI;
    wire       sp_rep = cnt >= SP_REP_LO && cnt <= SP_REP_HI;
    wire       sp_zero = cnt >= BIT_LO && cnt <= BIT_HI;
    wire       sp_one = cnt >= ONE_LO && cnt <= ONE_HI;
    wire [31:0] data_n = {data[30:0], sp_one};
    wire       valid32 = data_n[31:24] == 8'h00 && data_n[23:16] == 8'hff && data_n[15:8] == ~data_n[7:0];
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt <= 12'd0; mark <= 12'd0; in_frame <= 1'b0; nbits <= 6'd0; data <= 32'd0; lvl_q <= 1'b1;
            frame_ok <= 1'b0; rep_ok <= 1'b0;
        end else begin
            frame_ok <= 1'b0;
            rep_ok <= 1'b0;
            lvl_q <= lvl;
            if (rise || fall) cnt <= 12'd0;
            else if (tick && cnt != 12'hfff) cnt <= cnt + 12'd1;
            if (rise) mark <= cnt;
            if (fall) begin
                // 一个“低 + 高”对结束：按低段 mark 与高段 cnt 分类
                if (mark_lead && sp_hdr) begin
                    in_frame <= 1'b1; nbits <= 6'd0; data <= 32'd0;
                end else if (mark_lead && sp_rep) begin
                    in_frame <= 1'b0; rep_ok <= 1'b1;
                end else if (in_frame && mark_bit && (sp_zero || sp_one)) begin
                    data <= data_n;
                    nbits <= nbits + 6'd1;
                    if (nbits == 6'd31) begin
                        in_frame <= 1'b0;
                        frame_ok <= valid32;
                    end
                end else
                    in_frame <= 1'b0;
            end
            // 长时间空闲（> 40 ms）丢弃未完成的帧
            if (lvl && cnt == 12'hfff) in_frame <= 1'b0;
        end
    end

    // ---- 按键码 → 编号 ----
    function [4:0] key_of(input [7:0] c);
        case (c)
            8'h18: key_of = 5'd1;    // 上
            8'h4a: key_of = 5'd2;    // 下
            8'h10: key_of = 5'd3;    // 左
            8'h5a: key_of = 5'd4;    // 右
            8'h68: key_of = 5'd5;    // *
            8'ha2: key_of = 5'd6;    // 1
            8'h62: key_of = 5'd7;    // 2
            8'he2: key_of = 5'd8;    // 3
            8'h22: key_of = 5'd9;    // 4
            8'h02: key_of = 5'd10;   // 5
            8'hc2: key_of = 5'd11;   // 6
            8'he0: key_of = 5'd12;   // 7
            8'ha8: key_of = 5'd13;   // 8
            8'h38: key_of = 5'd14;   // OK
            8'h90: key_of = 5'd15;   // 9
            default: key_of = 5'd0;  // 0 / # 及其它
        endcase
    endfunction

    // ---- 按住跟踪与事件 ----
    reg [HW-1:0] hold;
    reg [4:0]    key;                   // 当前按住的键（0 = 无）
    reg [3:0]    reps;                  // 本次按住收到的重复次数（饱和 15）
    reg          alt;                   // 每个重复码翻转：连续调节每 2 个重复码一步
    wire         held = hold != 0;
    wire [4:0]   fkey = key_of(data[15:8]);
    wire         new_press = frame_ok && (!held || fkey != key);
    wire         again = rep_ok && held || frame_ok && held && fkey == key;
    wire [3:0]   reps_n = (reps == 4'hf) ? reps : reps + 4'd1;
    function [14:0] onehot(input [4:0] k);
        onehot = (k == 5'd0) ? 15'd0 : (15'd1 << (k - 5'd1));
    endfunction
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hold <= 0; key <= 5'd0; reps <= 4'd0; alt <= 1'b0; events <= 15'd0; rx_pulse <= 1'b0;
        end else begin
            events <= 15'd0;
            rx_pulse <= frame_ok || rep_ok;
            if (frame_ok || (rep_ok && held))
                hold <= HOLD_T;
            else if (tick && held)
                hold <= hold - 1'b1;
            if (tick && hold == 1)
                key <= 5'd0;
            if (new_press) begin
                key <= fkey;
                reps <= 4'd0;
                alt <= 1'b0;
                // OK 只在按住约 1 s 时保存
                events <= (fkey == 5'd14) ? 15'd0 : onehot(fkey);
            end else if (again) begin
                reps <= reps_n;
                alt <= !alt;
                if (key >= 5'd6 && key <= 5'd13 && reps_n >= 4'd4 && alt)
                    events <= onehot(key);
                if (key == 5'd14 && reps_n == 4'd9)
                    events <= onehot(5'd14);
            end
        end
    end
    // synthesis translate_off
    initial if (CLK_HZ < 200_000 || CLK_HZ % 100_000 != 0 || HOLD_MS < 120 || HOLD_MS > 500) begin
        $display("MEDIA_CONFIG_ERROR %m: CLK_HZ must be a multiple of 100 kHz, HOLD_MS 120..500");
        $finish;
    end
    // synthesis translate_on
endmodule
