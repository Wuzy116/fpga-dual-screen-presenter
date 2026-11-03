// Combinational ACR formatter; byte 0 is the least significant byte.
// The queue owns pending/latest N/CTS; hdmi_packet_bch owns capture and ECC.
// No timer, handshake, clock or pipeline stage is added here.
module hdmi_acr_payload (
    input wire [19:0] acr_n,acr_cts,
    output wire [23:0] header,
    output wire [223:0] payload
);
wire [55:0] acr_sub={acr_n[7:0],acr_n[15:8],4'd0,acr_n[19:16],
                    acr_cts[7:0],acr_cts[15:8],4'd0,acr_cts[19:16],8'd0};
assign header=24'h000001;
assign payload={4{acr_sub}};
endmodule
