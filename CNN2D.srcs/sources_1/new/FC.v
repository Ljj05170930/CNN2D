`timescale 1ns / 1ps
// =============================================================================
// Module  : FC
// Function: Fully-connected layer data buffer and sequencer.
//           Manages two 32-entry ping-pong register files (fc_rem0 / fc_rem1):
//             · fc_rem0 : filled in LAYER5 from 1-D avg-pool results (16-bit →
//                         split into two 8-bit entries per beat, 16 beats total)
//             · fc_rem1 : filled in LAYER6 from maxpool beat-by-beat (32 beats)
//           In LAYER6/7, fc_rem_sel muxes the appropriate bank and packs all
//           32 entries into fc_din for the downstream conv PE array.
//           fc_cnt tracks fill progress and drives layer5_ready / layer6_ready.
// =============================================================================
module FC #(
    parameter DIN_WIDTH = 8,   // Data bit-width per FC entry
    parameter NUM       = 9    // PE kernel size (3×3); used for fc_din slice widths
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- Top-level FSM state (one-hot) -------------------------------------
    input  wire [8:0]                 top_state,

    // ---- LAYER6 maxpool beat strobe ----------------------------------------
    input  wire                       maxpool_valid_ff,        // delayed maxpool valid

    // ---- LAYER6 FC serial input --------------------------------------------
    input  wire [7:0]                 FC_din,                  // one byte per maxpool beat

    // ---- LAYER5 1-D avg-pool results ---------------------------------------
    input  wire                       avg_dout_cov1D_valid,    // 1-D avg-pool output valid
    input  wire [15:0]                avg_pool_cov1D_dout,     // 16-bit result (2 entries packed)

    // ---- Layer-done handshakes to CTRL -------------------------------------
    output reg                        layer5_ready,            // all 16 LAYER5 beats received
    output reg                        layer6_ready,            // all 32 LAYER6 beats received

    // ---- FC beat counter (shared with CTRL for shift timing) ---------------
    output reg  [4:0]                 fc_cnt,

    // ---- Packed 32-entry FC data bus to conv PE array ----------------------
    output wire [32*DIN_WIDTH-1:0]    fc_din
);

// =============================================================================
// One-hot FSM state encoding (mirror of top_state)
// =============================================================================
localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;
localparam LAYER5 = 9'b001000000;  // 1-D conv → fills fc_rem0 (16 beats × 2 bytes)
localparam LAYER6 = 9'b010000000;  // Maxpool  → fills fc_rem1 (32 beats × 1 byte)
localparam LAYER7 = 9'b100000000;  // Hold both banks; fc_rem1 drives output

// =============================================================================
// Ping-pong register files
// fc_rem0[0..31] : 1-D avg-pool results from LAYER5
//                  each beat writes two entries: [fc_cnt<<1] and [fc_cnt<<1 + 1]
// fc_rem1[0..31] : maxpool serial stream from LAYER6 (one entry per beat)
// =============================================================================
reg [DIN_WIDTH-1:0] fc_rem0 [0:31];
reg [DIN_WIDTH-1:0] fc_rem1 [0:31];

// =============================================================================
// fc_cnt & layer-ready sequencer
// LAYER5: counts avg_dout_cov1D_valid beats 0→15; sets layer5_ready at wrap.
// LAYER6: counts maxpool_valid_ff beats 0→31; sets layer6_ready at wrap.
// =============================================================================
integer j;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        fc_cnt       <= 4'b0;
        layer5_ready <= 1'b0;
        layer6_ready <= 1'b0;
    end
    else begin
        case (top_state)
            LAYER5: begin
                if (avg_dout_cov1D_valid) begin
                    if (fc_cnt == 5'd15) begin
                        fc_cnt       <= 5'b0;
                        layer5_ready <= 1'b1;   // 16 beats complete → fc_rem0 full
                    end
                    else begin
                        fc_cnt <= fc_cnt + 1'b1;
                    end
                end
            end
            LAYER6: begin
                if (maxpool_valid_ff) begin
                    if (fc_cnt == 5'd31) begin
                        layer6_ready <= 1'b1;   // 32 beats complete → fc_rem1 full
                        fc_cnt       <= 5'b0;
                    end
                    else fc_cnt <= fc_cnt + 1'b1;
                end
            end
            default: begin
                fc_cnt       <= 4'b0;
                layer5_ready <= 1'b0;
                layer6_ready <= 1'b0;
            end
        endcase
    end
end

// =============================================================================
// Register file write logic
// LAYER5: split 16-bit avg result into two bytes at even/odd addresses
// LAYER6: write one FC_din byte per maxpool beat into fc_rem1
// LAYER7: hold both banks (explicit self-assignment to prevent inference issues)
// default: clear both banks
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (j = 0; j < 32; j = j + 1) begin
            fc_rem0[j] <= 8'b0;
            fc_rem1[j] <= 8'b0;
        end
    end
    else begin
        case (top_state)
            LAYER5: begin
                if (avg_dout_cov1D_valid) begin
                    // Split 16-bit result: low byte → even index, high byte → odd index
                    fc_rem0[fc_cnt << 1]       <= avg_pool_cov1D_dout[7:0];
                    fc_rem0[(fc_cnt << 1) + 1] <= avg_pool_cov1D_dout[15:8];
                end
            end
            LAYER6: begin
                if (maxpool_valid_ff) begin
                    fc_rem1[fc_cnt] <= FC_din;  // serial fill: one byte per beat
                end
            end
            LAYER7: begin
                // Hold both banks across LAYER7 for stable fc_din output
                for (j = 0; j < 32; j = j + 1) begin
                    fc_rem0[j] <= fc_rem0[j];
                    fc_rem1[j] <= fc_rem1[j];
                end
            end
            default: begin
                for (j = 0; j < 32; j = j + 1) begin
                    fc_rem0[j] <= 8'b0;
                    fc_rem1[j] <= 8'b0;
                end
            end
        endcase
    end
end

// =============================================================================
// Bank select mux & fc_din packing
// In LAYER6: fc_rem0 (just filled) drives the output (feed-forward).
// In LAYER7: fc_rem1 (filled in LAYER6) drives the output.
// fc_din is sliced into four PE-width groups:
//   [0..8]   → PE0  (9 entries)
//   [9..17]  → PE1  (9 entries)
//   [18..26] → PE2  (9 entries)
//   [27..31] → PE3  (5 entries, upper bits implicit zero in DATA_FLOW)
// =============================================================================
wire [DIN_WIDTH-1:0] fc_rem_sel [0:31];

genvar i;
generate
    for (i = 0; i < 32; i = i + 1) begin : rem_mux
        assign fc_rem_sel[i] = (top_state == LAYER6) ? fc_rem0[i] : fc_rem1[i];
    end
endgenerate

// Pack 32 entries into four consecutive PE-width slices
assign fc_din[DIN_WIDTH*NUM-1:0] =
    {fc_rem_sel[8], fc_rem_sel[7], fc_rem_sel[6], fc_rem_sel[5],
     fc_rem_sel[4], fc_rem_sel[3], fc_rem_sel[2], fc_rem_sel[1], fc_rem_sel[0]};

assign fc_din[DIN_WIDTH*NUM*2-1:DIN_WIDTH*NUM] =
    {fc_rem_sel[17], fc_rem_sel[16], fc_rem_sel[15], fc_rem_sel[14],
     fc_rem_sel[13], fc_rem_sel[12], fc_rem_sel[11], fc_rem_sel[10], fc_rem_sel[9]};

assign fc_din[DIN_WIDTH*NUM*3-1:2*DIN_WIDTH*NUM] =
    {fc_rem_sel[26], fc_rem_sel[25], fc_rem_sel[24], fc_rem_sel[23],
     fc_rem_sel[22], fc_rem_sel[21], fc_rem_sel[20], fc_rem_sel[19], fc_rem_sel[18]};

assign fc_din[32*DIN_WIDTH-1:3*DIN_WIDTH*NUM] =
    {fc_rem_sel[31], fc_rem_sel[30], fc_rem_sel[29], fc_rem_sel[28], fc_rem_sel[27]};

endmodule