// HDMI 1.4a 5.4: control/TMDS video/TERC4 and 5.2 guard bands.
// Conventional symbol numbering: bit 0 must be transmitted first.
// Encoding tables/algorithm cross-check: see HDMI_REFERENCE_LICENSE.txt.
module hdmi_symbol_encoder #(parameter integer CHANNEL=0)(
    input wire clk,rst,
    input wire [2:0] mode, // 0 control, 1 video, 2 video guard, 3 data, 4 data guard
    input wire [7:0] video_data,
    input wire [3:0] island_data,
    input wire [1:0] control_data,
    output reg [9:0] symbol
);
reg signed [5:0] disparity;
reg signed [5:0] disparity_next;
reg [8:0] transition_word;
reg [9:0] video_symbol;
integer i,ones,balance;
reg use_xnor;
function [9:0] control_code;
    input [1:0] value;
    begin
        case(value)
            0:control_code=10'b1101010100; 1:control_code=10'b0010101011;
            2:control_code=10'b0101010100; 3:control_code=10'b1010101011;
        endcase
    end
endfunction
function [9:0] terc4;
    input [3:0] value;
    begin
        case(value)
            0:terc4=10'b1010011100; 1:terc4=10'b1001100011;
            2:terc4=10'b1011100100; 3:terc4=10'b1011100010;
            4:terc4=10'b0101110001; 5:terc4=10'b0100011110;
            6:terc4=10'b0110001110; 7:terc4=10'b0100111100;
            8:terc4=10'b1011001100; 9:terc4=10'b0100111001;
            10:terc4=10'b0110011100; 11:terc4=10'b1011000110;
            12:terc4=10'b1010001110; 13:terc4=10'b1001110001;
            14:terc4=10'b0101100011; 15:terc4=10'b1011000011;
        endcase
    end
endfunction
always @* begin
    ones=0;
    for(i=0;i<8;i=i+1) ones=ones+video_data[i];
    use_xnor=(ones>4)||((ones==4)&&!video_data[0]);
    transition_word[0]=video_data[0];
    for(i=1;i<8;i=i+1) transition_word[i]=transition_word[i-1]^video_data[i]^use_xnor;
    transition_word[8]=!use_xnor;
    balance=-8;
    for(i=0;i<8;i=i+1) balance=balance+2*transition_word[i];
    if(disparity==0 || balance==0) begin
        video_symbol={~transition_word[8],transition_word[8],transition_word[7:0]^{8{!transition_word[8]}}};
        disparity_next=disparity+(transition_word[8]?balance:-balance);
    end else if((disparity>0 && balance>0)||(disparity<0 && balance<0)) begin
        video_symbol={1'b1,transition_word[8],~transition_word[7:0]};
        disparity_next=disparity-balance+(transition_word[8]?2:0);
    end else begin
        video_symbol={1'b0,transition_word[8],transition_word[7:0]};
        disparity_next=disparity+balance-(transition_word[8]?0:2);
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin disparity<=0;symbol<=10'b1101010100;end
    else begin
        disparity<=(mode==1)?disparity_next:6'sd0;
        case(mode)
            1:symbol<=video_symbol;
            2:symbol<=(CHANNEL==1)?10'b0100110011:10'b1011001100;
            3:symbol<=terc4(island_data);
            4:symbol<=(CHANNEL==0)?terc4({2'b11,control_data}):10'b0100110011;
            default:symbol<=control_code(control_data);
        endcase
    end
end
endmodule
