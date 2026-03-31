`timescale 1ns / 1ps
// =============================================================================
// Module  : DATA_FLOW
// Function: Central data routing crossbar for a multi-layer CNN accelerator.
//           Steers pixel data, conv results, and pooled outputs across layers:
//             · select_din[0..3] : mux raw / SRAM pixels to the window-select unit
//             · conv_din[0..3]   : mux window-select / 1-D / FC data to conv layer
//             · scale_din        : accumulate conv outputs into the BN/scale input
//             · sram_din[0..7]   : route maxpool outputs to the correct SRAM bank
//           All routing decisions are driven by top_state (one-hot FSM).
// =============================================================================
module DATA_FLOW #(
    parameter DIN_WIDTH      = 8,    // Input pixel bit-width
    parameter DOUT_WIDTH     = 8,    // Output / SRAM data bit-width
    parameter SCALE_IN_WIDTH = 20,   // BN/scale accumulator width
    parameter DOUT_WIDTH_1D  = 14,   // 1-D conv partial sum width
    parameter DOUT_WIDTH_2D  = 16,   // 2-D conv accumulated output width
    parameter NUM            = 9     // Kernel elements (3×3)
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // ---- Top-level FSM state (one-hot) -------------------------------------
    input  wire [8:0]                        top_state,

    // ---- Control -----------------------------------------------------------
    input  wire                              maxpool_in_valid,   // maxpool output beat strobe
    input  wire [1:0]                        sram_write_select,  // round-robin SRAM bank select

    // ---- Raw pixel input (LAYER0 only) -------------------------------------
    input  wire [DIN_WIDTH-1:0]              din,

    // ---- Window-select outputs (2-D conv sliding windows) ------------------
    input  wire [DIN_WIDTH*NUM-1:0]          select_dout0,
    input  wire [DIN_WIDTH*NUM-1:0]          select_dout1,
    input  wire [DIN_WIDTH*NUM-1:0]          select_dout2,
    input  wire [DIN_WIDTH*NUM-1:0]          select_dout3,

    // ---- 1-D conv sliding window (8 channels × 3 beats packed) ------------
    input  wire [DOUT_WIDTH*8*3-1:0]         conv1D_select_dout,

    // ---- FC layer input (32 pixels packed) ---------------------------------
    input  wire [32*DOUT_WIDTH-1:0]          fc_din,

    // ---- Conv layer pixel inputs (4 channels × NUM pixels each) -----------
    output reg  [DIN_WIDTH*NUM-1:0]          conv_din0,
    output reg  [DIN_WIDTH*NUM-1:0]          conv_din1,
    output reg  [DIN_WIDTH*NUM-1:0]          conv_din2,
    output reg  [DIN_WIDTH*NUM-1:0]          conv_din3,

    // ---- Window-select pixel inputs (one pixel per channel) ----------------
    output reg  [DIN_WIDTH-1:0]              select_din0,
    output reg  [DIN_WIDTH-1:0]              select_din1,
    output reg  [DIN_WIDTH-1:0]              select_din2,
    output reg  [DIN_WIDTH-1:0]              select_din3,

    // ---- 2-D conv results (from conv_layer) --------------------------------
    input  wire signed [DOUT_WIDTH_2D-1:0]   conv_2D_dout0,
    input  wire signed [DOUT_WIDTH_2D-1:0]   conv_2D_dout1,
    input  wire signed [DOUT_WIDTH_2D-1:0]   conv_2D_dout2,
    input  wire signed [DOUT_WIDTH_2D-1:0]   conv_2D_dout3,

    // ---- 1-D conv partial sums (8 row-sums packed) -------------------------
    input  wire signed [DOUT_WIDTH_1D*3*4-1:0] conv1D_dout,

    // ---- BN / scale accumulator input (4 channels packed) -----------------
    output wire signed [SCALE_IN_WIDTH*4-1:0]  scale_din,

    // ---- 8-bank SRAM read data ---------------------------------------------
    input  wire [DIN_WIDTH-1:0]              sram_dout0,
    input  wire [DIN_WIDTH-1:0]              sram_dout1,
    input  wire [DIN_WIDTH-1:0]              sram_dout2,
    input  wire [DIN_WIDTH-1:0]              sram_dout3,
    input  wire [DIN_WIDTH-1:0]              sram_dout4,
    input  wire [DIN_WIDTH-1:0]              sram_dout5,
    input  wire [DIN_WIDTH-1:0]              sram_dout6,
    input  wire [DIN_WIDTH-1:0]              sram_dout7,

    // ---- Maxpool outputs (4 channels) --------------------------------------
    input  wire [DIN_WIDTH-1:0]              maxpool_dout0,
    input  wire [DIN_WIDTH-1:0]              maxpool_dout1,
    input  wire [DIN_WIDTH-1:0]              maxpool_dout2,
    input  wire [DIN_WIDTH-1:0]              maxpool_dout3,

    // ---- 8-bank SRAM write data --------------------------------------------
    output reg  [DOUT_WIDTH-1:0]             sram_din0,
    output reg  [DOUT_WIDTH-1:0]             sram_din1,
    output reg  [DOUT_WIDTH-1:0]             sram_din2,
    output reg  [DOUT_WIDTH-1:0]             sram_din3,
    output reg  [DOUT_WIDTH-1:0]             sram_din4,
    output reg  [DOUT_WIDTH-1:0]             sram_din5,
    output reg  [DOUT_WIDTH-1:0]             sram_din6,
    output reg  [DOUT_WIDTH-1:0]             sram_din7
);

// =============================================================================
// One-hot FSM state encoding (mirror of top_state)
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
// 1-D conv partial sum unpacking
// conv1D_dout carries 8 row-sums (part0..part7); only the lower 8 × DOUT_WIDTH_1D
// bits are used here.  part0..3 are summed into scale_din_ff[0],
// part4..7 into scale_din_ff[1].
// =============================================================================
wire signed [DOUT_WIDTH_1D-1:0] conv1D_dout_part0, conv1D_dout_part1;
wire signed [DOUT_WIDTH_1D-1:0] conv1D_dout_part2, conv1D_dout_part3;
wire signed [DOUT_WIDTH_1D-1:0] conv1D_dout_part4, conv1D_dout_part5;
wire signed [DOUT_WIDTH_1D-1:0] conv1D_dout_part6, conv1D_dout_part7;

assign {conv1D_dout_part7, conv1D_dout_part6, conv1D_dout_part5, conv1D_dout_part4,
        conv1D_dout_part3, conv1D_dout_part2, conv1D_dout_part1, conv1D_dout_part0}
        = conv1D_dout[DOUT_WIDTH_1D*8-1:0];

// =============================================================================
// scale_din register array & output packing
// Registered on maxpool_in_valid; cleared when valid is deasserted.
// =============================================================================
reg signed [SCALE_IN_WIDTH-1:0] scale_din_ff [0:3];

assign scale_din = {scale_din_ff[3], scale_din_ff[2], scale_din_ff[1], scale_din_ff[0]};

// =============================================================================
// select_din mux (registered)
// Routes one pixel per channel to the upstream window-select unit.
// LAYER0   : ch0 = raw input din; ch1~3 = 0 (single-channel first layer)
// LAYER1   : ch0~3 = SRAM banks 0~3 (ping buffer)
// LAYER2   : ch0~3 = SRAM banks 4~7 (pong buffer)
// LAYER3   : ch0~3 = SRAM banks 0~3 (ping buffer, re-used)
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        select_din0 <= 8'b0;  select_din1 <= 8'b0;
        select_din2 <= 8'b0;  select_din3 <= 8'b0;
    end
    else begin
        case (top_state)
            IDLE: begin
                select_din0 <= 8'b0;  select_din1 <= 8'b0;
                select_din2 <= 8'b0;  select_din3 <= 8'b0;
            end
            LAYER0: begin
                select_din0 <= din;   // single input channel
                select_din1 <= 8'b0;
                select_din2 <= 8'b0;
                select_din3 <= 8'b0;
            end
            LAYER1: begin
                select_din0 <= sram_dout0;   // ping banks 0-3
                select_din1 <= sram_dout1;
                select_din2 <= sram_dout2;
                select_din3 <= sram_dout3;
            end
            LAYER2: begin
                select_din0 <= sram_dout4;   // pong banks 4-7
                select_din1 <= sram_dout5;
                select_din2 <= sram_dout6;
                select_din3 <= sram_dout7;
            end
            LAYER3: begin
                select_din0 <= sram_dout0;   // ping banks 0-3 (reused)
                select_din1 <= sram_dout1;
                select_din2 <= sram_dout2;
                select_din3 <= sram_dout3;
            end
            default: begin
                select_din0 <= 8'b0;  select_din1 <= 8'b0;
                select_din2 <= 8'b0;  select_din3 <= 8'b0;
            end
        endcase
    end
end

// =============================================================================
// conv_din mux (combinational)
// Routes the appropriate 3×3 window to each PE channel.
// LAYER0     : all 4 channels receive the same single-channel window (broadcast)
// LAYER1~3   : independent windows from window-select unit (4 channels)
// LAYER4~5   : 1-D conv windows packed from conv1D_select_dout
//              ch0 = bits [NUM*W-1:0], ch1 = next NUM*W bits,
//              ch2 = remaining 6 bytes zero-padded to 72 bits, ch3 = 0
// LAYER6~7   : FC data, 32 pixels split across 4 PE inputs; ch3 zero-padded
// =============================================================================
always @(*) begin
    case (top_state)
        LAYER0: begin
            // Broadcast single channel to all 4 PEs
            conv_din0 = select_dout0;
            conv_din1 = select_dout0;
            conv_din2 = select_dout0;
            conv_din3 = select_dout0;
        end
        LAYER1, LAYER2, LAYER3: begin
            conv_din0 = select_dout0;
            conv_din1 = select_dout1;
            conv_din2 = select_dout2;
            conv_din3 = select_dout3;
        end
        LAYER4, LAYER5: begin
            // 1-D conv: 3 channels active, ch3 unused
            conv_din0 = conv1D_select_dout[DIN_WIDTH*NUM-1:0];
            conv_din1 = conv1D_select_dout[DIN_WIDTH*NUM*2-1:DIN_WIDTH*NUM];
            conv_din2 = {24'b0, conv1D_select_dout[DIN_WIDTH*8*3-1:DIN_WIDTH*NUM*2]}; // zero-pad to 72b
            conv_din3 = 72'b0;
        end
        LAYER6, LAYER7: begin
            // FC: 32 pixels distributed across 4 PEs; ch3 has 5 pixels, zero-padded
            conv_din0 = fc_din[DIN_WIDTH*NUM-1:0];
            conv_din1 = fc_din[DIN_WIDTH*NUM*2-1:DIN_WIDTH*NUM];
            conv_din2 = fc_din[DIN_WIDTH*NUM*3-1:2*DIN_WIDTH*NUM];
            conv_din3 = {32'b0, fc_din[32*DIN_WIDTH-1:3*DIN_WIDTH*NUM]};  // zero-pad upper bits
        end
        default: begin
            conv_din0 = 72'b0;  conv_din1 = 72'b0;
            conv_din2 = 72'b0;  conv_din3 = 72'b0;
        end
    endcase
end

// =============================================================================
// scale_din accumulation (registered, gated by maxpool_in_valid)
// Accumulates conv results into the BN/scale input on each maxpool beat.
// LAYER0     : 4 independent 2-D outputs (one per channel)
// LAYER1~3   : sum of all 4 channels → ch0 only (single-channel output)
// LAYER4~5   : sum of 1-D part0~3 → ch0; sum of part4~7 → ch1; ch2/3 = 0
// LAYER6~7   : sum of all 4 2-D channels → ch0 only (FC accumulation)
// Cleared to zero when maxpool_in_valid is deasserted.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        scale_din_ff[0] <= 20'b0;  scale_din_ff[1] <= 20'b0;
        scale_din_ff[2] <= 20'b0;  scale_din_ff[3] <= 20'b0;
    end
    else if (maxpool_in_valid) begin
        case (top_state)
            LAYER0: begin
                // 4-channel independent outputs
                scale_din_ff[0] <= conv_2D_dout0;
                scale_din_ff[1] <= conv_2D_dout1;
                scale_din_ff[2] <= conv_2D_dout2;
                scale_din_ff[3] <= conv_2D_dout3;
            end
            LAYER1, LAYER2, LAYER3: begin
                // Fold 4 channels into ch0
                scale_din_ff[0] <= conv_2D_dout0 + conv_2D_dout1
                                  + conv_2D_dout2 + conv_2D_dout3;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER4, LAYER5: begin
                // 1-D: two independent sums (low 4 parts / high 4 parts)
                scale_din_ff[0] <= conv1D_dout_part0 + conv1D_dout_part1
                                  + conv1D_dout_part2 + conv1D_dout_part3;
                scale_din_ff[1] <= conv1D_dout_part4 + conv1D_dout_part5
                                  + conv1D_dout_part6 + conv1D_dout_part7;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER6, LAYER7: begin
                // FC accumulation: fold into ch0
                scale_din_ff[0] <= conv_2D_dout0 + conv_2D_dout1
                                  + conv_2D_dout2 + conv_2D_dout3;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            default: begin
                scale_din_ff[0] <= 20'b0;  scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;  scale_din_ff[3] <= 20'b0;
            end
        endcase
    end
    else begin
        // Clear accumulator between valid beats
        scale_din_ff[0] <= 20'b0;  scale_din_ff[1] <= 20'b0;
        scale_din_ff[2] <= 20'b0;  scale_din_ff[3] <= 20'b0;
    end
end

// =============================================================================
// sram_din routing (registered)
// Routes maxpool outputs to the correct SRAM write bank per layer.
// LAYER0 : ch0~3 → banks 0~3 simultaneously (4-channel first layer write)
// LAYER1 : ch0   → one of banks 4~7, selected by sram_write_select (round-robin)
// LAYER2 : ch0   → one of banks 0~3, selected by sram_write_select (round-robin)
// All unselected banks are held at 0.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        sram_din0 <= 8'b0;  sram_din1 <= 8'b0;
        sram_din2 <= 8'b0;  sram_din3 <= 8'b0;
        sram_din4 <= 8'b0;  sram_din5 <= 8'b0;
        sram_din6 <= 8'b0;  sram_din7 <= 8'b0;
    end
    else begin
        case (top_state)
            IDLE: begin
                sram_din0 <= 8'b0;  sram_din1 <= 8'b0;
                sram_din2 <= 8'b0;  sram_din3 <= 8'b0;
                sram_din4 <= 8'b0;  sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;  sram_din7 <= 8'b0;
            end
            LAYER0: begin
                // All 4 maxpool channels written to banks 0-3 simultaneously
                sram_din0 <= maxpool_dout0;
                sram_din1 <= maxpool_dout1;
                sram_din2 <= maxpool_dout2;
                sram_din3 <= maxpool_dout3;
                sram_din4 <= 8'b0;  sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;  sram_din7 <= 8'b0;
            end
            LAYER1: begin
                // ch0 steered to one of banks 4-7 via round-robin select
                sram_din0 <= 8'b0;  sram_din1 <= 8'b0;
                sram_din2 <= 8'b0;  sram_din3 <= 8'b0;
                case (sram_write_select)
                    2'b00: sram_din4 <= maxpool_dout0;
                    2'b01: sram_din5 <= maxpool_dout0;
                    2'b10: sram_din6 <= maxpool_dout0;
                    2'b11: sram_din7 <= maxpool_dout0;
                    default: begin
                        sram_din4 <= 8'b0;  sram_din5 <= 8'b0;
                        sram_din6 <= 8'b0;  sram_din7 <= 8'b0;
                    end
                endcase
            end
            LAYER2: begin
                // ch0 steered to one of banks 0-3 via round-robin select
                case (sram_write_select)
                    2'b00: sram_din0 <= maxpool_dout0;
                    2'b01: sram_din1 <= maxpool_dout0;
                    2'b10: sram_din2 <= maxpool_dout0;
                    2'b11: sram_din3 <= maxpool_dout0;
                    default: begin
                        sram_din0 <= 8'b0;  sram_din1 <= 8'b0;
                        sram_din2 <= 8'b0;  sram_din3 <= 8'b0;
                    end
                endcase
                sram_din4 <= 8'b0;  sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;  sram_din7 <= 8'b0;
            end
            default: begin
                sram_din0 <= 8'b0;  sram_din1 <= 8'b0;
                sram_din2 <= 8'b0;  sram_din3 <= 8'b0;
                sram_din4 <= 8'b0;  sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;  sram_din7 <= 8'b0;
            end
        endcase
    end
end

endmodule