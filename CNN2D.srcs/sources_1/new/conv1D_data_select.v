`timescale 1ns / 1ps
// =============================================================================
// Module  : conv1D_data_select
// Function: Data selector and 3-beat shift buffer for 1-D convolution input.
//           Reads 4-pixel-wide RAM output, accumulates 3 consecutive beats into
//           a sliding window buffer, and outputs a packed 8-channel × 3-beat
//           window to the downstream 1-D conv layer.
//           A cycle counter (out_cnt) tracks burst length per layer stage,
//           and generates a 'control' pulse to flush the valid pipeline.
// =============================================================================
module conv1D_data_select #(
    parameter DIN_WIDTH  = 8,   // Input pixel bit-width
    parameter DOUT_WIDTH = 8    // Output pixel bit-width (same as input)
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // ---- Top-level FSM state (one-hot) -------------------------------------
    input  wire [8:0]                  top_state,

    // ---- RAM read interface ------------------------------------------------
    input  wire                        conv1D_din_valid,  // RAM output valid strobe
    input  wire [DIN_WIDTH*4-1:0]      ram_out,           // 4 pixels packed from RAM

    // ---- Sliding-window output to 1-D conv ---------------------------------
    output wire [DOUT_WIDTH*8*3-1:0]   conv1D_select_dout, // 8 channels × 3 beats packed
    output wire                        control,             // end-of-burst flush pulse
    output reg                         conv1D_dout_valid    // output data valid
);

// =============================================================================
// One-hot FSM state encoding
// =============================================================================
localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;  // 1-D conv stage: burst length 16
localparam LAYER5 = 9'b001000000;  // 1-D conv stage: burst length  7
localparam LAYER6 = 9'b010000000;
localparam LAYER7 = 9'b100000000;

// =============================================================================
// Burst cycle counter (out_cnt)
// Counts valid input beats within LAYER4 / LAYER5; resets otherwise.
// =============================================================================
reg [3:0] out_cnt;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        out_cnt <= 4'b0;
    end
    else begin
        case (top_state)
            LAYER4: begin
                if (conv1D_din_valid) begin
                    if (out_cnt == 4'd15)   out_cnt <= 4'b0;        // wrap at 16
                    else                    out_cnt <= out_cnt + 1'b1;
                end
            end
            LAYER5: begin
                if (conv1D_din_valid) begin
                    if (out_cnt == 4'd6)    out_cnt <= 4'b0;        // wrap at 7
                    else                    out_cnt <= out_cnt + 1'b1;
                end
            end
            default: out_cnt <= 4'b0;                               // idle / other layers
        endcase
    end
end

// End-of-burst pulse: asserted on the last valid beat of each layer burst
assign control = (out_cnt == 5'd15 && top_state == LAYER4) ||
                 (out_cnt == 5'd6  && top_state == LAYER5);

// =============================================================================
// RAM output unpacking (gated to zero when invalid)
// =============================================================================
wire [DIN_WIDTH-1:0] conv1D_din0, conv1D_din1, conv1D_din2, conv1D_din3;

assign {conv1D_din3, conv1D_din2, conv1D_din1, conv1D_din0} =
           conv1D_din_valid ? ram_out : 32'b0;

// =============================================================================
// Output valid pipeline
// conv1D_dout_valid is delayed 2 cycles behind conv1D_din_valid.
// On end-of-burst (control), the pipeline is flushed to prevent spurious valid.
// =============================================================================
reg conv1D_valid_ff0, conv1D_valid_ff1;   // 2-stage delay shift register

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_dout_valid <= 1'b0;
        conv1D_valid_ff0  <= 1'b0;
        conv1D_valid_ff1  <= 1'b0;
    end
    else if (control) begin
        // Flush valid pipeline at end of burst
        conv1D_dout_valid <= conv1D_valid_ff1;
        conv1D_valid_ff0  <= 1'b0;
        conv1D_valid_ff1  <= 1'b0;
    end
    else begin
        conv1D_valid_ff0  <= conv1D_din_valid;
        conv1D_valid_ff1  <= conv1D_valid_ff0;
        conv1D_dout_valid <= conv1D_valid_ff1;
    end
end

// =============================================================================
// 3-beat sliding window buffer
// buffer_conv0/1/2 hold the oldest-to-newest pixel rows respectively.
// Each beat shifts conv2 → conv1 → conv0, then loads the new pixels into conv2.
// Buffer is cleared when input is not valid.
// =============================================================================
integer i;
reg [DIN_WIDTH-1:0] buffer_conv0 [0:3];  // oldest beat (t-2)
reg [DIN_WIDTH-1:0] buffer_conv1 [0:3];  // middle  beat (t-1)
reg [DIN_WIDTH-1:0] buffer_conv2 [0:3];  // newest  beat (t)

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 4; i = i + 1) begin
            buffer_conv0[i] <= 8'b0;
            buffer_conv1[i] <= 8'b0;
            buffer_conv2[i] <= 8'b0;
        end
    end
    else if (conv1D_din_valid) begin
        // Shift old beats down, load new pixels into conv2
        for (i = 0; i < 4; i = i + 1) begin
            buffer_conv0[i] <= buffer_conv1[i];
            buffer_conv1[i] <= buffer_conv2[i];
        end
        buffer_conv2[0] <= conv1D_din0;
        buffer_conv2[1] <= conv1D_din1;
        buffer_conv2[2] <= conv1D_din2;
        buffer_conv2[3] <= conv1D_din3;
    end
    else begin
        // Clear buffer when no valid input
        for (i = 0; i < 4; i = i + 1) begin
            buffer_conv0[i] <= 8'b0;
            buffer_conv1[i] <= 8'b0;
            buffer_conv2[i] <= 8'b0;
        end
    end
end

// =============================================================================
// Output packing
// Layout: 8 virtual channels (ch0~ch3 duplicated) × 3 beats each.
// Each group is packed as [newest(conv2) | middle(conv1) | oldest(conv0)].
// =============================================================================
assign conv1D_select_dout = {
    buffer_conv2[3], buffer_conv1[3], buffer_conv0[3],   // ch3 (copy B)
    buffer_conv2[2], buffer_conv1[2], buffer_conv0[2],   // ch2 (copy B)
    buffer_conv2[1], buffer_conv1[1], buffer_conv0[1],   // ch1 (copy B)
    buffer_conv2[0], buffer_conv1[0], buffer_conv0[0],   // ch0 (copy B)
    buffer_conv2[3], buffer_conv1[3], buffer_conv0[3],   // ch3 (copy A)
    buffer_conv2[2], buffer_conv1[2], buffer_conv0[2],   // ch2 (copy A)
    buffer_conv2[1], buffer_conv1[1], buffer_conv0[1],   // ch1 (copy A)
    buffer_conv2[0], buffer_conv1[0], buffer_conv0[0]    // ch0 (copy A)
};

endmodule