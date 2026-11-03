`timescale 1ns/1ps

// 观众屏黑场与价格揭晓（D21，控制域）。
// chord（KEY2+KEY3 同按）翻转黑场。卡上有 5 张图、目标槽为 3（第 4 张）且不在缩略图时，KEY2 单击（next_in）分两步：
//   第一次：不换图，只进入黑场；第二次（黑场中）：放行下一张，等实际显示槽变成 4（第 5 张，转场完成）后撤销黑场淡入。
// 等待揭晓期间再按任何切图键（next/prev）或同按：立即撤销黑场，按键照常生效。
// revealed：第 5 张显示、黑场撤销的那一拍单拍（D23 提示音）。
// D32（ENABLE_FX_GATE=1）：5 张图、不在缩略图且未黑场时，目标槽为 1（第 2 张）或 2（第 3 张）的“下一张”先不放行，
//   翻转 fx_go_cam / fx_go_lens 让像素域播放推进镜头的转场；像素域转场推到底后翻转 fx_done（两级同步到本域），
//   这时才放行一拍 next_out 真正换图。等待期间切图键全部吞掉；FX_TIMEOUT 个时钟内没有 fx_done 则放弃（不换图）。
module media_reveal #(
    parameter integer ENABLE_FX_GATE = 0,
    parameter integer FX_TIMEOUT = 100_000_000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       next_in,        // 观众屏 KEY2 单击（单拍）
    input  wire       prev_in,        // 观众屏 KEY2 双击（单拍）
    input  wire       chord_toggle,   // 同按（单拍）
    input  wire       thumb_mode,
    input  wire [2:0] desired_slot,
    input  wire [2:0] slot_count,
    input  wire       display_valid,
    input  wire [2:0] display_slot,
    input  wire       fx_done,        // 像素域翻转位（异步）
    output wire       next_out,
    output reg        blackout,
    output reg        revealed,
    output reg        fx_go_cam,      // 翻转位
    output reg        fx_go_lens
);
    reg  pend;
    wire at_gate = !thumb_mode && slot_count == 3'd5 && desired_slot == 3'd3;
    // ---- D32 推进镜头转场门 ----
    localparam integer TW = $clog2(FX_TIMEOUT + 1);
    (* ASYNC_REG="TRUE" *) reg done_s1, done_s2;
    reg  done_s3, fx_pend, fx_release;
    reg  [TW-1:0] fx_timer;
    wire fx_gate = ENABLE_FX_GATE && !thumb_mode && !blackout && slot_count == 3'd5 &&
                   (desired_slot == 3'd1 || desired_slot == 3'd2);
    wire fx_take = ENABLE_FX_GATE && next_in && fx_gate && !fx_pend;
    wire fx_eat  = ENABLE_FX_GATE && fx_pend && (next_in || prev_in);
    wire next_eff = next_in && !fx_eat && !fx_take;
    wire prev_eff = prev_in && !fx_eat;
    wire swallow = next_eff && at_gate && !blackout && !pend;
    assign next_out = (next_eff && !swallow) || fx_release;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            done_s1 <= 1'b0; done_s2 <= 1'b0; done_s3 <= 1'b0;
            fx_pend <= 1'b0; fx_release <= 1'b0; fx_timer <= {TW{1'b0}};
            fx_go_cam <= 1'b0; fx_go_lens <= 1'b0;
        end else if (ENABLE_FX_GATE) begin
            done_s1 <= fx_done; done_s2 <= done_s1; done_s3 <= done_s2;
            fx_release <= 1'b0;
            if (fx_take) begin
                fx_pend <= 1'b1; fx_timer <= {TW{1'b0}};
                if (desired_slot == 3'd1) fx_go_cam <= !fx_go_cam; else fx_go_lens <= !fx_go_lens;
            end else if (fx_pend) begin
                if (done_s2 != done_s3) begin fx_pend <= 1'b0; fx_release <= 1'b1; end
                else if (fx_timer == FX_TIMEOUT[TW-1:0]) fx_pend <= 1'b0;
                else fx_timer <= fx_timer + 1'b1;
            end
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            blackout <= 1'b0; pend <= 1'b0; revealed <= 1'b0;
        end else if (chord_toggle) begin
            revealed <= 1'b0;
            blackout <= !blackout; pend <= 1'b0;
        end else if (next_eff || prev_eff) begin
            revealed <= 1'b0;
            if (pend) begin blackout <= 1'b0; pend <= 1'b0; end
            else if (swallow) blackout <= 1'b1;
            else if (next_eff && at_gate && blackout) pend <= 1'b1;
        end else if (pend && display_valid && display_slot == 3'd4) begin
            blackout <= 1'b0; pend <= 1'b0; revealed <= 1'b1;
        end else begin
            revealed <= 1'b0;
        end
    end
endmodule
