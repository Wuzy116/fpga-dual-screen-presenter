// Fixed format: 2-channel consumer LPCM, 48 kHz, 16 significant bits.
// HDMI 1.4a tables 5-12/13, ACR 5.3.3, InfoFrames 8.2.1/8.2.2.
// Protocol cross-check: hdl-util/hdmi (Sameer Puri); see HDMI_REFERENCE_LICENSE.txt.
// Byte 0 is the least significant byte. All reserved fields are zero.
module hdmi_packet_payload #(
    parameter integer PCM_PAIRS = 1 // Supported: 1..4 subpackets per PCM packet
) (
    input wire [2:0] packet_kind, // 0 Null, 1 PCM, 2 ACR, 3 Audio IF, 4 AVI IF
    input wire signed [15:0] pcm_left, pcm_right,
    input wire [7:0] frame_index, // IEC60958 frame 0..191, advances per sample pair
    input wire [19:0] acr_n, acr_cts,
    output reg [23:0] header,
    output reg [223:0] payload,
    // Pairs 1..3, low pair first; unused when PCM_PAIRS=1.
    input wire [95:0] pcm_extra
);
// Byte 0: consumer/LPCM/copyright not asserted/no emphasis.
// Byte 2: channel number 1/2; byte 3: 48kHz; byte 4: 16 bits (20-bit max).
localparam [191:0] STATUS_LEFT ={152'd0,40'h0202100004};
localparam [191:0] STATUS_RIGHT={152'd0,40'h0202200004};
wire [127:0] pcm_words={pcm_extra,pcm_right,pcm_left};
integer sub,frame;
reg cl,cr;
reg [23:0] left_word,right_word;
wire [23:0] acr_header;
wire [223:0] acr_payload;
hdmi_acr_payload u_acr (
    .acr_n(acr_n),.acr_cts(acr_cts),.header(acr_header),.payload(acr_payload)
);
wire [23:0] info_header;
wire [223:0] info_payload;
hdmi_infoframe_payload u_infoframe (
    .avi(packet_kind==3'd4),.header(info_header),.payload(info_payload)
);
always @* begin
    header=0;payload=0;frame=0;cl=0;cr=0;left_word=0;right_word=0;
    case(packet_kind)
        1: begin
            header=24'h000002; // layout 0; sample-present bits selected below
            for(sub=0;sub<PCM_PAIRS;sub=sub+1) begin
                frame=frame_index+sub;
                if(frame_index<192 && frame>=192) frame=frame-192;
                cl=(frame<192)?STATUS_LEFT[frame]:1'b0;
                cr=(frame<192)?STATUS_RIGHT[frame]:1'b0;
                left_word={pcm_words[sub*32+:16],8'd0};
                right_word={pcm_words[sub*32+16+:16],8'd0};
                header[8+sub]=1'b1;
                header[20+sub]=(frame==0); // block-start B[sub], not sample-flat
                payload[sub*56+:56]={(^right_word)^cr,cr,2'b00,(^left_word)^cl,cl,2'b00,right_word,left_word};
            end
        end
        2: begin header=acr_header;payload=acr_payload;end
        3,4: begin header=info_header;payload=info_payload;end
        default: begin header=0;payload=0;end
    endcase
end
endmodule
