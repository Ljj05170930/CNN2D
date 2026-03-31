`timescale 1ns / 1ps
// =============================================================================
// Module  : CNN2D
// Function: Full 2-D CNN inference pipeline for the Radar-AI accelerator.
//           Instantiates and wires together all datapath and control sub-modules
//           for an 8-layer (LAYER0~LAYER7) inference sequence:
//
//           LAYER0~3 : 2-D conv → BN/ReLU → maxpool → PINGPONG_RAM (feature maps)
//           LAYER4~5 : 1-D conv on avg-pooled temporal features (via CONV1D_RAM)
//           LAYER6~7 : FC (fully-connected) conv → BN/ReLU → maxpool → output
//
//           Data flow summary:
//             din → DATA_FLOW.select_din → DATA_SELECT (line buffer / 3×3 window)
//                 → DATA_FLOW.conv_din   → conv_layer (4-ch PE array)
//                 → DATA_FLOW.scale_din  → scale_relu_layer (BN + ReLU)
//                 → maxpool_layer        → PINGPONG_RAM (ping-pong feature store)
//             PINGPONG_RAM → DATA_SELECT (LAYER1~3 re-feed)
//             avg_pool → CONV1D_RAM_CTRL → conv1D_data_select → conv_layer (LAYER4~5)
//             FC register file → conv_layer (LAYER6~7)
//
//           Control is centralised in CTRL, which drives the one-hot top_state
//           FSM and generates all address, write-enable, and valid signals.
// =============================================================================
module CNN2D #(
    // ---- Shared pixel data width -------------------------------------------
    parameter DIN_WIDTH      = 8,   // Input pixel bit-width
    parameter DOUT_WIDTH     = 8,   // Output / maxpool data bit-width

    // ---- SRAM configuration ------------------------------------------------
    parameter SRAM_WIDTH     = 10,  // Address width per PINGPONG_RAM bank
    parameter SRAM_NUM       = 8,   // Number of PINGPONG_RAM banks

    // ---- conv_layer / PE datapath widths ------------------------------------
    parameter NUM            = 9,   // Kernel elements (3×3)
    parameter WEIGHT_WIDTH   = 4,   // Weight bit-width (int4)
    parameter MUL_WIDTH      = 12,  // PE multiplier output width
    parameter DOUT_WIDTH_1D  = 14,  // PE row-partial-sum width
    parameter DOUT_WIDTH_2D  = 16,  // PE full 3×3 conv result width

    // ---- BN / scale widths -------------------------------------------------
    parameter BIAS_WIDTH     = 12,  // Bias adder bit-width
    parameter SCALE_WIDTH    = 3,   // Scale right-shift bits
    parameter SCALE_IN_WIDTH = 20,  // Accumulator input width into scale_relu_layer

    // ---- Spatial counter width ---------------------------------------------
    parameter MAX_WIDTH      = 6    // Address/counter width (max image dim = 2^MAX_WIDTH)
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- CNN pipeline arm --------------------------------------------------
    input  wire                   cnn_start,   // Level: held high for full inference window

    // ---- Pixel stream input ------------------------------------------------
    input  wire [DIN_WIDTH-1:0]   din,
    input  wire                   din_valid,

    // ---- Inference result --------------------------------------------------
    output wire [DOUT_WIDTH-1:0]  dout,        // Classification output (channel 0)
    output wire                   dout_valid   // One-cycle pulse: result ready
);

// =============================================================================
// One-hot FSM state encoding (driven by CTRL)
// =============================================================================
localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;  // 1-D conv stage A
localparam LAYER5 = 9'b001000000;  // 1-D conv stage B
localparam LAYER6 = 9'b010000000;  // FC stage
localparam LAYER7 = 9'b100000000;  // Final maxpool / output

// =============================================================================
// Global control wires (from CTRL)
// =============================================================================
wire [8:0]          top_state;          // One-hot current FSM state
wire                state_switch;       // Asserted when next_state changes
wire [6:0]          conv1D_ram_addr0;   // CONV1D_RAM_CTRL write pointer (RAM0)
wire [6:0]          conv1D_ram_addr1;   // CONV1D_RAM_CTRL write pointer (RAM1)
wire [MAX_WIDTH-1:0] img_width;         // Active feature-map width
wire [MAX_WIDTH-1:0] img_height;        // Active feature-map height
wire                select_din_valid;   // Gated valid to DATA_SELECT
wire                state_switch_w;
wire                conv_rs_end;        // Row-sum boundary from DATA_SELECT
wire                conv_end;           // Full conv done from DATA_SELECT
wire                shift_en;           // BN shift strobe
wire                FC_valid;           // FC data valid to conv_layer
wire [4:0]          fc_cnt;             // FC beat counter (shared with CTRL)
wire [1:0]          sram_write_select;  // Round-robin SRAM bank select
wire [3:0]          pool_en;            // Per-channel maxpool enable
wire                conv_mode;          // 0 = 2-D, 1 = 1-D conv mode
wire [6:0]          W_addr;             // Weight ROM address
wire [7:0]          BN_addr;            // BN ROM address
wire [7:0]          ram_we;             // Per-bank PINGPONG_RAM write enable
wire [SRAM_WIDTH*SRAM_NUM-1:0] ram_addr_pack;  // Packed 8-bank address bus
wire [SRAM_WIDTH-1:0] ram_addr [0:7];   // Unpacked per-bank addresses
wire [7:0]          ram_din  [0:7];     // Per-bank write data
wire [7:0]          ram_dout [0:7];     // Per-bank read data
wire                layer5_ready;       // LAYER5 done flag → CTRL
wire                layer6_ready;       // LAYER6 done flag → CTRL

// =============================================================================
// Weight ROM
// Provides one full filter (4 channels × 9 weights × 4 bits = 144 bits) per
// address.  Enabled only while cnn_start is asserted.
// =============================================================================
wire [143:0] W_dout;

Weight_Rom u_Weight_Rom (
    .clka  (clk      ),
    .ena   (cnn_start),
    .addra (W_addr   ),
    .douta (W_dout   )
);

// =============================================================================
// BN ROM
// Stores per-layer bias and scale coefficients packed as
// [scale(SCALE_WIDTH-1:0) | bias(BIAS_WIDTH-1:0)].
// =============================================================================
wire [BIAS_WIDTH+SCALE_WIDTH-1:0] BN_dout;
wire [BIAS_WIDTH-1:0]             bias;
wire [SCALE_WIDTH-1:0]            scale;

BN_Rom u_BN_Rom (
    .clka  (clk      ),
    .ena   (cnn_start),
    .addra (BN_addr  ),
    .douta (BN_dout  )
);

assign bias  = BN_dout[BIAS_WIDTH-1:0];
assign scale = BN_dout[BIAS_WIDTH+SCALE_WIDTH-1:BIAS_WIDTH];

// =============================================================================
// DATA_SELECT
// Maintains 4-channel circular line buffers and assembles 3×3 sliding windows.
// Outputs select_dout0~3 (flattened 9-pixel windows) and data_select_valid.
// =============================================================================
wire [DIN_WIDTH-1:0]     select_din0, select_din1, select_din2, select_din3;
wire [DIN_WIDTH*NUM-1:0] select_dout0, select_dout1, select_dout2, select_dout3;
wire                     data_select_valid;

DATA_SELECT #(
    .DIN_WIDTH  (DIN_WIDTH),
    .DOUT_WIDTH (DIN_WIDTH),   // Window pixel width = input pixel width
    .MAX_WIDTH  (MAX_WIDTH),
    .NUM        (NUM      )
) u_data_select (
    .clk               (clk              ),
    .rst_n             (rst_n            ),
    .cnn_start         (cnn_start        ),
    .select_din0       (select_din0      ),
    .select_din1       (select_din1      ),
    .select_din2       (select_din2      ),
    .select_din3       (select_din3      ),
    .din_valid         (select_din_valid ),
    .state_switch      (state_switch     ),
    .img_width         (img_width        ),
    .img_height        (img_height       ),
    .select_dout0      (select_dout0     ),
    .select_dout1      (select_dout1     ),
    .select_dout2      (select_dout2     ),
    .select_dout3      (select_dout3     ),
    .conv_rs_end       (conv_rs_end      ),
    .conv_end          (conv_end         ),
    .data_select_valid (data_select_valid)
);

// =============================================================================
// conv_in_valid mux
// Routes the appropriate upstream valid strobe to conv_layer based on layer:
//   LAYER0~3 : 2-D sliding window valid from DATA_SELECT
//   LAYER4~5 : 1-D window valid from conv1D_data_select
//   LAYER6~7 : FC valid from FC module
// =============================================================================
wire signed [DOUT_WIDTH_2D-1:0]     conv_2D_dout0, conv_2D_dout1;
wire signed [DOUT_WIDTH_2D-1:0]     conv_2D_dout2, conv_2D_dout3;
wire signed [DOUT_WIDTH_1D*3*4-1:0] conv1D_dout;
wire                                conv_out1D_valid, conv_out2D_valid;
wire                                conv1D_dout_valid;
wire [DIN_WIDTH*NUM-1:0]            conv_din0, conv_din1, conv_din2, conv_din3;
reg                                 conv_in_valid;

always @(*) begin
    case (top_state)
        LAYER0, LAYER1, LAYER2, LAYER3: conv_in_valid = data_select_valid;
        LAYER4, LAYER5:                 conv_in_valid = conv1D_dout_valid;
        LAYER6, LAYER7:                 conv_in_valid = FC_valid;
        default:                        conv_in_valid = 1'b0;
    endcase
end

// =============================================================================
// conv_layer
// 4-channel parallel PE array.  Receives windowed pixels, weights, and control;
// produces 2-D full conv results (conv_2D_dout*) and 1-D partial sums (conv1D_dout).
// =============================================================================
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
    .conv_din0        (conv_din0        ),
    .conv_din1        (conv_din1        ),
    .conv_din2        (conv_din2        ),
    .conv_din3        (conv_din3        ),
    .weight           (W_dout           ),
    .conv_mode        (conv_mode        ),
    .conv_in_valid    (conv_in_valid    ),
    .conv_2D_dout0    (conv_2D_dout0    ),
    .conv_2D_dout1    (conv_2D_dout1    ),
    .conv_2D_dout2    (conv_2D_dout2    ),
    .conv_2D_dout3    (conv_2D_dout3    ),
    .conv1D_dout      (conv1D_dout      ),
    .conv_out1D_valid (conv_out1D_valid ),
    .conv_out2D_valid (conv_out2D_valid )
);

// =============================================================================
// scale_relu_layer
// 4-channel BN (bias + right-shift scale) followed by ReLU.
// dout_finial exposes channel-0 for single-channel output layers.
// =============================================================================
wire [SCALE_IN_WIDTH*4-1:0] scale_din;
wire [DOUT_WIDTH*4-1:0]     scale_dout;
wire [DIN_WIDTH-1:0]        dout_finial;

scale_relu_layer #(
    .SCALE_IN_WIDTH (SCALE_IN_WIDTH),
    .DOUT_WIDTH     (DOUT_WIDTH    ),
    .BIAS_WIDTH     (BIAS_WIDTH    ),
    .SCALE_WIDTH    (SCALE_WIDTH   )
) u_scale_relu_layer (
    .clk         (clk        ),
    .rst_n       (rst_n      ),
    .top_state   (top_state  ),
    .shift_en    (shift_en   ),
    .scale       (scale      ),
    .bias        (bias       ),
    .dout_finial (dout_finial),
    .scale_din   (scale_din  ),
    .scale_dout  (scale_dout )
);

// =============================================================================
// maxpool_in_valid mux & pipeline register
// Routes the appropriate conv valid strobe to maxpool_layer:
//   LAYER0~3, 6~7 : 2-D conv output valid
//   LAYER4~5      : 1-D conv output valid
// maxpool_valid_ff is a 1-cycle delayed copy used for:
//   · Rising-edge detection (maxpool_valid_rise → CTRL)
//   · FC beat strobe (maxpool_valid_ff → FC)
//   · LAYER7 dout_valid gate
// =============================================================================
reg maxpool_in_valid;
reg maxpool_valid_ff;

always @(*) begin
    case (top_state)
        LAYER0, LAYER1, LAYER2, LAYER3,
        LAYER6, LAYER7: maxpool_in_valid = conv_out2D_valid;
        LAYER4, LAYER5: maxpool_in_valid = conv_out1D_valid;
        default:        maxpool_in_valid = 1'b0;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  maxpool_valid_ff <= 1'b0;
    else         maxpool_valid_ff <= maxpool_in_valid;
end

// Rising edge of maxpool_in_valid: used by CTRL for W_addr / BN_addr advance
wire maxpool_valid_rise;
assign maxpool_valid_rise = !maxpool_in_valid && maxpool_valid_ff;

// =============================================================================
// maxpool_layer input unpacking (from scale_dout)
// =============================================================================
wire [DIN_WIDTH-1:0] maxpool_din0, maxpool_din1, maxpool_din2, maxpool_din3;
wire [DIN_WIDTH-1:0] maxpool_dout0, maxpool_dout1, maxpool_dout2, maxpool_dout3;
wire                 maxpool_flag;

assign maxpool_din0 = scale_dout[DOUT_WIDTH-1:0];
assign maxpool_din1 = scale_dout[DOUT_WIDTH*2-1:DOUT_WIDTH];
assign maxpool_din2 = scale_dout[DOUT_WIDTH*3-1:DOUT_WIDTH*2];
assign maxpool_din3 = scale_dout[DOUT_WIDTH*4-1:DOUT_WIDTH*3];

// =============================================================================
// maxpool_layer
// 4-channel parallel 2×2 max-pooling.  pool_en gates individual channels.
// maxpool_flag (= ch-0 valid) is used as the global write strobe to CTRL/SRAMs.
// =============================================================================
maxpool_layer #(
    .DIN_WIDTH  (DIN_WIDTH ),
    .MAX_WIDTH  (MAX_WIDTH ),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_maxpool_layer (
    .clk              (clk             ),
    .rst_n            (rst_n           ),
    .maxpool_din0     (maxpool_din0    ),
    .maxpool_din1     (maxpool_din1    ),
    .maxpool_din2     (maxpool_din2    ),
    .maxpool_din3     (maxpool_din3    ),
    .img_width        (img_width       ),
    .img_height       (img_height      ),
    .maxpool_in_valid (maxpool_valid_ff),  // 1-cycle delayed to align with scale_dout
    .pool_en          (pool_en         ),
    .maxpool_dout0    (maxpool_dout0   ),
    .maxpool_dout1    (maxpool_dout1   ),
    .maxpool_dout2    (maxpool_dout2   ),
    .maxpool_dout3    (maxpool_dout3   ),
    .maxpool_flag     (maxpool_flag    )
);

// 2-channel packed maxpool output for CONV1D_RAM_CTRL
wire [DIN_WIDTH*2-1:0] maxpool_dout_2channel;
assign maxpool_dout_2channel = {maxpool_dout1, maxpool_dout0};

// =============================================================================
// dout / dout_valid
// dout_valid is asserted when LAYER7 is active and maxpool_valid_ff fires.
// dout carries the channel-0 BN/ReLU output (classification score).
// =============================================================================
assign dout_valid = maxpool_valid_ff && (top_state == LAYER7);
assign dout       = dout_valid ? dout_finial : 8'b0;

// =============================================================================
// DATA_FLOW
// Central routing crossbar: steers select_din, conv_din, scale_din, and
// sram_din[0..7] based on top_state.  Also accumulates conv outputs into
// the scale_din bus for BN input.
// =============================================================================
wire [32*DOUT_WIDTH-1:0]   fc_din;
wire [DOUT_WIDTH*8*3-1:0]  conv1D_select_dout;

DATA_FLOW #(
    .NUM            (NUM            ),
    .DIN_WIDTH      (DIN_WIDTH      ),
    .DOUT_WIDTH     (DOUT_WIDTH     ),
    .SCALE_IN_WIDTH (SCALE_IN_WIDTH ),
    .DOUT_WIDTH_1D  (DOUT_WIDTH_1D  ),
    .DOUT_WIDTH_2D  (DOUT_WIDTH_2D  )
) u_DATA_FLOW (
    .clk               (clk               ),
    .rst_n             (rst_n             ),
    .top_state         (top_state         ),
    .maxpool_in_valid  (maxpool_in_valid  ),
    .din               (din               ),
    .sram_write_select (sram_write_select ),
    .select_dout0      (select_dout0      ),
    .select_dout1      (select_dout1      ),
    .select_dout2      (select_dout2      ),
    .select_dout3      (select_dout3      ),
    .conv1D_select_dout(conv1D_select_dout),
    .fc_din            (fc_din            ),
    .conv_din0         (conv_din0         ),
    .conv_din1         (conv_din1         ),
    .conv_din2         (conv_din2         ),
    .conv_din3         (conv_din3         ),
    .select_din0       (select_din0       ),
    .select_din1       (select_din1       ),
    .select_din2       (select_din2       ),
    .select_din3       (select_din3       ),
    .conv_2D_dout0     (conv_2D_dout0     ),
    .conv_2D_dout1     (conv_2D_dout1     ),
    .conv_2D_dout2     (conv_2D_dout2     ),
    .conv_2D_dout3     (conv_2D_dout3     ),
    .conv1D_dout       (conv1D_dout       ),
    .scale_din         (scale_din         ),
    .sram_dout0        (ram_dout[0]       ),
    .sram_dout1        (ram_dout[1]       ),
    .sram_dout2        (ram_dout[2]       ),
    .sram_dout3        (ram_dout[3]       ),
    .sram_dout4        (ram_dout[4]       ),
    .sram_dout5        (ram_dout[5]       ),
    .sram_dout6        (ram_dout[6]       ),
    .sram_dout7        (ram_dout[7]       ),
    .maxpool_dout0     (maxpool_dout0     ),
    .maxpool_dout1     (maxpool_dout1     ),
    .maxpool_dout2     (maxpool_dout2     ),
    .maxpool_dout3     (maxpool_dout3     ),
    .sram_din0         (ram_din[0]        ),
    .sram_din1         (ram_din[1]        ),
    .sram_din2         (ram_din[2]        ),
    .sram_din3         (ram_din[3]        ),
    .sram_din4         (ram_din[4]        ),
    .sram_din5         (ram_din[5]        ),
    .sram_din6         (ram_din[6]        ),
    .sram_din7         (ram_din[7]        )
);

// Unpack CTRL's packed address bus into per-bank array
generate
    genvar i;
    for (i = 0; i < 8; i = i + 1) begin : gen_ram_addr_unpack
        assign ram_addr[i] = ram_addr_pack[i*SRAM_WIDTH +: SRAM_WIDTH];
    end
endgenerate

// =============================================================================
// CTRL
// Centralised sequencer: drives top_state FSM, all address buses, write
// enables, spatial config, and valid signals for every sub-module.
// =============================================================================
CTRL #(
    .SRAM_WIDTH (SRAM_WIDTH),
    .MAX_WIDTH  (MAX_WIDTH ),
    .SRAM_NUM   (SRAM_NUM  ),
    .DIN_WIDTH  (DIN_WIDTH )
) u_CTRL (
    .clk                (clk               ),
    .rst_n              (rst_n             ),
    .cnn_start          (cnn_start         ),
    .din_valid          (din_valid         ),
    .conv_rs_end        (conv_rs_end       ),
    .conv_end           (conv_end          ),
    .fc_cnt             (fc_cnt            ),
    .layer5_ready       (layer5_ready      ),
    .layer6_ready       (layer6_ready      ),
    .maxpool_valid_rise (maxpool_valid_rise),
    .maxpool_flag       (maxpool_flag      ),
    .conv1D_ram_addr0   (conv1D_ram_addr0  ),
    .conv1D_ram_addr1   (conv1D_ram_addr1  ),
    .top_state          (top_state         ),
    .state_switch       (state_switch      ),
    .img_width          (img_width         ),
    .img_height         (img_height        ),
    .W_addr             (W_addr            ),
    .BN_addr            (BN_addr           ),
    .FC_valid           (FC_valid          ),
    .shift_en           (shift_en          ),
    .ram_we             (ram_we            ),
    .ram_addr           (ram_addr_pack     ),
    .sram_write_select  (sram_write_select ),
    .select_din_valid   (select_din_valid  ),
    .pool_en            (pool_en           ),
    .conv_mode          (conv_mode         )
);

// =============================================================================
// avg_pool
// LAYER3 : averages maxpool_dout0 across a 7×6 spatial region to produce a
//          single avg_pool_dout byte per beat → written to CONV1D_RAM0.
// LAYER5 : averages two scale_dout channels to produce avg_pool_cov1D_dout
//          (16-bit, 2 bytes packed) → written to FC register file.
// =============================================================================
wire [DOUT_WIDTH-1:0]   avg_pool_din0, avg_pool_din1;
wire                    avg_din_valid;
wire [DOUT_WIDTH*2-1:0] avg_pool_cov1D_dout;
wire                    avg_dout_cov1D_valid;
wire [DOUT_WIDTH-1:0]   avg_pool_dout;
wire                    avg_dout_valid;

assign avg_pool_din0 = (top_state == LAYER3) ? maxpool_dout0
                                             : scale_dout[DOUT_WIDTH-1:0];
assign avg_pool_din1 = (top_state == LAYER3) ? 8'b0
                                             : scale_dout[DOUT_WIDTH*2-1:DOUT_WIDTH];
assign avg_din_valid = (top_state == LAYER3 && maxpool_flag)
                     || (maxpool_in_valid   && top_state == LAYER5);

avg_pool #(
    .DIN_WIDTH  (DIN_WIDTH ),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_avg_pool (
    .clk                  (clk                 ),
    .rst_n                (rst_n               ),
    .top_state            (top_state           ),
    .avg_pool_din0        (avg_pool_din0       ),
    .avg_pool_din1        (avg_pool_din1       ),
    .avg_din_valid        (avg_din_valid       ),
    .avg_pool_dout        (avg_pool_dout       ),
    .avg_pool_cov1D_dout  (avg_pool_cov1D_dout ),
    .avg_dout_cov1D_valid (avg_dout_cov1D_valid),
    .avg_dout_valid       (avg_dout_valid      )
);

// =============================================================================
// CONV1D_RAM_CTRL
// Manages two single-port RAMs that stage feature maps for 1-D conv:
//   RAM0 ← avg_pool_dout   (LAYER3 writes, LAYER4 reads)
//   RAM1 ← maxpool_dout_2channel + buffered rows (LAYER4 writes, LAYER5 reads)
// Outputs conv1D_din_valid and ram_out (4-pixel packed) to conv1D_data_select.
// =============================================================================
wire [DIN_WIDTH*4-1:0] ram_out;
wire                   conv1D_din_valid;
wire                   control;

CONV1D_RAM_CTRL u_CONV1D_RAM_CTRL (
    .clk                  (clk                 ),
    .rst_n                (rst_n               ),
    .cnn_start            (cnn_start           ),
    .top_state            (top_state           ),
    .control              (control             ),
    .avg_dout_valid       (avg_dout_valid      ),
    .avg_pool_dout        (avg_pool_dout       ),
    .maxpool_flag         (maxpool_flag        ),
    .maxpool_dout_2channel(maxpool_dout_2channel),
    .conv1D_ram_addr0     (conv1D_ram_addr0    ),
    .conv1D_ram_addr1     (conv1D_ram_addr1    ),
    .conv1D_din_valid     (conv1D_din_valid    ),
    .ram_out              (ram_out             )
);

// =============================================================================
// FC
// Ping-pong register file:
//   fc_rem0 ← avg_pool_cov1D_dout (LAYER5, 16 beats × 2 bytes)
//   fc_rem1 ← maxpool_dout0       (LAYER6, 32 beats × 1 byte)
// Outputs packed fc_din (32 bytes) to DATA_FLOW for LAYER6/7 conv_din routing.
// =============================================================================
FC #(
    .DIN_WIDTH (DIN_WIDTH),
    .NUM       (NUM      )
) u_FC (
    .clk                  (clk                 ),
    .rst_n                (rst_n               ),
    .top_state            (top_state           ),
    .maxpool_valid_ff     (maxpool_valid_ff    ),
    .FC_din               (maxpool_din0        ),  // serial FC input from maxpool ch0
    .avg_dout_cov1D_valid (avg_dout_cov1D_valid),
    .avg_pool_cov1D_dout  (avg_pool_cov1D_dout ),
    .fc_cnt               (fc_cnt              ),
    .layer5_ready         (layer5_ready        ),
    .layer6_ready         (layer6_ready        ),
    .fc_din               (fc_din              )
);

// =============================================================================
// conv1D_data_select
// 3-beat sliding window buffer for 1-D conv input.  Reads 4-pixel-wide ram_out,
// accumulates 3 consecutive beats, and outputs 8-channel × 3-beat packed window
// (conv1D_select_dout) to DATA_FLOW for LAYER4/5 conv_din routing.
// =============================================================================
conv1D_data_select #(
    .DIN_WIDTH  (DIN_WIDTH ),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_conv1D_data_select (
    .clk                (clk                ),
    .rst_n              (rst_n              ),
    .top_state          (top_state          ),
    .conv1D_din_valid   (conv1D_din_valid   ),
    .ram_out            (ram_out            ),
    .control            (control            ),
    .conv1D_select_dout (conv1D_select_dout ),
    .conv1D_dout_valid  (conv1D_dout_valid  )
);

// =============================================================================
// PINGPONG_RAM × 8
// 8 independent single-port BRAMs organised as a ping-pong feature-map store.
// Banks 0~3 and 4~7 alternate between read and write roles each layer pair
// (LAYER0/1 → LAYER1/2 → LAYER2/3) under CTRL's address and write-enable steering.
// =============================================================================
PINGPONG_RAM u_PINGPONG_RAM0 (.clka(clk), .ena(cnn_start), .wea(ram_we[0]), .addra(ram_addr[0]), .dina(ram_din[0]), .douta(ram_dout[0]));
PINGPONG_RAM u_PINGPONG_RAM1 (.clka(clk), .ena(cnn_start), .wea(ram_we[1]), .addra(ram_addr[1]), .dina(ram_din[1]), .douta(ram_dout[1]));
PINGPONG_RAM u_PINGPONG_RAM2 (.clka(clk), .ena(cnn_start), .wea(ram_we[2]), .addra(ram_addr[2]), .dina(ram_din[2]), .douta(ram_dout[2]));
PINGPONG_RAM u_PINGPONG_RAM3 (.clka(clk), .ena(cnn_start), .wea(ram_we[3]), .addra(ram_addr[3]), .dina(ram_din[3]), .douta(ram_dout[3]));
PINGPONG_RAM u_PINGPONG_RAM4 (.clka(clk), .ena(cnn_start), .wea(ram_we[4]), .addra(ram_addr[4]), .dina(ram_din[4]), .douta(ram_dout[4]));
PINGPONG_RAM u_PINGPONG_RAM5 (.clka(clk), .ena(cnn_start), .wea(ram_we[5]), .addra(ram_addr[5]), .dina(ram_din[5]), .douta(ram_dout[5]));
PINGPONG_RAM u_PINGPONG_RAM6 (.clka(clk), .ena(cnn_start), .wea(ram_we[6]), .addra(ram_addr[6]), .dina(ram_din[6]), .douta(ram_dout[6]));
PINGPONG_RAM u_PINGPONG_RAM7 (.clka(clk), .ena(cnn_start), .wea(ram_we[7]), .addra(ram_addr[7]), .dina(ram_din[7]), .douta(ram_dout[7]));

endmodule