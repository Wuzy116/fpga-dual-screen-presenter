// 提词屏选页（D20，像素域）：全部讲稿共用一张总览页（卡上 S1P00.BMP，G x G 格（D21：G 由页数决定），第 k 页在第 k 格）。
// nav_active=1（提词模式且讲稿已装）时：
//   cmd_open（KEY4）：窗口直接跳到总览槽，焦点 = 当前页；没有总览页或没有讲稿页时不响应。再按 cmd_open = 取消，跳回原页。
//   选页中 cmd_next / cmd_prev（KEY2 单击 / 双击）：焦点后移 / 前移一页，首末页之间环绕。
//   cmd_confirm（KEY3）：窗口跳到所选页并退出选页。选页中 nav_active 撤销（拨回 SW4）时退出，恢复后先跳回原页。
// 观众屏不受选页影响。selecting=1 时上层屏蔽 prompter_nav 的翻页/滚动。焦点框由读取器按 focus_cell 画。
module prompter_select (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        nav_active,
    input  wire [5:0]  ov_slot,         // 总览页槽
    input  wire        ov_valid,
    input  wire [5:0]  pages,           // 讲稿页数（不含总览）
    input  wire        cmd_open,
    input  wire        cmd_next,
    input  wire        cmd_prev,
    input  wire        cmd_confirm,
    input  wire [5:0]  page_slot,       // 当前（选页前）窗口所在页
    input  wire        sliding,
    output wire        selecting,
    output reg         jump,
    output reg  [5:0]  jump_slot,
    output wire [4:0]  focus_cell,
    output wire        box_on
);
    localparam integer CELLS = 25;
    reg        sel, restore;
    reg [4:0]  focus;
    reg [5:0]  home_slot;
    // 总览只有 25 格：焦点范围 0..last
    wire [5:0] last = ((pages > CELLS) ? CELLS[5:0] : pages) - 6'd1;
    assign selecting = sel || jump;
    assign focus_cell = focus;
    assign box_on = sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel <= 1'b0; restore <= 1'b0; focus <= 5'd0; home_slot <= 6'd0; jump <= 1'b0; jump_slot <= 6'd0;
        end else begin
            jump <= 1'b0;
            if (!nav_active) begin
                if (sel) restore <= 1'b1;
                sel <= 1'b0;
            end else if (!sel) begin
                if (restore) begin
                    // 选页中途离开提词模式：恢复时窗口还停在总览页，先跳回原页
                    restore <= 1'b0; jump <= 1'b1; jump_slot <= home_slot;
                end else if (cmd_open && !sliding && !jump && ov_valid && pages != 6'd0) begin
                    sel <= 1'b1; home_slot <= page_slot;
                    focus <= (page_slot <= last) ? page_slot[4:0] : 5'd0;
                    jump <= 1'b1; jump_slot <= ov_slot;
                end
            end else if (cmd_open) begin
                sel <= 1'b0; jump <= 1'b1; jump_slot <= home_slot;
            end else if (cmd_confirm) begin
                sel <= 1'b0; jump <= 1'b1; jump_slot <= {1'b0, focus};
            end else if (cmd_next) begin
                focus <= ({1'b0, focus} >= last) ? 5'd0 : focus + 5'd1;
            end else if (cmd_prev) begin
                focus <= (focus == 5'd0) ? last[4:0] : focus - 5'd1;
            end
        end
    end
endmodule
