`timescale 1ns / 1ps
module conv_layer #(
    parameter DIN_WIDTH     = 8,
    parameter NUM           = 9,
    parameter WEIGHT_WIDTH  = 4,
    parameter MUL_WIDTH     = 12,
    parameter DOUT_WIDTH_1D = 14,
    parameter DOUT_WIDTH_2D = 16
) (
    input  wire                                   clk,
    input  wire                                   rst_n,

    // 4-channel 3x3 pixel windows (flattened)
    input  wire [DIN_WIDTH*NUM-1:0]               conv_din0,
    input  wire [DIN_WIDTH*NUM-1:0]               conv_din1,
    input  wire [DIN_WIDTH*NUM-1:0]               conv_din2,
    input  wire [DIN_WIDTH*NUM-1:0]               conv_din3,

    // All 4 channels' weights packed: [ch3|ch2|ch1|ch0], each NUM*WEIGHT_WIDTH bits
    input  wire signed [WEIGHT_WIDTH*NUM*4-1:0]   weight,

    input  wire                                   conv_mode,
    input  wire                                   conv_in_valid,
    // 2D conv results per channel
    output wire signed [DOUT_WIDTH_2D-1:0]        conv_2D_dout0,
    output wire signed [DOUT_WIDTH_2D-1:0]        conv_2D_dout1,
    output wire signed [DOUT_WIDTH_2D-1:0]        conv_2D_dout2,
    output wire signed [DOUT_WIDTH_2D-1:0]        conv_2D_dout3,

    // 1D partial sums for all 4 channels packed
    output wire signed [DOUT_WIDTH_1D*3*4-1:0]    conv1D_dout,

    output wire                                   conv_out1D_valid,
    output wire                                   conv_out2D_valid
);

// =============================================================================
// Internal wires
// =============================================================================

// Packed pixel input: gate to zero when not valid
wire [DIN_WIDTH*NUM*4-1:0]  din_ff;
// assign din_ff = conv_in_valid ? {conv_din3, conv_din2, conv_din1, conv_din0}
//                               : {(DIN_WIDTH*NUM*4){1'b0}};
assign din_ff = {conv_din3, conv_din2, conv_din1, conv_din0};
// Packed 2D outputs from all PE instances
wire signed [DOUT_WIDTH_2D*4-1:0] conv2D_dout_packed;
assign {conv_2D_dout3, conv_2D_dout2, conv_2D_dout1, conv_2D_dout0} = conv2D_dout_packed;

// Per-channel valid flags — AND all 4 to produce global valid
wire [3:0] conv_out1D_valid_ch;
wire [3:0] conv_out2D_valid_ch;
assign conv_out1D_valid = &conv_out1D_valid_ch;
assign conv_out2D_valid = &conv_out2D_valid_ch;

// =============================================================================
// 4-channel PE array
// =============================================================================
generate
    genvar i;
    for (i = 0; i < 4; i = i + 1) begin : gen_conv_ch
        PE #(
            .DIN_WIDTH    (DIN_WIDTH   ),
            .NUM          (NUM         ),
            .WEIGHT_WIDTH (WEIGHT_WIDTH),
            .MUL_WIDTH    (MUL_WIDTH   ),
            .DOUT_WIDTH_1D(DOUT_WIDTH_1D),
            .DOUT_WIDTH_2D(DOUT_WIDTH_2D)
        ) u_PE (
            .clk              (clk                                               ),
            .rst_n            (rst_n                                             ),
            .din              (din_ff[i*NUM*DIN_WIDTH     +: NUM*DIN_WIDTH     ] ),
            .weight           (weight [i*NUM*WEIGHT_WIDTH +: NUM*WEIGHT_WIDTH  ] ),
            .conv_in_valid    (conv_in_valid                                     ),
            .conv_mode        (conv_mode                                         ),
            .conv1D_dout      (conv1D_dout[i*DOUT_WIDTH_1D*3 +: DOUT_WIDTH_1D*3] ),
            .conv2D_dout      (conv2D_dout_packed[i*DOUT_WIDTH_2D +: DOUT_WIDTH_2D]),
            .conv_out1D_valid (conv_out1D_valid_ch[i]                            ),
            .conv_out2D_valid (conv_out2D_valid_ch[i]                            )
        );
    end
endgenerate

endmodule