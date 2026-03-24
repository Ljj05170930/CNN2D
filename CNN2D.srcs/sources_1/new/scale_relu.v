`timescale 1ns / 1ps
// =============================================================================
// Module  : scale_relu
// Function: Bias addition followed by ReLU activation and right-shift scaling.
//           Implements:  dout = ReLU(din + bias) >> scale
//           All arithmetic is performed in signed SCALE_IN_WIDTH-bit precision;
//           the final arithmetic right-shift produces an unsigned DOUT_WIDTH
//           result.
// Latency : 0 (purely combinational)
// =============================================================================
module scale_relu#(
    parameter SCALE_IN_WIDTH = 20,
    parameter DOUT_WIDTH     = 8,
    parameter BIAS_WIDTH     = 12,
    parameter SCALE_WIDTH    = 3
    )
(
    input  wire        [SCALE_WIDTH-1:0]    scale,   // Right-shift amount (0~7)
    input  wire signed [BIAS_WIDTH-1:0]     bias,    // Signed bias term
    input  wire signed [SCALE_IN_WIDTH-1:0] din,     // Signed accumulator input

    output wire        [DOUT_WIDTH-1:0] dout         // Unsigned scaled output
);

// =============================================================================
// Bias addition and ReLU
//   dout_ff  : result of din + bias (full precision, signed)
//   dout_reg : ReLU output — zeroed when dout_ff is negative (MSB == 1)
// =============================================================================
wire signed [SCALE_IN_WIDTH-1:0]  dout_ff;
wire signed [SCALE_IN_WIDTH-1:0]  dout_reg;

assign dout_ff =  din + bias ;
assign dout_reg = dout_ff[SCALE_IN_WIDTH-1] ? 20'b0 : dout_ff;

// =============================================================================
// Arithmetic right-shift  –  quantise to DOUT_WIDTH bits
// =============================================================================
assign dout = (dout_reg >>> scale);

endmodule