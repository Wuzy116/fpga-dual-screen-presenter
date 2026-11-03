// 槽位 0 对应新第 1 位，低 8 位保存槽位 0；位选与段码成对传给扫描器。
module seg_page_render #(
    parameter ENABLE_PARAMETER_HINT = 0,
    parameter ENABLE_DIAG_PAGE = 0,
    // D18：PIC 页第 1~2 位显示时期 S1 预备 / S2 演讲（stage = 0 / 1）
    parameter ENABLE_STAGE = 0
)(
    input wire [1:0] page_id,
    input wire [2:0] img_idx,
    input wire display_valid,
    input wire load_busy,
    // 周期已由 seg_period_seconds 换算：valid=0～99 整数秒，bcd={十位, 个位}。
    input wire period_valid,
    input wire [7:0] period_bcd,
    output wire [63:0] slot_sel,
    output wire [63:0] slot_seg,
    input wire parameter_hint_ready,
    input wire parameter_selected_volume,
    // 诊断页 8 位十六进制，低 4 位对应第 1 位；仅 ENABLE_DIAG_PAGE 时显示。
    input wire [31:0] diag_digits,
    // 控制域运行音量 0～255，第三页显示为 A 百 十 个。
    input wire [7:0] volume,
    input wire [1:0] stage,
    // A-8：启动 / 后台加载首因阶段 1..6（0 = 无故障），PIC 页第 3~4 位显示 E 与阶段号
    input wire [2:0] fault
);
// synthesis translate_off
initial begin
    if (ENABLE_PARAMETER_HINT != 0 && ENABLE_PARAMETER_HINT != 1) begin
        $display("MEDIA_CONFIG_ERROR seg_page_render %m: hint enable must be 0 or 1");
        $finish;
    end
end
// synthesis translate_on
localparam [1:0] PAGE_PIC = 2'd0, PAGE_PRD = 2'd1, PAGE_VOLUME = 2'd2, PAGE_DIAG = 2'd3;
// 0～15 保留原十六进制字符编码，扩展字符编码见 seg_decoder。
localparam [4:0] CHAR_P = 5'd16, CHAR_I = 5'd17, CHAR_R = 5'd18,
                 CHAR_S = 5'd19, CHAR_BLANK = 5'd20, CHAR_DASH = 5'd21;
reg [4:0] chars [0:7];
reg [7:0] dp_on;
reg [7:0] digit_enable;
integer i;
wire [3:0] pic_number = (!display_valid || load_busy) ? 4'd0 :
                       ({1'b0, img_idx} + 4'd1);

// 8 位二进制转三位 BCD（移位加 3），纯组合、无除法器。
function [11:0] volume_bcd;
    input [7:0] bin;
    integer k;
    reg [19:0] s;
    begin
        s = {12'd0, bin};
        for (k = 0; k < 8; k = k + 1) begin
            if (s[11:8]  >= 4'd5) s[11:8]  = s[11:8]  + 4'd3;
            if (s[15:12] >= 4'd5) s[15:12] = s[15:12] + 4'd3;
            if (s[19:16] >= 4'd5) s[19:16] = s[19:16] + 4'd3;
            s = s << 1;
        end
        volume_bcd = s[19:8];
    end
endfunction
wire [11:0] volume_digits = volume_bcd(volume);

always @(*) begin
    for (i = 0; i < 8; i = i + 1)
        chars[i] = CHAR_BLANK;
    dp_on = 8'h00;
    digit_enable = 8'hff;
    case (page_id)
        PAGE_PIC: begin
            chars[4] = CHAR_P;
            chars[5] = CHAR_I;
            chars[6] = 5'h0c;
            chars[7] = {1'b0, pic_number};
            if (ENABLE_STAGE) begin
                chars[0] = CHAR_S;
                chars[1] = {3'b000, stage} + 5'd1;
            end
            if (fault != 3'd0) begin
                chars[2] = 5'd14;
                chars[3] = {2'b00, fault};
            end
        end
        PAGE_PRD: begin
            chars[0] = CHAR_P;
            chars[1] = CHAR_R;
            chars[2] = 5'h0d;
            chars[7] = CHAR_S;
            // 超过 99 秒或含小数秒时显示 --，不能伪装成截断后的周期。
            chars[5] = period_valid ? {1'b0, period_bcd[7:4]} : CHAR_DASH;
            chars[6] = period_valid ? {1'b0, period_bcd[3:0]} : CHAR_DASH;
        end
        // 空 空 空 提示 A 百 十 个：A000 静音，A255 最大。
        PAGE_VOLUME: begin
            chars[4] = 5'h0a;
            chars[5] = {1'b0, volume_digits[11:8]};
            chars[6] = {1'b0, volume_digits[7:4]};
            chars[7] = {1'b0, volume_digits[3:0]};
        end
        // 全部小数点点亮，与其他页面区分。
        PAGE_DIAG: if (ENABLE_DIAG_PAGE) begin
            for (i = 0; i < 8; i = i + 1)
                chars[i] = {1'b0, diag_digits[i*4 +: 4]};
            dp_on = 8'hff;
        end else digit_enable = 8'h00;
        default: digit_enable = 8'h00;
    endcase
    // Read-only target hint: slot 3 is blank on PIC/PRD/VOLUME.
    // P. = period, A. = audio volume. Keep illegal pages fully blank.
    // Inputs are synchronous to the panel clock; seg_scan snapshots a whole frame.
    if (ENABLE_PARAMETER_HINT && parameter_hint_ready && page_id != 2'd3) begin
        chars[3] = parameter_selected_volume ? 5'd10 : CHAR_P;
        dp_on[3] = 1'b1;
    end
end

genvar k;
generate
    for (k = 0; k < 8; k = k + 1) begin : g_digit
        wire [6:0] decoded;
        seg_decoder u_decoder (.bin_data(chars[k]), .seg_data(decoded));
        assign slot_sel[k*8 +: 8] = digit_enable[k] ? ~(8'b1 << k) : 8'hff;
        assign slot_seg[k*8 +: 8] = {~dp_on[k], decoded};
    end
endgenerate
endmodule
