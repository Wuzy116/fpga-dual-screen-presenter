`timescale 1ns/1ps

// 第 13/15 课缩略图模式（控制域）。KEY4 按下进入/退出；进入时焦点 = 当前显示槽。
// 模式内：KEY2 单击（next_event）焦点右移、KEY2 双击（prev_event）焦点左移，均在已完成槽内环绕；
// KEY3 单击（select_event）跳到焦点图并退出，KEY4 再按直接退出、仍显示原图。
// 同拍优先级：thumb_press > select > next > prev。模式内切图/轮播事件全部被本模块吸收（调用方用 thumb_mode 门控），
// 轮播计时暂停，退出后重新计完整周期。播放许可撤销或故障时清除模式。
// jump_req 单拍，jump_slot 有效，且与 thumb_mode 撤销同拍；调用方据此把总览页标志与目标槽整笔替换（按手动转场）。
module media_thumb_mode (
    input  wire       clk,
    input  wire       rst,
    input  wire       active,        // 播放许可且无故障
    input  wire       thumb_press,   // KEY4 消抖后按下沿，单拍
    input  wire       next_event,    // KEY2 单击，单拍
    input  wire       prev_event,    // KEY2 双击，单拍
    input  wire       select_event,  // KEY3 单击，单拍
    input  wire [2:0] display_slot,
    input  wire [2:0] slot_count,
    output reg        thumb_mode,
    output reg  [2:0] focus,
    output reg        jump_req,
    output reg  [2:0] jump_slot
);
    wire [2:0] last_slot = (slot_count >= 3'd1 && slot_count <= 3'd5) ? slot_count - 3'd1 : 3'd4;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            thumb_mode <= 1'b0;
            focus <= 3'd0;
            jump_req <= 1'b0;
            jump_slot <= 3'd0;
        end else begin
            jump_req <= 1'b0;
            if (!active) begin
                thumb_mode <= 1'b0;
            end else if (!thumb_mode) begin
                if (thumb_press) begin
                    thumb_mode <= 1'b1;
                    focus <= display_slot;
                end
            end else if (thumb_press) begin
                thumb_mode <= 1'b0;
            end else if (select_event) begin
                thumb_mode <= 1'b0;
                jump_req <= 1'b1;
                jump_slot <= focus;
            end else if (next_event) begin
                focus <= (focus >= last_slot) ? 3'd0 : focus + 3'd1;
            end else if (prev_event) begin
                focus <= (focus == 3'd0 || focus > last_slot) ? last_slot : focus - 3'd1;
            end
        end
    end
endmodule
