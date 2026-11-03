// Pixel-domain packet selection and 16-pair elastic PCM queue.
// request captures the currently offered header/payload in hdmi_packet_bch.
// At 640x480, two packet opportunities/line exceed the 48k sample rate.
// Overflow is sticky and drops the NEW input, never overwrites queued audio.
module hdmi_audio_packet_queue #(
    parameter integer PCM_PAIRS = 4 // Supported: 1..4; wait for a full packet
) (
    input wire clk,rst,
    input wire pcm_commit,
    input wire signed [15:0] pcm_left,pcm_right,
    input wire acr_valid,
    input wire [19:0] acr_n,acr_cts,
    input wire info_refresh,packet_request,
    output wire [23:0] header,
    output wire [223:0] payload,
    output reg overflow,
    output wire [4:0] level
);
reg [31:0] samples [0:15];
reg [3:0] rd_ptr,wr_ptr;
reg [4:0] count;
reg [7:0] frame_index;
reg [19:0] n_hold,cts_hold;
reg acr_pending,audio_info_pending,avi_pending;
reg [2:0] kind;
wire pop=packet_request && kind==1;
wire push=pcm_commit && (count<16 || pop);
wire [31:0] next_sample=(count!=0)?samples[rd_ptr]:32'd0;
wire [3:0] rd1=rd_ptr+4'd1,rd2=rd_ptr+4'd2,rd3=rd_ptr+4'd3;
wire [95:0] extra_samples={samples[rd3],samples[rd2],samples[rd1]};
assign level=count;
always @* begin
    if(acr_pending) kind=2;
    else if(audio_info_pending) kind=3;
    else if(avi_pending) kind=4;
    else if(count>=PCM_PAIRS) kind=1;
    else kind=0;
end
hdmi_packet_payload #(.PCM_PAIRS(PCM_PAIRS)) u_payload (
    .packet_kind(kind),.pcm_left(next_sample[15:0]),.pcm_right(next_sample[31:16]),
    .frame_index(frame_index),.acr_n(n_hold),.acr_cts(cts_hold),.header(header),.payload(payload),
    .pcm_extra(extra_samples)
);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        rd_ptr<=0;wr_ptr<=0;count<=0;frame_index<=0;overflow<=0;
        n_hold<=20'd6144;cts_hold<=20'd25000;
        acr_pending<=1;audio_info_pending<=1;avi_pending<=1;
    end else begin
        if(push) begin samples[wr_ptr]<={pcm_right,pcm_left};wr_ptr<=wr_ptr+1'b1;end
        if(pcm_commit && !push) overflow<=1;
        if(pop) begin
            rd_ptr<=rd_ptr+PCM_PAIRS;
            frame_index<=(frame_index>=192-PCM_PAIRS)?frame_index+PCM_PAIRS-192:frame_index+PCM_PAIRS;
        end
        case({push,pop})
            2'b10:count<=count+1'b1;
            2'b01:count<=count-PCM_PAIRS;
            2'b11:count<=count-PCM_PAIRS+1;
            default:count<=count;
        endcase
        if(packet_request) begin
            if(kind==2) acr_pending<=0;
            if(kind==3) audio_info_pending<=0;
            if(kind==4) avi_pending<=0;
        end
        // New events win over a simultaneous consumption of the OLD packet.
        if(acr_valid) begin n_hold<=acr_n;cts_hold<=acr_cts;acr_pending<=1;end
        if(info_refresh) begin audio_info_pending<=1;avi_pending<=1;end
    end
end
endmodule
