`timescale 1ns / 1ps
// =============================================================================
// Module  : scale_relu_layer
// Function: 4-channel parallel BN-scale + ReLU wrapper.
//           Holds per-channel bias/scale coefficient registers (bias_reg /
//           scale_reg) and feeds them into 4 independent scale_relu instances.
//           Coefficient loading strategy varies by layer:
//             · LAYER0     : shift-register chain (4-deep); new coeff enters [3]
//                            and ripples toward [0] on each shift_en beat.
//             · LAYER4/5   : 2-entry shift (shift_en delayed by 1); new coeff
//                            enters [1], [0] is the active output channel.
//             · LAYER1~3, 6~7: broadcast — all 4 entries loaded with the same
//                            bias/scale every cycle.
//           dout_finial exposes channel-0 output for single-channel layers.
// =============================================================================
module scale_relu_layer #(
    parameter SCALE_IN_WIDTH = 20,  // Accumulator input width from DATA_FLOW
    parameter DOUT_WIDTH     = 8,   // Output pixel bit-width after ReLU
    parameter BIAS_WIDTH     = 12,  // Bias coefficient bit-width
    parameter SCALE_WIDTH    = 3    // Scale (right-shift amount) bit-width
) (
    input  wire                               clk,
    input  wire                               rst_n,

    // ---- Top-level FSM state (one-hot) -------------------------------------
    input  wire [8:0]                         top_state,

    // ---- Coefficient shift control -----------------------------------------
    input  wire                               shift_en,        // shift strobe from CTRL

    // ---- BN coefficients (broadcast or shift-loaded per layer) -------------
    input  wire [SCALE_WIDTH-1:0]             scale,           // right-shift amount
    input  wire signed [BIAS_WIDTH-1:0]       bias,            // additive bias

    // ---- Accumulator inputs (4 channels packed) ----------------------------
    input  wire signed [SCALE_IN_WIDTH*4-1:0] scale_din,

    // ---- Outputs ------------------------------------------------------------
    output wire signed [DOUT_WIDTH-1:0]       dout_finial,     // channel-0 output (single-ch layers)
    output wire [DOUT_WIDTH*4-1:0]            scale_dout       // all 4 channels packed
);

// =============================================================================
// One-hot FSM state encoding (mirror of top_state)
// =============================================================================
localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;  // 1-D conv stage A — 2-entry shift load
localparam LAYER5 = 9'b001000000;  // 1-D conv stage B — 2-entry shift load
localparam LAYER6 = 9'b010000000;  // FC stage          — broadcast load
localparam LAYER7 = 9'b100000000;  // Final output      — broadcast load

// =============================================================================
// Coefficient register files
// bias_reg[0..3]  : per-channel bias,  [0] feeds PE0 (active output)
// scale_reg[0..3] : per-channel scale, [0] feeds PE0 (active output)
// =============================================================================
reg [BIAS_WIDTH-1:0]  bias_reg  [0:3];
reg [SCALE_WIDTH-1:0] scale_reg [0:3];

// Per-channel ReLU outputs collected from generate block
wire [DOUT_WIDTH-1:0] dout_finial_mem [0:3];

// shift_en delayed one cycle (used by LAYER4/5 to align with data pipeline)
reg shift_en_ff;

// Channel-0 output exposed for single-channel layers (LAYER1~3, 6~7)
assign dout_finial = dout_finial_mem[0];

// =============================================================================
// shift_en pipeline register
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)  shift_en_ff <= 1'b0;
    else         shift_en_ff <= shift_en;
end

// =============================================================================
// Coefficient register loading
// Three distinct strategies based on layer:
//
// LAYER0 (4-deep shift chain):
//   On shift_en: [0]←[1]←[2]←[3]←{bias,scale}
//   Coefficients are pre-loaded in order so that the correct value reaches
//   [0] by the time the corresponding channel data arrives.
//
// LAYER4/5 (2-entry shift, delayed):
//   On shift_en_ff: [0]←[1]←{bias,scale}
//   Only entries [0..1] are used; shift is delayed one cycle to align with
//   the 1-D conv valid pipeline.
//
// LAYER1/2/3/6/7 (broadcast):
//   All 4 entries receive the same bias/scale every cycle (single active coeff).
// =============================================================================
integer j;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (j = 0; j < 4; j = j + 1) begin
            bias_reg[j]  <= 12'b0;
            scale_reg[j] <= 3'b0;
        end
    end
    else begin
        case (top_state)
            IDLE: begin
                for (j = 0; j < 4; j = j + 1) begin
                    bias_reg[j]  <= 12'b0;
                    scale_reg[j] <= 3'b0;
                end
            end
            LAYER0: begin
                // 4-deep shift: new coeff enters tail [3], active coeff exits head [0]
                if (shift_en) begin
                    for (j = 1; j < 4; j = j + 1) begin
                        bias_reg[j-1]  <= bias_reg[j];
                        scale_reg[j-1] <= scale_reg[j];
                    end
                    bias_reg[3]  <= bias;
                    scale_reg[3] <= scale;
                end
            end
            LAYER4, LAYER5: begin
                // 2-entry shift (delayed): new coeff enters [1], active at [0]
                if (shift_en_ff) begin
                    for (j = 1; j < 4; j = j + 1) begin
                        bias_reg[j-1]  <= bias_reg[j];
                        scale_reg[j-1] <= scale_reg[j];
                    end
                    bias_reg[1]  <= bias;
                    scale_reg[1] <= scale;
                end
            end
            LAYER1, LAYER2, LAYER3, LAYER6, LAYER7: begin
                // Broadcast: single coeff applies to all 4 channels
                for (j = 0; j < 4; j = j + 1) begin
                    bias_reg[j]  <= bias;
                    scale_reg[j] <= scale;
                end
            end
            default: begin
                for (j = 0; j < 4; j = j + 1) begin
                    bias_reg[j]  <= 12'b0;
                    scale_reg[j] <= 3'b0;
                end
            end
        endcase
    end
end

// =============================================================================
// 4-channel scale_relu generate array
// Each instance applies: dout = ReLU((din >> scale_reg[i]) + bias_reg[i])
// scale_dout packs all 4 channel outputs; dout_finial exposes channel 0.
// =============================================================================
generate
    genvar i;
    for (i = 0; i < 4; i = i + 1) begin : scale_4channel
        scale_relu #(
            .SCALE_IN_WIDTH (SCALE_IN_WIDTH),
            .DOUT_WIDTH     (DOUT_WIDTH    ),
            .BIAS_WIDTH     (BIAS_WIDTH    ),
            .SCALE_WIDTH    (SCALE_WIDTH   )
        ) u_scale_relu (
            .scale      (scale_reg [i]                            ),
            .bias       (bias_reg  [i]                            ),
            .din        (scale_din [i*SCALE_IN_WIDTH +: SCALE_IN_WIDTH]),
            .dout_finial(dout_finial_mem[i]                       ),
            .dout       (scale_dout[i*DOUT_WIDTH     +: DOUT_WIDTH])
        );
    end
endgenerate

endmodule