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
    parameter SRAM_NUM      = 8,
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
wire state_switch;
wire [6:0] conv1D_ram_addr0;
wire [6:0] conv1D_ram_addr1;
// =============================================================================
// Weight_Rom
// =============================================================================
wire [6:0]   W_addr;
wire [143:0] W_dout;
reg  maxpool_in_valid; // pixel valid strobe
reg  maxpool_valid_ff;
wire [DIN_WIDTH-1:0]  maxpool_din0;     // channel 0 pixel from upstream
wire [DIN_WIDTH-1:0]  dout_finial;

assign dout_valid = maxpool_valid_ff && top_state == LAYER7;
assign dout = dout_valid ? dout_finial : 8'b0;

Weight_Rom u_Weight_Rom(
    .clka  (clk      ),
    .ena   (cnn_start),
    .addra (W_addr   ),
    .douta (W_dout   )
);

// =============================================================================
// BN_Rom
// =============================================================================
wire [7:0]   BN_addr;
wire [BIAS_WIDTH + SCALE_WIDTH-1:0] BN_dout;
wire [BIAS_WIDTH-1:0]  bias;
wire [SCALE_WIDTH-1:0] scale;
BN_Rom u_BN_Rom(
    .clka  (clk      ),
    .ena   (cnn_start),
    .addra (BN_addr  ),
    .douta (BN_dout   )
);

assign bias  = BN_dout[BIAS_WIDTH-1:0];
assign scale = BN_dout[BIAS_WIDTH + SCALE_WIDTH-1:BIAS_WIDTH]; 
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

wire [DIN_WIDTH*NUM-1:0] select_dout0;
wire [DIN_WIDTH*NUM-1:0] select_dout1;
wire [DIN_WIDTH*NUM-1:0] select_dout2;
wire [DIN_WIDTH*NUM-1:0] select_dout3;

wire data_select_valid;
wire conv_rs_end;
wire conv_end;
wire [MAX_WIDTH-1:0]  img_width;        // active feature-map width
wire [MAX_WIDTH-1:0]  img_height;       // active feature-map height
wire select_din_valid;
wire select_valid_ff0;

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
    .din_valid         (select_din_valid  ),
    .state_switch      (state_switch      ),
    .img_width         (img_width         ),
    .img_height        (img_height        ),

    // 3×3 flattened window outputs → connect directly to conv_layer inputs
    .select_dout0      (select_dout0      ),
    .select_dout1      (select_dout1      ),
    .select_dout2      (select_dout2      ),
    .select_dout3      (select_dout3      ),

    // Window-valid strobe → gates conv_layer input
    .conv_rs_end       (conv_rs_end       ),
    .conv_end          (conv_end          ),
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
reg                                   conv_in_valid;    // pixel window is valid

// conv_layer outputs
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout0;
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout1;
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout2;
wire signed [DOUT_WIDTH_2D-1:0]       conv_2D_dout3;
wire signed [DOUT_WIDTH_1D*3*4-1:0]   conv1D_dout;
wire                                  conv_out1D_valid;
wire                                  conv_out2D_valid;
wire                                  conv1D_dout_valid;
wire                                  FC_valid;
always @(*) begin
    conv_in_valid = 1'b0;
    begin
        case (top_state)
            LAYER0: conv_in_valid = data_select_valid;
            LAYER1: conv_in_valid = data_select_valid;
            LAYER2: conv_in_valid = data_select_valid;
            LAYER3: conv_in_valid = data_select_valid;
            LAYER4: conv_in_valid = conv1D_dout_valid;
            LAYER5: conv_in_valid = conv1D_dout_valid;
            LAYER6: conv_in_valid = FC_valid;
            LAYER7: conv_in_valid = FC_valid;
            default: begin
                conv_in_valid = 1'b0;
            end
        endcase
    end
