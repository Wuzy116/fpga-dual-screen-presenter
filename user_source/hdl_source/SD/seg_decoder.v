// 0～15：原十六进制字符；16=P，17=I，18=r，19=S，20=空白，21=横线。
// 输出低有效，顺序为 {g,f,e,d,c,b,a}，小数点由页面层单独组合。
module seg_decoder (
    input wire [4:0] bin_data,
    output reg [6:0] seg_data
);
always @(*) begin
    case (bin_data)
        5'd0:  seg_data = 7'b100_0000;
        5'd1:  seg_data = 7'b111_1001;
        5'd2:  seg_data = 7'b010_0100;
        5'd3:  seg_data = 7'b011_0000;
        5'd4:  seg_data = 7'b001_1001;
        5'd5:  seg_data = 7'b001_0010;
        5'd6:  seg_data = 7'b000_0010;
        5'd7:  seg_data = 7'b111_1000;
        5'd8:  seg_data = 7'b000_0000;
        5'd9:  seg_data = 7'b001_0000;
        5'd10: seg_data = 7'b000_1000;
        5'd11: seg_data = 7'b000_0011;
        5'd12: seg_data = 7'b100_0110;
        5'd13: seg_data = 7'b010_0001;
        5'd14: seg_data = 7'b000_0110;
        5'd15: seg_data = 7'b000_1110;
        5'd16: seg_data = 7'b000_1100;
        5'd17: seg_data = 7'b111_1001;
        5'd18: seg_data = 7'b010_1111;
        5'd19: seg_data = 7'b001_0010;
        5'd21: seg_data = 7'b011_1111;
        default: seg_data = 7'b111_1111;
    endcase
end
endmodule
