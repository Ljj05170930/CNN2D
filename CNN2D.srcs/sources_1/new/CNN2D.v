`timescale 1ns / 1ps
// =============================================================================
// Module  : CNN2D
// Function: CNN top-level
// =============================================================================
module CNN2D #(
    // ---- Shared: pixel data width across all modules -------------------------
    parameter DIN_WIDTH     = 8,    // Input pixel bit-width (conv_layer din, maxpool din)
 
    // ---- Shared: final output width -----------------------------------------
    parameter DOUT_WIDTH    = 8,    // Top-level dout width; also maxpool output width
    parameter SRAM_WIDTH    = 10,
    // ---- conv_layer / PE: convolution datapath widths -----------------------
    parameter NUM           = 9,    // Kernel elements per channel (3x3 = 9)
    parameter WEIGHT_WIDTH  = 4,    // Weight bit-width (int4, used in PE -> MUL)
    parameter MUL_WIDTH     = 12,   // Multiplier output width in PE (DIN+WEIGHT sign-extended)
    parameter DOUT_WIDTH_1D = 14,   // PE row-partial-sum width (3 mults accumulated)
    parameter DOUT_WIDTH_2D = 16,   // PE full 3x3 conv result width (3 rows accumulated)
 
    // ---- BN (Batch Norm) / post-processing widths ---------------------------
    parameter BIAS_WIDTH    = 12,   // Bias adder bit-width (BN module)
    parameter SCALE_WIDTH   = 3,    // Scale shift bits for BN quantization
    parameter SCALE_IN_WIDTH = 20,  // Scale data in bit
    // ---- maxpool_layer / address counter -----------------------------------
    parameter MAX_WIDTH     = 6    // Address/counter width (max image dim = 2^MAX_WIDTH)

) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   cnn_start,

    input  wire [DIN_WIDTH-1:0]   din,
    input  wire                   din_valid,

    output wire [DOUT_WIDTH-1:0]  dout,
    output wire                   dout_valid
);

localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;
localparam LAYER5 = 9'b001000000;
localparam LAYER6 = 9'b010000000;
localparam LAYER7 = 9'b100000000;

wire [8:0] top_state;

// =============================================================================
// Weight_Rom
// =============================================================================
wire [5:0]   W_addr;
wire [143:0] W_dout;

Weight_Rom u_Weight_Rom(
    .clka  (clk      ),
    .ena   (cnn_start),
    .addra (W_addr   ),
    .douta (W_dout   )
);
// =============================================================================
// Bias_Rom
// =============================================================================
wire [5:0]   B_addr;
wire [BIAS_WIDTH-1:0] B_dout;

Bias_Rom u_Bias_Rom(
    .clka  (clk      ),
    .ena   (cnn_start),
    .addra (B_addr   ),
    .douta (B_dout   )
);

// =============================================================================
// Scale_Rom
// =============================================================================
wire [5:0]   S_addr;
wire [SCALE_WIDTH-1:0] S_dout;

Scale_Rom u_Scale_Rom(
    .clka  (clk      ),
    .ena   (cnn_start),
    .addra (S_addr   ),
    .douta (S_dout   )
);

// =============================================================================
// DATA_SELECT
//   Buffers three consecutive input rows in circular line buffers and assembles
//   a 3×3 sliding window for each of the four input channels.  The four
//   flattened 9-pixel windows (select_dout0~3) are forwarded directly to
//   conv_layer as conv_din0~3.  data_select_valid drives conv_in_valid.
// =============================================================================

// Intermediate pixel buses: one per channel, routed from upstream source to
// DATA_SELECT.  These carry raw DIN_WIDTH-wide pixels before windowing.
wire [DIN_WIDTH-1:0] select_din0;   // Raw pixel stream for channel 0
wire [DIN_WIDTH-1:0] select_din1;   // Raw pixel stream for channel 1
wire [DIN_WIDTH-1:0] select_din2;   // Raw pixel stream for channel 2
wire [DIN_WIDTH-1:0] select_din3;   // Raw pixel stream for channel 3

wire [DIN_WIDTH-1:0] select_dout0;
wire [DIN_WIDTH-1:0] select_dout1;
wire [DIN_WIDTH-1:0] select_dout2;
wire [DIN_WIDTH-1:0] select_dout3;

wire data_select_valid;

wire [MAX_WIDTH-1:0]  img_width;        // active feature-map width
wire [MAX_WIDTH-1:0]  img_height;       // active feature-map height

assign select_din0 = din;
assign select_din1 = din;
assign select_din2 = din;
assign select_din3 = din;

DATA_SELECT #(
    .DIN_WIDTH  (DIN_WIDTH ),
    .DOUT_WIDTH (DIN_WIDTH ),   // Window pixel width equals input pixel width
    .MAX_WIDTH  (MAX_WIDTH ),
    .NUM        (NUM       )
) u_data_select (
    .clk               (clk               ),
    .rst_n             (rst_n             ),
    .cnn_start         (cnn_start         ),

    // Raw per-channel pixel inputs
    .select_din0       (select_din0       ),
    .select_din1       (select_din1       ),
    .select_din2       (select_din2       ),
    .select_din3       (select_din3       ),

    // Shared spatial config and input valid
    .din_valid         (din_valid         ),
    .img_width         (img_width         ),
    .img_height        (img_height        ),

    // 3×3 flattened window outputs → connect directly to conv_layer inputs
    .select_dout0      (select_dout0      ),
    .select_dout1      (select_dout1      ),
    .select_dout2      (select_dout2      ),
    .select_dout3      (select_dout3      ),

    // Window-valid strobe → gates conv_layer input
    .data_select_valid (data_select_valid )
);

// =============================================================================
// CONV_LAYER
// =============================================================================

// 4-channel 3x3 pixel windows fed into conv_layer
wire [DIN_WIDTH*NUM-1:0]              conv_din0;        // channel 0 pixel window
wire [DIN_WIDTH*NUM-1:0]              conv_din1;        // channel 1 pixel window
wire [DIN_WIDTH*NUM-1:0]              conv_din2;        // channel 2 pixel window
wire [DIN_WIDTH*NUM-1:0]              conv_din3;        // channel 3 pixel window
 
// Weight bus from BRAM: all 4 channels packed, one filter's worth per cycle
 
// Control signals from internal sequencer
wire                                  conv_mode;        // clears PE accumulators
wire                                  conv_in_valid;    // pixel window is valid
 
// conv_layer outputs
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout0;
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout1;
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout2;
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout3;
wire signed [DOUT_WIDTH_1D*3*4-1:0]   conv1D_dout;
wire                                  conv_out1D_valid;
wire                                  conv_out2D_valid;

conv_layer #(
    .DIN_WIDTH    (DIN_WIDTH    ),
    .NUM          (NUM          ),
    .WEIGHT_WIDTH (WEIGHT_WIDTH ),
    .MUL_WIDTH    (MUL_WIDTH    ),
    .DOUT_WIDTH_1D(DOUT_WIDTH_1D),
    .DOUT_WIDTH_2D(DOUT_WIDTH_2D)
) u_conv_layer (
    .clk              (clk              ),
    .rst_n            (rst_n            ),
 
    // 4-channel pixel windows from upstream (line buffer / sliding window)
    .conv_din0        (conv_din0        ),
    .conv_din1        (conv_din1        ),
    .conv_din2        (conv_din2        ),
    .conv_din3        (conv_din3        ),
 
    // Weights from BRAM (current filter, all 4 channels)
    .weight           (W_dout           ),
 
    // Control
    .conv_mode        (conv_mode        ),
    .conv_in_valid    (conv_in_valid    ),
 
    // 2D convolution results per channel
    .conv_2D_dout0    (conv_2D_dout0    ),
    .conv_2D_dout1    (conv_2D_dout1    ),
    .conv_2D_dout2    (conv_2D_dout2    ),
    .conv_2D_dout3    (conv_2D_dout3    ),
 
    // 1D partial sums (packed, all 4 channels)
    .conv1D_dout      (conv1D_dout      ),
 
    // Valid strobes
    .conv_out1D_valid (conv_out1D_valid ),
    .conv_out2D_valid (conv_out2D_valid )
);
// =============================================================================
// Scale_ReLu
// =============================================================================

scale_relu_layer#(
    .SCALE_IN_WIDTH(SCALE_IN_WIDTH),
    .DOUT_WIDTH(DOUT_WIDTH),
    .BIAS_WIDTH(BIAS_WIDTH),
    .SCALE_WIDTH(SCALE_WIDTH)
) u_scale_relu_layer(
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .top_state  (top_state  ),
    .shift_en   (shift_en   ),
    .scale      (scale      ),
    .bias       (bias       ),
    .scale_din  (scale_din  ),
    .scale_dout (scale_dout )
);


// =============================================================================
// MAXPOOL_LAYER
// =============================================================================

// 4-channel pixel inputs to the pooling layer
wire [DIN_WIDTH-1:0]  maxpool_din0;     // channel 0 pixel from upstream
wire [DIN_WIDTH-1:0]  maxpool_din1;     // channel 1 pixel from upstream
wire [DIN_WIDTH-1:0]  maxpool_din2;     // channel 2 pixel from upstream
wire [DIN_WIDTH-1:0]  maxpool_din3;     // channel 3 pixel from upstream

// Shared spatial and control signals produced by the internal control unit

wire                  maxpool_in_valid; // pixel valid strobe
wire [3:0]            pool_en;          // per-channel pool enable, bit[i] -> ch i

// 4-channel pooled outputs
wire [DOUT_WIDTH-1:0] maxpool_dout0;
wire [DOUT_WIDTH-1:0] maxpool_dout1;
wire [DOUT_WIDTH-1:0] maxpool_dout2;
wire [DOUT_WIDTH-1:0] maxpool_dout3;
wire                  maxpool_flag;     // output valid, gated ch-0 flag

maxpool_layer #(
    .DIN_WIDTH  (DIN_WIDTH ),
    .MAX_WIDTH  (MAX_WIDTH ),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_maxpool_layer (
    .clk                (clk              ),
    .rst_n              (rst_n            ),

    // 4-channel pixel inputs from upstream
    .maxpool_din0       (maxpool_din0     ),
    .maxpool_din1       (maxpool_din1     ),
    .maxpool_din2       (maxpool_din2     ),
    .maxpool_din3       (maxpool_din3     ),

    // Shared spatial config
    .img_width          (img_width        ),
    .img_height         (img_height       ),

    // Shared control
    .maxpool_in_valid   (maxpool_in_valid ),
    .pool_en            (pool_en          ),

    // Pooled outputs
    .maxpool_dout0      (maxpool_dout0    ),
    .maxpool_dout1      (maxpool_dout1    ),
    .maxpool_dout2      (maxpool_dout2    ),
    .maxpool_dout3      (maxpool_dout3    ),

    // Global valid flag (sourced from channel 0)
    .maxpool_flag       (maxpool_flag     )
);

// =============================================================================
// DATA_FLOW
// =============================================================================

DATA_FLOW#(
    .NUM(NUM),
    .DIN_WIDTH(DIN_WIDTH),
    .DOUT_WIDTH(DOUT_WIDTH)
) u_DATA_FLOW(
    .clk          (clk          ),
    .rst_n        (rst_n        ),
    .top_state    (top_state    ),
    .din          (din          ),
    .select_dout0 (select_dout0 ),
    .select_dout1 (select_dout1 ),
    .select_dout2 (select_dout2 ),
    .select_dout3 (select_dout3 ),
    .conv_din0    (conv_din0    ),
    .conv_din1    (conv_din1    ),
    .conv_din2    (conv_din2    ),
    .conv_din3    (conv_din3    )
);

CTRL#(
    .SRAM_WIDTH(SRAM_WIDTH),
    .MAX_WIDTH(MAX_WIDTH),
    .DIN_WIDTH(DIN_WIDTH)
) u_CTRL(
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .cnn_start  (cnn_start  ),
    .img_width  (img_width  ),
    .img_height (img_height )
);


endmodule