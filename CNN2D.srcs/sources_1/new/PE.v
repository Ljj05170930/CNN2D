`timescale 1ns / 1ps
// =============================================================================
// Module  : PE  (Processing Element)
// Function: 3×3 convolution engine for a single output channel.
//           Nine MUL cells compute pixel×weight products in parallel.
//           Products are accumulated in two pipeline stages:
//             Stage 1 – three row partial sums (add_dout0/1/2), registered.
//             Stage 2 – column sum of the three row results → conv2D_dout.
//           Two output modes selected by conv_mode:
//             conv_mode=0 : 2-D full conv output (conv2D_dout, conv_out2D_valid)
//             conv_mode=1 : 1-D row partial sums  (conv1D_dout, conv_out1D_valid)
// Latency : 2 cycles from conv_in_valid to conv_out2D_valid (mode 0)
//           1 cycle  from conv_in_valid to conv_out1D_valid  (mode 1)
// =============================================================================
module PE#(
    parameter DIN_WIDTH     = 8,    // Input pixel bit-width
    parameter NUM           = 9,    // Kernel elements (3×3)
    parameter WEIGHT_WIDTH  = 4,    // Signed weight bit-width (int4)
    parameter MUL_WIDTH     = 12,   // MUL output width (DIN_WIDTH+1 + WEIGHT_WIDTH)
    parameter DOUT_WIDTH_1D = 14,   // Row partial-sum width (3 products accumulated)
    parameter DOUT_WIDTH_2D = 16    // Full 3×3 conv result width (3 rows accumulated)
    )
(
    input  wire                                clk,
    input  wire                                rst_n,

    input  wire        [DIN_WIDTH*NUM-1:0]     din,            // Flattened 9-pixel window
    input  wire signed [WEIGHT_WIDTH*NUM-1:0]  weight,         // Flattened 9-weight kernel
    input  wire                                conv_mode,      // 0 = 2-D mode, 1 = 1-D mode
    input  wire                                conv_in_valid,  // Input window valid strobe

    output wire signed [DOUT_WIDTH_1D*3-1:0]   conv1D_dout,      // {row2, row1, row0} partial sums
    output reg  signed [DOUT_WIDTH_2D-1:0]     conv2D_dout,      // Full 3×3 convolution result
    output reg                                 conv_out1D_valid,  // Valid strobe for conv1D_dout
    output reg                                 conv_out2D_valid   // Valid strobe for conv2D_dout
);

// =============================================================================
// Internal wires and registers
// =============================================================================
wire signed [MUL_WIDTH-1:0]   mul_out [0:NUM-1];      // Outputs of 9 MUL instances
reg  signed [DOUT_WIDTH_1D-1:0] add_dout0;            // Row 0 partial sum (pixels 0,1,2)
reg  signed [DOUT_WIDTH_1D-1:0] add_dout1;            // Row 1 partial sum (pixels 3,4,5)
reg  signed [DOUT_WIDTH_1D-1:0] add_dout2;            // Row 2 partial sum (pixels 6,7,8)
reg  conv_out2D_valid_ff;                             // One-cycle delay pipeline for 2-D valid

// =============================================================================
// 1-D output assembly
//   Pack the three row partial sums into a single bus for downstream use.
// =============================================================================
assign conv1D_dout = {add_dout2, add_dout1, add_dout0};

// =============================================================================
// Pixel unpack  (unused in arithmetic but useful for debug/readability)
// =============================================================================
wire [7:0] conv_din [0:8];
generate
    genvar j;
    for (j = 0; j < 9; j = j + 1) begin
        assign conv_din[j] = din[j*DIN_WIDTH+:DIN_WIDTH];
    end
endgenerate

// =============================================================================
// MUL array  –  9 parallel multipliers, one per kernel position
//   din  slice : din[DIN_WIDTH*(i+1)-1 : DIN_WIDTH*i]
//   weight slice: weight[WEIGHT_WIDTH*(i+1)-1 : WEIGHT_WIDTH*i]
// =============================================================================
generate
    genvar i;
    for (i = 0; i < NUM; i = i + 1) begin
        MUL #(
            .DIN_WIDTH    (DIN_WIDTH),
            .WEIGHT_WIDTH (WEIGHT_WIDTH),
            .DOUT_WIDTH   (MUL_WIDTH)
        ) u_MUL (
            .din_A (din[DIN_WIDTH*(i+1)-1 : DIN_WIDTH*i]),
            .din_B (weight[WEIGHT_WIDTH*(i+1)-1 : WEIGHT_WIDTH*i]),
            .dout  (mul_out[i])
        );
    end
endgenerate

// =============================================================================
// Two-stage accumulator
//   Stage 1 (same cycle as conv_in_valid):  compute three row partial sums.
//   Stage 2 (one cycle later):             sum the three rows → conv2D_dout.
//   All registers clear to zero when conv_in_valid is de-asserted.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        add_dout0   <= 14'b0;
        add_dout1   <= 14'b0;
        add_dout2   <= 14'b0;
        // conv2D_dout <= 16'b0;
    end else if (conv_in_valid) begin
        // Stage 1: row partial sums
        add_dout0  <= mul_out[0] + mul_out[1] + mul_out[2];
        add_dout1  <= mul_out[3] + mul_out[4] + mul_out[5];
        add_dout2  <= mul_out[6] + mul_out[7] + mul_out[8];
        // Stage 2: column accumulation of previous cycle's row sums
        // conv2D_dout <= add_dout0 + add_dout1 + add_dout2;
    end else begin
        add_dout0   <= 14'b0;
        add_dout1   <= 14'b0;
        add_dout2   <= 14'b0;
        // conv2D_dout <= 16'b0;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        conv2D_dout <= 16'b0;
    end
    else begin
        conv2D_dout <= add_dout0 + add_dout1 + add_dout2;
    end
end

// =============================================================================
// Valid pipeline
//   conv_mode=0 (2-D): conv_out2D_valid is asserted two cycles after
//                      conv_in_valid to account for the two accumulator stages.
//   conv_mode=1 (1-D): conv_out1D_valid mirrors conv_in_valid (one stage).
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv_out1D_valid    <= 1'b0;
        conv_out2D_valid    <= 1'b0;
        conv_out2D_valid_ff <= 1'b0;
    end 
    else begin
        case (conv_mode)
            1'b0:begin
                // 2-D mode: two-cycle delay on valid
                conv_out2D_valid_ff <= conv_in_valid;
                conv_out2D_valid    <= conv_out2D_valid_ff;
                conv_out1D_valid    <= 1'b0;
            end 
            1'b1:begin
                // 1-D mode: one-cycle delay on valid
                conv_out1D_valid    <= conv_in_valid;
                conv_out2D_valid    <= 1'b0;
                conv_out2D_valid_ff <= 1'b0;
            end
            default:begin
                conv_out1D_valid    <= 1'b0;
                conv_out2D_valid    <= 1'b0;
                conv_out2D_valid_ff <= 1'b0;
            end
        endcase
    end
end

endmodule