// 控制域按键映射（D18）：KEY2/KEY3 手势按拨码分到三种用途，同一时刻只有一种生效。
// param_mode=1（SW1 拨上）：KEY2 单击/长按重复 = 加，KEY3 = 减；双击算两次（第二次晚一拍发出）；
//   KEY2+KEY3 同按（短按或长按）= 保存请求。增减同拍抵消。
// 否则 prompter_mode=1（SW4 拨下）：事件转给提词命令（pm_next/pm_prev/pm_key3），观众屏不响应。
// 否则（控制观众屏）：KEY2 单击 = 下一张，双击 = 上一张；KEY3 单击 = 自动播放开关（缩略图内为确定）。
// 两种非参数模式下长按不响应；KEY2+KEY3 同按短按 = 观众屏黑场开/关（D21，两种模式都有效）。events_ready=0 时全部屏蔽。
module media_key_mode_map (
    input  wire clk,
    input  wire rst,
    input  wire events_ready,
    input  wire param_mode,
    input  wire prompter_mode,
    input  wire key2_click, key2_double, key2_long,
    input  wire key3_click, key3_double, key3_long,
    input  wire chord_click, chord_save,
    output wire increase_event,
    output wire decrease_event,
    output wire save_request,
    output wire next_event,
    output wire prev_event,
    output wire auto_toggle_event,
    output wire pm_next,
    output wire pm_prev,
    output wire pm_key3,
    output wire blackout_toggle
);
    wire active = !rst && events_ready;
    wire adjust = active && param_mode;
    wire view   = active && !param_mode;
    reg  inc_again, dec_again;
    always @(posedge clk or posedge rst) begin
        if (rst) begin inc_again <= 1'b0; dec_again <= 1'b0; end
        else begin
            inc_again <= adjust && key2_double;
            dec_again <= adjust && key3_double;
        end
    end
    wire inc = adjust && (key2_click || key2_double || key2_long || inc_again);
    wire dec = adjust && (key3_click || key3_double || key3_long || dec_again);
    assign increase_event = inc && !dec;
    assign decrease_event = dec && !inc;
    assign save_request = adjust && (chord_click || chord_save);
    assign next_event = view && !prompter_mode && key2_click;
    assign prev_event = view && !prompter_mode && key2_double;
    assign auto_toggle_event = view && !prompter_mode && key3_click;
    assign pm_next = view && prompter_mode && key2_click;
    assign pm_prev = view && prompter_mode && key2_double;
    assign pm_key3 = view && prompter_mode && key3_click;
    assign blackout_toggle = view && chord_click;
endmodule
