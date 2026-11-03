// Fixed 640x480 progressive / 800x525, negative HS/VS, 25MHz pixel clock.
// PCM is already in the pixel domain. NO I2S receiver and NO new clock domain.
// Ten-pixel video delay provides look-ahead for the 8+2 video preamble/guard.
// Two independent 32-pixel data islands per horizontal blank, including V blank.
// Outputs use conventional TMDS bit numbering (bit 0 first); adapt at the PHY.
module hdmi_audio_symbol_core (
    input wire clk,rst,
    input wire [23:0] video_rgb,
    input wire video_hs,video_vs,video_de,
    input wire pcm_commit,
    input wire signed [15:0] pcm_left,pcm_right,
    input wire acr_valid,
    input wire [19:0] acr_n,acr_cts,
    output wire [9:0] channel0_symbol,channel1_symbol,channel2_symbol,
    output wire audio_overflow,
    // Sticky diagnostic only; reset clears it. Does not alter the video path.
    output reg sequence_error
);
reg [9:0] hs_pipe,vs_pipe,de_pipe;
reg [23:0] rgb_pipe[0:9];
reg prev_hs,prev_vs,line_seen,island_enabled;
reg [9:0] line_position;
wire hs=hs_pipe[9],vs=vs_pipe[9],de=de_pipe[9];
wire hs_start=prev_hs && !hs;
wire [9:0] position=hs_start?10'd0:line_position;
// Position zero is HS assertion; active pixels are 144..783.
wire [9:0] blank_position=(position>=784)?position-10'd784:position+10'd16;
wire window_start=(blank_position==12 || blank_position==76);
wire island_on=window_start?line_seen:island_enabled;
wire first_window=(blank_position>=12 && blank_position<56);
wire second_window=(blank_position>=76 && blank_position<120);
wire [9:0] slot=second_window?blank_position-10'd76:blank_position-10'd12;
wire in_island=island_on && (first_window||second_window) && !de;
wire packet_request=in_island && slot==9; // leading guard #2, capture for next pixel
wire info_refresh=prev_vs && !vs;
wire [23:0] header;wire [223:0] payload;
wire [8:0] packet_bits;
wire packet_busy,packet_valid;
wire [4:0] packet_index;
wire [4:0] queue_level;
integer i;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        hs_pipe<=10'h3ff;vs_pipe<=10'h3ff;de_pipe<=0;
        for(i=0;i<10;i=i+1) rgb_pipe[i]<=0;
        prev_hs<=1;prev_vs<=1;line_seen<=0;line_position<=0;island_enabled<=0;
    end else begin
        hs_pipe<={hs_pipe[8:0],video_hs};vs_pipe<={vs_pipe[8:0],video_vs};
        de_pipe<={de_pipe[8:0],video_de};rgb_pipe[0]<=video_rgb;
        for(i=1;i<10;i=i+1) rgb_pipe[i]<=rgb_pipe[i-1];
        prev_hs<=hs;prev_vs<=vs;
        if(hs_start) line_seen<=1;
        line_position<=(position==799)?10'd0:position+1'b1;
        // Never begin half a preamble when HS lock first arrives mid-window.
        if(window_start) island_enabled<=line_seen;
        else if(blank_position==56 || blank_position==120) island_enabled<=0;
    end
end
hdmi_audio_packet_queue u_packets (
    .clk(clk),.rst(rst),.pcm_commit(pcm_commit),.pcm_left(pcm_left),.pcm_right(pcm_right),
    .acr_valid(acr_valid),.acr_n(acr_n),.acr_cts(acr_cts),
    .info_refresh(info_refresh),.packet_request(packet_request),.header(header),.payload(payload),
    .overflow(audio_overflow),.level(queue_level)
);
hdmi_packet_bch u_bch (
    .clk(clk),.rst(rst),.start(packet_request),.header(header),.payload(payload),
    .busy(packet_busy),.packet_valid(packet_valid),.packet_index(packet_index),.packet_bits(packet_bits)
);
reg [2:0] mode;
reg [1:0] control1,control2;
wire video_guard=!de && de_pipe[7];
wire video_preamble=!de && !video_guard && video_de;
// Independent 44-cycle observer of the scheduled island: 8 preamble,
// 2 leading guard, 32 payload and 2 trailing guard cycles. Keep this
// separate from the existing position-based scheduler; no new clock domain.
reg sequence_active;
reg [5:0] sequence_slot;
wire payload_expected=sequence_slot>=10 && sequence_slot<42;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        sequence_error<=0;sequence_active<=0;sequence_slot<=0;
    end else begin
        if(!sequence_active) begin
            if(in_island) begin
                if(slot!=0 || mode!=0 || control1!=1 || control2!=1)
                    sequence_error<=1;
                sequence_active<=1;sequence_slot<=1;
            end
        end else begin
            if(!in_island || slot!=sequence_slot || de || video_guard || video_preamble)
                sequence_error<=1;
            if(sequence_slot<8) begin
                if(mode!=0 || control1!=1 || control2!=1) sequence_error<=1;
            end else if(payload_expected) begin
                if(mode!=3 || !packet_valid || packet_index!=sequence_slot-6'd10)
                    sequence_error<=1;
            end else if(mode!=4) sequence_error<=1;
            if(sequence_slot==43) begin sequence_active<=0;sequence_slot<=0;end
            else sequence_slot<=sequence_slot+1'b1;
        end
        if(packet_request && packet_busy) sequence_error<=1;
        if(packet_valid && (!sequence_active || !payload_expected)) sequence_error<=1;
    end
end
always @* begin
    mode=0;control1=0;control2=0;
    if(de) mode=1;
    else if(video_guard) mode=2;
    else if(video_preamble) control1=1;
    else if(in_island) begin
        if(slot<8) begin control1=1;control2=1;end
        else if(slot<10 || slot>=42) mode=4;
        else mode=3;
    end
end
hdmi_symbol_encoder #(.CHANNEL(0)) u_ch0 (
    .clk(clk),.rst(rst),.mode(mode),.video_data(rgb_pipe[9][7:0]),
    .island_data({1'b1,packet_bits[0],vs,hs}),.control_data({vs,hs}),.symbol(channel0_symbol)
);
hdmi_symbol_encoder #(.CHANNEL(1)) u_ch1 (
    .clk(clk),.rst(rst),.mode(mode),.video_data(rgb_pipe[9][15:8]),
    .island_data(packet_bits[4:1]),.control_data(control1),.symbol(channel1_symbol)
);
hdmi_symbol_encoder #(.CHANNEL(2)) u_ch2 (
    .clk(clk),.rst(rst),.mode(mode),.video_data(rgb_pipe[9][23:16]),
    .island_data(packet_bits[8:5]),.control_data(control2),.symbol(channel2_symbol)
);
endmodule
