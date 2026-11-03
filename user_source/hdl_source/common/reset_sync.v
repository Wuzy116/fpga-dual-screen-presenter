// 每个时钟域单独实例化：异步置位复位、两级同步释放。
// 只整形复位释放沿，不产生 POR 延时；ext_rst_n 必须由外部复位/PLL LOCK 驱动。
module reset_sync (
    input wire clk,
    input wire ext_rst_n,
    output wire rst_n_sync
);
(* ASYNC_REG="TRUE" *) reg s1, s2;
always @(posedge clk or negedge ext_rst_n) begin
    if (!ext_rst_n) begin
        s1 <= 1'b0;
        s2 <= 1'b0;
    end else begin
        s1 <= 1'b1;
        s2 <= s1;
    end
end
assign rst_n_sync = s2;
endmodule
