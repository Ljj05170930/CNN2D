`timescale 1ns / 1ps
// =============================================================================
// Module  : frame_ctrl
// Function: Per-frame above-threshold pixel accumulator and validity checker.
//           Instantiates pixel_ctrl to obtain per-row counts (row_non_zero_cnt_final)
//           and row-end strobes (row_done), then accumulates across ROW_NUMS rows:
//             · frame_non_zero_counts : total above-threshold pixels in the frame
//             · frame_non_zero_acc    : weighted sum (row_index × row_count),
//                                       used as a vertical centre-of-mass estimate
//           At the last row, results are latched into output registers,
//           accumulators are reset, and frame_done pulses for one cycle.
//           frame_valid is asserted when frame_done and the pixel count meets
//           the FRAME_VALID_COUNTS threshold (indicates a non-empty frame).
// =============================================================================
module frame_ctrl #(
    parameter DATA_WIDTH         = 8,    // Input pixel bit-width (passed to pixel_ctrl)
    parameter FRAME_VALID_COUNTS = 100,  // Min above-threshold pixels for a valid frame
    parameter ROW_NUMS           = 62    // Rows per frame
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- Pixel stream input (forwarded to pixel_ctrl) ----------------------
    input  wire [DATA_WIDTH-1:0]  raw_data,
    input  wire                   din_valid,

    // ---- Frame result outputs ----------------------------------------------
    output reg  [17:0]            frame_non_zero_acc,     // Weighted row sum (latched)
    output reg  [11:0]            frame_non_zero_counts,  // Total pixel count (latched)
    output reg                    frame_done,             // One-cycle pulse at frame end
    output wire                   frame_valid             // frame_done && count ≥ threshold
);

// =============================================================================
// pixel_ctrl interface wires
// =============================================================================
wire [5:0]  row_non_zero_cnt_final;   // Above-threshold pixel count for the completed row
wire        row_done;                  // One-cycle pulse from pixel_ctrl at end of each row

// =============================================================================
// Internal accumulators (double-buffered against output registers)
// _acc suffix = working registers updated each row_done
// Output registers are only updated at end-of-frame to present stable values
// =============================================================================
reg  [5:0]  row_index;                 // Current row index within frame [0..ROW_NUMS-1]
reg  [17:0] frame_non_zero_acc_acc;    // Running weighted sum accumulator
reg  [11:0] frame_non_zero_counts_acc; // Running pixel count accumulator

// Combinational next values — pre-computed so end-of-frame and mid-frame
// paths both capture the final row's contribution in the same cycle
wire [11:0] frame_non_zero_counts_next;
wire [17:0] frame_non_zero_acc_next;

assign frame_non_zero_counts_next = frame_non_zero_counts_acc + row_non_zero_cnt_final;
assign frame_non_zero_acc_next    = frame_non_zero_acc_acc
                                  + row_index * row_non_zero_cnt_final;

// =============================================================================
// Frame accumulation FSM
// Triggered on each row_done pulse from pixel_ctrl.
// End-of-frame (row_index == ROW_NUMS-1):
//   · Latch _next values into output registers (visible to downstream)
//   · Reset working accumulators and row_index for the next frame
//   · Pulse frame_done for one cycle
// Mid-frame:
//   · Fold _next values back into working accumulators
//   · Advance row_index
// frame_done is cleared to 0 at the top of every cycle (single-cycle pulse).
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row_index                 <= 6'd0;
        frame_non_zero_acc_acc    <= 18'd0;
        frame_non_zero_counts_acc <= 12'd0;
        frame_non_zero_acc        <= 18'd0;
        frame_non_zero_counts     <= 12'd0;
        frame_done                <= 1'b0;
    end
    else begin
        frame_done <= 1'b0;   // default: deassert pulse each cycle

        if (row_done) begin
            if (row_index == ROW_NUMS - 1) begin
                // ---- End of frame: latch results & reset accumulators ------
                frame_non_zero_counts <= frame_non_zero_counts_next;
                frame_non_zero_acc    <= frame_non_zero_acc_next;
                frame_done            <= 1'b1;

                frame_non_zero_counts_acc <= 12'd0;
                frame_non_zero_acc_acc    <= 18'd0;
                row_index                 <= 6'd0;
            end
            else begin
                // ---- Mid-frame: accumulate and advance row pointer ---------
                frame_non_zero_counts_acc <= frame_non_zero_counts_next;
                frame_non_zero_acc_acc    <= frame_non_zero_acc_next;
                row_index                 <= row_index + 1'b1;
            end
        end
    end
end

// =============================================================================
// frame_valid: combinational gate — frame must be done AND meet pixel threshold
// =============================================================================
assign frame_valid = frame_done && (frame_non_zero_counts >= FRAME_VALID_COUNTS);

// =============================================================================
// pixel_ctrl instance — supplies row_non_zero_cnt_final and row_done
// =============================================================================
pixel_ctrl #(
    .DATA_WIDTH    (DATA_WIDTH)
) inst_pixel_ctrl (
    .clk                    (clk                   ),
    .rst_n                  (rst_n                 ),
    .raw_data               (raw_data              ),
    .din_valid              (din_valid             ),
    .row_non_zero_cnt_final (row_non_zero_cnt_final),
    .row_done               (row_done              )
);

endmodule