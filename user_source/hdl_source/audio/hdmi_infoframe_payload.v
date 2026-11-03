// Fixed Audio/AVI InfoFrame content, byte 0 in the least significant byte.
// Emit/pending/priority remain in the queue; capture/ECC remain in BCH.
module hdmi_infoframe_payload (
    input wire avi, // 0: 2-channel audio; 1: RGB 640x480p VIC 1
    output reg [23:0] header,
    output reg [223:0] payload
);
always @* begin
    payload=0;
    if(avi) begin
        header=24'h0d0282; // type 82, version 2, length 13
        payload[7:0]=8'h56;payload[23:16]=8'h18;payload[39:32]=8'h01;
        // RGB, 4:3, VIC 1, default quantization, no pixel repetition.
    end else begin
        header=24'h0a0184; // type 84, version 1, length 10
        payload[7:0]=8'h70;payload[15:8]=8'h01;
        // CC=1: two channels. CT/SF/SS refer to stream, CA=0: FL/FR.
    end
end
endmodule
