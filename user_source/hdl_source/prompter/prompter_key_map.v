// 提词命令（D18，控制域）：上游 media_key_mode_map 已按拨码选出提词按键事件，这里把它们变成命令翻转位（cmd_toggle），
// 供上层经邮箱整笔送往像素域，像素域按位比较得到单拍命令。
// 位序：{overview, key3, 0, 0, prev, next}。key3 = KEY3 单击（像素域：选页中为确定，否则为连续滚动开关）；
// overview = KEY4 短按（进/出选页）。prompter_mode=0 时不翻转任何位。
module prompter_key_map (
    input  wire       clk,
    input  wire       rst,
    input  wire       prompter_mode,
    input  wire       next,
    input  wire       prev,
    input  wire       key3,
    input  wire       overview,
    output reg  [5:0] cmd_toggle
);
    always @(posedge clk or posedge rst) begin
        if (rst) cmd_toggle <= 6'd0;
        else if (prompter_mode) cmd_toggle <= cmd_toggle ^ {overview, key3, 2'b00, prev, next};
    end
endmodule
