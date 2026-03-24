`timescale 1ns / 1ps
// =============================================================================
// Module  : avg_pool
// Function: Top-level average-pooling dispatcher.
//           Routes the incoming pixel stream to either a 9-pixel (avg_9) or a
//           5-pixel (avg_5) pooling kernel depending on the active network layer
//           indicated by top_state.
//             LAYER3 → avg_9  (single-channel output, avg_pool_dout)
//             LAYER5 → avg_5  (dual-channel output, avg_pool_cov1D_dout)
// =============================================================================
module avg_pool#(
    parameter DIN_WIDTH        = 8,
    parameter DOUT_WIDTH       = 8
)
(
    input wire                    clk,
    input wire                    rst_n,
    input wire [3:0]              top_state,        // One-hot layer selector from top FSM

    input wire [DIN_WIDTH-1:0]    avg_pool_din0,    // Pixel stream for channel 0
    input wire [DIN_WIDTH-1:0]    avg_pool_din1,    // Pixel stream for channel 1
    input wire                    avg_din_valid,

    output wire [DOUT_WIDTH-1:0]   avg_pool_dout,         // avg_9 result (LAYER3)
    output wire [DOUT_WIDTH*2-1:0] avg_pool_cov1D_dout,   // Concatenated avg_5 results (LAYER5)
    output wire                    avg_dout_cov1D_valid,   // High when both avg_5 outputs are valid
    output wire                    avg_dout_valid           // avg_9 output valid
);

// =============================================================================
// Top-level layer-state encoding  (one-hot, 9-bit)
// =============================================================================
localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;
localparam LAYER5 = 9'b001000000;
localparam LAYER6 = 9'b010000000;
localparam LAYER7 = 9'b100000000;

// =============================================================================
// Internal wires  –  per-instance outputs before output muxing
// =============================================================================
wire [DIN_WIDTH-1:0] avg_pool_dout0, avg_pool_dout1;
wire avg_dout_valid0, avg_dout_valid1;

// =============================================================================
// Kernel enable signals  –  decoded from top_state
//   avg_9_en : activates the 9-pixel kernel during LAYER3
//   avg_5_en : activates both 5-pixel kernels during LAYER5
// =============================================================================
wire avg_9_en;
wire avg_5_en;

assign avg_9_en = top_state == LAYER3;
assign avg_5_en = top_state == LAYER5;

// =============================================================================
// avg_9 instance  –  9-pixel average pooling, channel 0 only
// =============================================================================
avg_9#(
   .DIN_WIDTH(DIN_WIDTH),
   .DOUT_WIDTH(DOUT_WIDTH) 
)u_avg_9(
    .clk            (clk            ),
    .rst_n          (rst_n          ),
    .en             (avg_9_en       ),
    .avg_pool_din   (avg_pool_din0  ),
    .avg_din_valid  (avg_din_valid  ),
    .avg_pool_dout  (avg_pool_dout  ),
    .avg_dout_valid (avg_dout_valid )
);

// =============================================================================
// avg_5 instances  –  5-pixel average pooling, one per channel
// =============================================================================

// Channel 0
avg_5#(
   .DIN_WIDTH(DIN_WIDTH),
   .DOUT_WIDTH(DOUT_WIDTH) 
)u_avg_5_0(
    .clk            (clk            ),
    .rst_n          (rst_n          ),
    .en             (avg_5_en       ),
    .avg_pool_din   (avg_pool_din0  ),
    .avg_din_valid  (avg_din_valid  ),
    .avg_pool_dout  (avg_pool_dout0  ),
    .avg_dout_valid (avg_dout_valid0 )
);

// Channel 1
avg_5 #(
   .DIN_WIDTH(DIN_WIDTH),
   .DOUT_WIDTH(DOUT_WIDTH) 
)u_avg_5_1(
    .clk            (clk            ),
    .rst_n          (rst_n          ),
    .en             (avg_5_en       ),
    .avg_pool_din   (avg_pool_din1  ),
    .avg_din_valid  (avg_din_valid  ),
    .avg_pool_dout  (avg_pool_dout1  ),
    .avg_dout_valid (avg_dout_valid1 )
);

// =============================================================================
// 1-D convolution output assembly
//   avg_dout_cov1D_valid : both channels must be valid simultaneously
//   avg_pool_cov1D_dout  : {ch1, ch0} concatenated; zeroed when invalid
// =============================================================================
assign avg_dout_cov1D_valid = avg_dout_valid0 && avg_dout_valid1;

assign avg_pool_cov1D_dout = avg_dout_cov1D_valid ? {avg_pool_dout1, avg_pool_dout0} : 16'b0;

endmodule