end

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
wire shift_en;
wire [SCALE_IN_WIDTH*4-1:0] scale_din;
wire [DOUT_WIDTH*4-1:0]     scale_dout;

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
    .dout_finial(dout_finial),
    .scale_din  (scale_din  ),
    .scale_dout (scale_dout )
);


// =============================================================================
// MAXPOOL_LAYER
// =============================================================================

// 4-channel pixel inputs to the pooling layer

wire [DIN_WIDTH-1:0]  maxpool_din1;     // channel 1 pixel from upstream
wire [DIN_WIDTH-1:0]  maxpool_din2;     // channel 2 pixel from upstream
wire [DIN_WIDTH-1:0]  maxpool_din3;     // channel 3 pixel from upstream

// Shared spatial and control signals produced by the internal control unit


wire                  maxpool_valid_rise;

wire [3:0]            pool_en;          // per-channel pool enable, bit[i] -> ch i

// 4-channel pooled outputs
wire [DOUT_WIDTH-1:0] maxpool_dout0;
wire [DOUT_WIDTH-1:0] maxpool_dout1;
wire [DOUT_WIDTH-1:0] maxpool_dout2;
wire [DOUT_WIDTH-1:0] maxpool_dout3;
wire                  maxpool_flag;     // output valid, gated ch-0 flag

always @(*) begin
    maxpool_in_valid = 1'b0;
    case (top_state)
        LAYER0: maxpool_in_valid = conv_out2D_valid;
        LAYER1: maxpool_in_valid = conv_out2D_valid;
        LAYER2: maxpool_in_valid = conv_out2D_valid;
        LAYER3: maxpool_in_valid = conv_out2D_valid;
        LAYER4: maxpool_in_valid = conv_out1D_valid;
        LAYER5: maxpool_in_valid = conv_out1D_valid;
        LAYER6: maxpool_in_valid = conv_out2D_valid;  
        LAYER7: maxpool_in_valid = conv_out2D_valid;  
        default: begin
            maxpool_in_valid = 1'b0;
        end
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        maxpool_valid_ff <= 1'b0;
    end
    else begin
        maxpool_valid_ff <= maxpool_in_valid;
    end
end

assign maxpool_valid_rise = !maxpool_in_valid && maxpool_valid_ff;

assign maxpool_din0 = scale_dout[DOUT_WIDTH-1:0];
assign maxpool_din1 = scale_dout[DOUT_WIDTH*2-1:DOUT_WIDTH];
assign maxpool_din2 = scale_dout[DOUT_WIDTH*3-1:DOUT_WIDTH*2];
assign maxpool_din3 = scale_dout[DOUT_WIDTH*4-1:DOUT_WIDTH*3];

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
    .maxpool_in_valid   (maxpool_valid_ff ),
    .pool_en            (pool_en          ),

    // Pooled outputs
    .maxpool_dout0      (maxpool_dout0    ),
    .maxpool_dout1      (maxpool_dout1    ),
    .maxpool_dout2      (maxpool_dout2    ),
    .maxpool_dout3      (maxpool_dout3    ),

    // Global valid flag (sourced from channel 0)
    .maxpool_flag       (maxpool_flag     )
);

wire [7:0] maxpool_dout_all [0:3];
assign maxpool_dout_all[0] = maxpool_dout0;
assign maxpool_dout_all[1] = maxpool_dout1;
assign maxpool_dout_all[2] = maxpool_dout2;
assign maxpool_dout_all[3] = maxpool_dout3;

wire [DIN_WIDTH*2-1:0] maxpool_dout_2channel;
assign maxpool_dout_2channel = {maxpool_dout1,maxpool_dout0};
// =============================================================================
// DATA_FLOW
// =============================================================================
wire [1:0] sram_write_select;
// wire [7:0] ram_en;
wire [7:0] ram_we;
wire [9:0] ram_addr [0:7];
wire [7:0] ram_din  [0:7];
wire [7:0] ram_dout [0:7];
wire [SRAM_WIDTH*SRAM_NUM-1:0] ram_addr_pack;
wire [32*DOUT_WIDTH-1:0]       fc_din;
wire [DOUT_WIDTH*8*3-1:0] conv1D_select_dout;
wire control;
wire layer5_ready;
wire layer6_ready;
wire [4:0] fc_cnt;

