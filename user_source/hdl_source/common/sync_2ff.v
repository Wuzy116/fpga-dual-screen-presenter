// 仅用于目的域可采到的慢变单比特电平，不用于脉冲或多位数据总线。
// rst_n 使用目的时钟域已经同步释放的复位。
module sync_2ff #(
    parameter RESET_VAL = 1'b0
)(
    input wire clk,
    input wire rst_n,
    input wire async_in,
    output wire sync_out
);
(* ASYNC_REG="TRUE" *) reg s1, s2;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s1 <= RESET_VAL;
        s2 <= RESET_VAL;
    end else begin
        s1 <= async_in;
        s2 <= s1;
    end
end
assign sync_out = s2;
endmodule
