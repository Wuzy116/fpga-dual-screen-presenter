`timescale 1ns/1ps

// 由 user_source/hdl_source/python/qr_to_rom.py 生成，勿手改。
// 内容：https://www.baidu.com（版本 2-M，掩码 6）；bits[24] 为最左一列，1 = 深色模块。
module qr_rom (
    input  wire [4:0]  row,
    output reg  [24:0] bits
);
    always @* begin
        case (row)
            5'd0: bits = 25'h1fda57f;
            5'd1: bits = 25'h1055141;
            5'd2: bits = 25'h1754a5d;
            5'd3: bits = 25'h174085d;
            5'd4: bits = 25'h175f55d;
            5'd5: bits = 25'h1049941;
            5'd6: bits = 25'h1fd557f;
            5'd7: bits = 25'h0007900;
            5'd8: bits = 25'h13fc797;
            5'd9: bits = 25'h0631ebe;
            5'd10: bits = 25'h0f7ab69;
            5'd11: bits = 25'h0c0952f;
            5'd12: bits = 25'h1cef141;
            5'd13: bits = 25'h1004792;
            5'd14: bits = 25'h1fdbedf;
            5'd15: bits = 25'h16861ad;
            5'd16: bits = 25'h16507f6;
            5'd17: bits = 25'h001b916;
            5'd18: bits = 25'h1fda151;
            5'd19: bits = 25'h1059713;
            5'd20: bits = 25'h1751ff3;
            5'd21: bits = 25'h175c443;
            5'd22: bits = 25'h174169f;
            5'd23: bits = 25'h104c437;
            5'd24: bits = 25'h1fd0d89;
            default: bits = 25'h0000000;
        endcase
    end
endmodule