DATA_FLOW#(
    .NUM(NUM),
    .DIN_WIDTH(DIN_WIDTH),
    .DOUT_WIDTH(DOUT_WIDTH),
    .SCALE_IN_WIDTH(SCALE_IN_WIDTH),
    .DOUT_WIDTH_1D(DOUT_WIDTH_1D),
    .DOUT_WIDTH_2D(DOUT_WIDTH_2D)
) u_DATA_FLOW(
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

generate
    genvar i;
    for (i = 0;i < 8;i = i + 1) begin
        assign ram_addr[i] = ram_addr_pack[i*SRAM_WIDTH+:SRAM_WIDTH];
    end
endgenerate


CTRL#(
    .SRAM_WIDTH(SRAM_WIDTH),
    .MAX_WIDTH(MAX_WIDTH),
    .SRAM_NUM(SRAM_NUM),
    .DIN_WIDTH(DIN_WIDTH)
) u_CTRL(
    .clk                (clk                ),
    .rst_n              (rst_n              ),
    .cnn_start          (cnn_start          ),
    .din_valid          (din_valid          ),
    .conv_rs_end        (conv_rs_end        ),
    .conv_end           (conv_end           ),
    .fc_cnt             (fc_cnt             ),
    .layer5_ready       (layer5_ready       ),
    .layer6_ready       (layer6_ready       ),
    .maxpool_valid_rise (maxpool_valid_rise ),
    .maxpool_flag       (maxpool_flag       ),
    .conv1D_ram_addr0   (conv1D_ram_addr0   ),
    .conv1D_ram_addr1   (conv1D_ram_addr1   ),
    .top_state          (top_state          ),
    .state_switch       (state_switch       ),
    .img_width          (img_width          ),
    .img_height         (img_height         ),
    .W_addr             (W_addr             ),
    .BN_addr            (BN_addr            ), 
    .FC_valid           (FC_valid           ),
    .shift_en           (shift_en           ),
    .ram_we             (ram_we             ),
    .ram_addr           (ram_addr_pack      ),
    .sram_write_select  (sram_write_select  ),
    .select_din_valid   (select_din_valid   ),
    .pool_en            (pool_en            ),
    .conv_mode          (conv_mode          )
);

wire [DOUT_WIDTH-1:0]       avg_pool_din0;
wire [DOUT_WIDTH-1:0]       avg_pool_din1;
wire                        avg_din_valid;
wire [DOUT_WIDTH*2-1:0]     avg_pool_cov1D_dout;
wire                        avg_dout_cov1D_valid;
wire [DOUT_WIDTH-1:0]       avg_pool_dout;
wire                        avg_dout_valid;


assign avg_pool_din0 = top_state == LAYER3 ?  maxpool_dout0 : scale_dout[DOUT_WIDTH-1:0];
assign avg_pool_din1 = top_state == LAYER3 ?  8'b0          : scale_dout[DOUT_WIDTH*2-1:DOUT_WIDTH];
assign avg_din_valid = (top_state == LAYER3 && maxpool_flag) || (maxpool_in_valid && top_state == LAYER5);

avg_pool#(
   .DIN_WIDTH (DIN_WIDTH),
   .DOUT_WIDTH(DOUT_WIDTH) 
)u_avg_pool(
    .clk                  (clk            ),
    .rst_n                (rst_n          ),
    .top_state            (top_state      ),
    .avg_pool_din0        (avg_pool_din0  ),
    .avg_pool_din1        (avg_pool_din1  ),
    .avg_din_valid        (avg_din_valid  ),
    .avg_pool_dout        (avg_pool_dout  ),
    .avg_pool_cov1D_dout  (avg_pool_cov1D_dout ),
    .avg_dout_cov1D_valid (avg_dout_cov1D_valid ),
    .avg_dout_valid       (avg_dout_valid )
);

