`timescale 1ns / 1ps
// =============================================================================
// Module  : MUL
// Function: Single unsigned×signed multiplier cell used inside each PE.
//           din_A is zero-extended by one bit to prevent sign contamination
//           before being multiplied with the signed weight din_B.
//           Result width = DIN_WIDTH+1 + WEIGHT_WIDTH, truncated to DOUT_WIDTH.
// Latency : 0 (purely combinational)
// =============================================================================
module MUL#(
    parameter DIN_WIDTH    = 8,    // Unsigned pixel input bit-width
    parameter WEIGHT_WIDTH = 4,    // Signed weight bit-width (int4)
    parameter DOUT_WIDTH   = 12    // Product output bit-width
    )
(
    input  wire        [DIN_WIDTH-1:0]     din_A,   // Unsigned pixel value
    input  wire signed [WEIGHT_WIDTH-1:0]  din_B,   // Signed weight
    output wire signed [DOUT_WIDTH-1:0]    dout     // Signed product
);

// =============================================================================
// Sign extension
//   Prepend a zero MSB so that the unsigned pixel is treated as a positive
//   signed value when multiplied with the signed weight.
// =============================================================================
wire signed [DIN_WIDTH:0] din_A_ff;

assign din_A_ff = {1'b0, din_A};

// =============================================================================
// Multiply
// =============================================================================
assign dout = din_A_ff * din_B;

endmodule