// HDMI data-island packet: 24-bit header + 4 x 56-bit subpacket.
// LSB-first transport, BCH parity (HDMI Figure 5-5), 32 pixel slots.
// start is accepted only while idle. Payload is captured, so the caller
// may change it afterwards. No stall is permitted inside a packet.
module hdmi_packet_bch (
    input wire clk, rst, start,
    input wire [23:0] header,
    input wire [223:0] payload,
    output reg busy,
    output wire packet_valid,
    output reg [4:0] packet_index,
    output wire [8:0] packet_bits
);
reg [23:0] header_hold;
reg [223:0] payload_hold;
reg [7:0] header_ecc;
reg [7:0] sub_ecc [0:3];
wire [31:0] header_code={header_ecc,header_hold};
wire [5:0] even_bit={packet_index,1'b0};
wire [5:0] odd_bit={packet_index,1'b1};
function [7:0] ecc_step;
    input [7:0] remainder;
    input data_bit;
    begin ecc_step=(remainder>>1)^((remainder[0]^data_bit)?8'h83:8'h00); end
endfunction
assign packet_valid=busy;
assign packet_bits[0]=header_code[packet_index];
genvar s;
generate for(s=0;s<4;s=s+1) begin: subpacket
    wire [55:0] data=payload_hold[s*56+:56];
    wire [63:0] codeword={sub_ecc[s],data};
    assign packet_bits[s+1]=codeword[even_bit];
    assign packet_bits[s+5]=codeword[odd_bit];
    always @(posedge clk or posedge rst) begin
        if(rst) sub_ecc[s]<=0;
        else if(!busy) sub_ecc[s]<=0;
        else if(packet_index<28)
            sub_ecc[s]<=ecc_step(ecc_step(sub_ecc[s],data[even_bit]),data[odd_bit]);
    end
end endgenerate
always @(posedge clk or posedge rst) begin
    if(rst) begin
        busy<=0; packet_index<=0; header_hold<=0; payload_hold<=0; header_ecc<=0;
    end else if(!busy) begin
        packet_index<=0; header_ecc<=0;
        if(start) begin busy<=1; header_hold<=header; payload_hold<=payload; end
    end else begin
        if(packet_index<24) header_ecc<=ecc_step(header_ecc,header_hold[packet_index]);
        if(packet_index==31) begin busy<=0; packet_index<=0; end
        else packet_index<=packet_index+1'b1;
    end
end
endmodule