wire [DIN_WIDTH*4-1:0]                ram_out;
wire conv1D_din_valid;

CONV1D_RAM_CTRL u_CONV1D_RAM_CTRL(
    .clk             (clk             ),
    .rst_n           (rst_n           ),
    .cnn_start       (cnn_start       ),
    .top_state       (top_state       ),
    .control         (control         ),
    .avg_dout_valid  (avg_dout_valid  ),
    .avg_pool_dout   (avg_pool_dout   ),
    .maxpool_flag    (maxpool_flag    ),
    .maxpool_dout_2channel(maxpool_dout_2channel),
    .conv1D_ram_addr0(conv1D_ram_addr0),
    .conv1D_ram_addr1(conv1D_ram_addr1),
    .conv1D_din_valid(conv1D_din_valid),
    .ram_out         (ram_out         )
);

FC#(
    .DIN_WIDTH(DIN_WIDTH),
    .NUM(NUM)
) u_FC(
    .clk                  (clk                  ),
    .rst_n                (rst_n                ),
    .top_state            (top_state            ),
    .maxpool_valid_ff     (maxpool_valid_ff     ),
    .FC_din               (maxpool_din0         ),
    .avg_dout_cov1D_valid (avg_dout_cov1D_valid ),
    .avg_pool_cov1D_dout  (avg_pool_cov1D_dout  ),
    .fc_cnt               (fc_cnt               ),
    .layer5_ready         (layer5_ready         ),  
    .layer6_ready         (layer6_ready         ), 
    .fc_din               (fc_din               )
);

conv1D_data_select#(
    .DIN_WIDTH (DIN_WIDTH ),
    .DOUT_WIDTH(DOUT_WIDTH)
)u_conv1D_data_select(
    .clk                (clk                ),
    .rst_n              (rst_n              ),
    .top_state          (top_state          ),
    .conv1D_din_valid   (conv1D_din_valid   ),
    .ram_out            (ram_out            ),
    .control            (control            ),
    .conv1D_select_dout (conv1D_select_dout ),
    .conv1D_dout_valid  (conv1D_dout_valid  )
);

PINGPONG_RAM u_PINGPONG_RAM0(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [0] ),
    .addra (ram_addr[0] ),
    .dina  (ram_din [0] ),
    .douta (ram_dout[0] )
);

PINGPONG_RAM u_PINGPONG_RAM1(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [1] ),
    .addra (ram_addr[1] ),
    .dina  (ram_din [1] ),
    .douta (ram_dout[1] )
);

PINGPONG_RAM u_PINGPONG_RAM2(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [2] ),
    .addra (ram_addr[2] ),
    .dina  (ram_din [2] ),
    .douta (ram_dout[2] )
);

PINGPONG_RAM u_PINGPONG_RAM3(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [3] ),
    .addra (ram_addr[3] ),
    .dina  (ram_din [3] ),
    .douta (ram_dout[3] )
);

PINGPONG_RAM u_PINGPONG_RAM4(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [4] ),
    .addra (ram_addr[4] ),
    .dina  (ram_din [4] ),
    .douta (ram_dout[4] )
);

PINGPONG_RAM u_PINGPONG_RAM5(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [5] ),
    .addra (ram_addr[5] ),
    .dina  (ram_din [5] ),
    .douta (ram_dout[5] )
);

PINGPONG_RAM u_PINGPONG_RAM6(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [6] ),
    .addra (ram_addr[6] ),
    .dina  (ram_din [6] ),
    .douta (ram_dout[6] )
);

PINGPONG_RAM u_PINGPONG_RAM7(
    .clka  (clk         ),
    .ena   (cnn_start   ),
    .wea   (ram_we  [7] ),
    .addra (ram_addr[7] ),
    .dina  (ram_din [7] ),
    .douta (ram_dout[7] )
);



endmodule