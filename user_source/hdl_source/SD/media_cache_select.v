// 预加载缓存（D19：最多 5 槽）的控制域选槽；所有接口属于 clk 域，由可选预加载顶层使用。
// rst 须由控制域复位同步器释放，并与下游 CDC 使用同一统一复位源。
// 首次 player_enable 提交槽 0，同拍 step 忽略；此前的 step 不缓存。
// step_req 为单拍事件，step_prev=1 上一槽，否则下一槽；按最新目标累计并在前 slot_count 槽内环绕。
// 一个稳定的待受理槽 + 一个合并的目标：src_valid && !src_ready 时不改 src_slot。
// 每拍 step 均改变 desired_slot，但中间目标不逐个排队显示；目标相同不重复提交。
// src_valid && src_ready 只表示邮箱受理，不表示送达、reader 采用或画面提交。
// 许可撤销立即屏蔽 valid，并在 clk 采到后锁停至复位；不是普通暂停/恢复接口。
// step_manual 标记本拍 step 来自按键（否则为轮播）；src_manual 随 src_slot 一起发布，
// 表示该目标最近一次由谁产生，供像素域选择转场方式（手动淡入淡出 / 轮播 Wipe）。
// 已被 CDC 受理的槽不能在此撤回，外层必须同时关闭 reader；统一复位取消在途邮箱。
// ENABLE_JUMP=1：jump_req 单拍把目标直接设为 jump_slot（越界钳到末槽，按手动转场），优先于同拍 step。
// ENABLE_SHEET=1：sheet 电平（缩略图模式）与目标槽整笔发布为 {src_sheet, src_slot}；sheet 变化按手动转场，
// 与同拍 jump 合并为一次发布（确认时“退出总览页 + 跳到焦点图”不经过中间目标）。
module media_cache_select #(parameter ENABLE_JUMP = 0, parameter ENABLE_SHEET = 0) (
    input wire clk, rst,
    input wire player_enable,
    input wire step_req, step_prev, step_manual,
    // 可选的槽数 1..5；首张即显示时随后台加载单调增长（desired_slot 始终小于它）；越界按 5 处理。
    input wire [2:0] slot_count,
    input wire jump_req,
    input wire [2:0] jump_slot,
    input wire sheet,
    output reg [2:0] desired_slot,
    output reg [2:0] src_slot,
    output reg src_manual,
    output reg src_sheet,
    output wire src_valid,
    input wire src_ready,
    output wire stopped
);
localparam WAIT_ENABLE=2'd0, RUN=2'd1, STOPPED=2'd2;
reg [1:0] state;
reg pending;
reg desired_manual;
reg desired_sheet;
wire jump = ENABLE_JUMP && jump_req;
wire sheet_now = ENABLE_SHEET && sheet;
wire next_manual = (jump || sheet_now != desired_sheet) ? 1'b1 : step_req ? step_manual : desired_manual;
wire [2:0] last_slot = (slot_count >= 3'd1 && slot_count <= 3'd5) ? slot_count - 3'd1 : 3'd4;
wire [2:0] next_target = jump ? ((jump_slot > last_slot) ? last_slot : jump_slot) :
                         !step_req ? desired_slot :
                         step_prev ? ((desired_slot == 3'd0) ? last_slot : desired_slot - 3'd1) :
                                     ((desired_slot >= last_slot) ? 3'd0 : desired_slot + 3'd1);
wire publish = {sheet_now, next_target} != {src_sheet, src_slot};
assign src_valid = !rst && player_enable && state == RUN && pending;
assign stopped = state == STOPPED;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= WAIT_ENABLE;
        pending <= 1'b0;
        desired_slot <= 3'd0;
        src_slot <= 3'd0;
        desired_manual <= 1'b1;
        src_manual <= 1'b1;
        desired_sheet <= 1'b0;
        src_sheet <= 1'b0;
    end else begin
        case (state)
            WAIT_ENABLE: if (player_enable) begin
                state <= RUN;
                pending <= 1'b1;
                desired_slot <= 3'd0;
                src_slot <= 3'd0;
                desired_manual <= 1'b1;
                src_manual <= 1'b1;
                desired_sheet <= 1'b0;
                src_sheet <= 1'b0;
            end
            RUN: if (!player_enable) begin
                state <= STOPPED;
                pending <= 1'b0;
                desired_slot <= 3'd0;
                src_slot <= 3'd0;
                desired_sheet <= 1'b0;
                src_sheet <= 1'b0;
            end else begin
                desired_slot <= next_target;
                desired_manual <= next_manual;
                desired_sheet <= sheet_now;
                // 空闲或旧槽本拍受理后，才可发布最新目标；同拍新事件不能丢失。
                if (!pending || src_ready) begin
                    pending <= publish;
                    if (publish) begin
                        src_slot <= next_target;
                        src_sheet <= sheet_now;
                        src_manual <= next_manual;
                    end
                end
            end
            default: begin
                state <= STOPPED;
                pending <= 1'b0;
            end
        endcase
    end
end
endmodule
