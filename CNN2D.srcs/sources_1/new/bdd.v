// =============================================================================
// Module  : bdd
// Function: Behaviour-Difference Detector over a sliding window of FRAME_NUM
//           valid frames.  For each valid frame supplied by frame_ctrl, the
//           module tracks the frame with the highest and lowest vertical
//           centroid (represented as acc/count rational numbers).  After
//           FRAME_NUM frames, a 3-stage pipeline evaluates whether the
//           centroid delta between min and max exceeds DELTA_THRESHOLD, and
//           whether the max frame occurred after the min frame (ascending
//           motion order).  trigger_pluse is asserted for one cycle when all
//           three conditions are met.
//
// Centroid comparison avoids division by cross-multiplying:
//   cur > max  ⟺  cur_acc * max_cnt > max_acc * cur_cnt
//   cur < min  ⟺  cur_acc * min_cnt < min_acc * cur_cnt
//
// Delta threshold check (stage 1→2):
//   |max_centroid - min_centroid| > DELTA_THRESHOLD
//   ⟺ |max_acc*min_cnt - min_acc*max_cnt| > DELTA_THRESHOLD*max_cnt*min_cnt
// =============================================================================
module bdd #(
    parameter DATA_WIDTH      = 8,   // Input pixel bit-width (passed to frame_ctrl)
    parameter DELTA_THRESHOLD = 7,   // Minimum centroid delta to assert trigger
    parameter FRAME_NUM       = 16   // Sliding window size (number of valid frames)
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- Pixel stream input (forwarded to frame_ctrl) ----------------------
    input  wire [DATA_WIDTH-1:0]  raw_data,
    input  wire                   din_valid,

    // ---- Trigger output ----------------------------------------------------
    output reg                    trigger_pluse   // One-cycle pulse: motion detected
);

// =============================================================================
// frame_ctrl interface wires
// =============================================================================
wire [17:0] frame_non_zero_acc;     // Weighted row sum for the completed frame
wire [11:0] frame_non_zero_counts;  // Total above-threshold pixel count
wire        frame_done;             // One-cycle pulse at end of each frame
wire        frame_valid;            // frame_done && count ≥ FRAME_VALID_COUNTS

// =============================================================================
// Frame tracking registers
// =============================================================================
reg [3:0] frame_index;   // Index of the current frame within the window [0..FRAME_NUM-1]
reg [4:0] frame_cnt;     // Number of valid (non-empty) frames seen in this window

// ---- Max centroid frame record ---------------------------------------------
reg [17:0] max_acc;      // Weighted sum of the max-centroid frame
reg [11:0] max_cnt;      // Pixel count  of the max-centroid frame
reg [3:0]  max_index;    // Frame index  of the max-centroid frame

// ---- Min centroid frame record ---------------------------------------------
reg [17:0] min_acc;      // Weighted sum of the min-centroid frame
reg [11:0] min_cnt;      // Pixel count  of the min-centroid frame
reg [3:0]  min_index;    // Frame index  of the min-centroid frame

// =============================================================================
// Centroid comparison (cross-multiply to avoid division)
// cur > max  ⟺  frame_non_zero_acc * max_cnt > max_acc * frame_non_zero_counts
// cur < min  ⟺  frame_non_zero_acc * min_cnt < min_acc * frame_non_zero_counts
// =============================================================================
wire [29:0] cur_gt_max_lhs, cur_gt_max_rhs;
wire [29:0] cur_lt_min_lhs, cur_lt_min_rhs;

assign cur_gt_max_lhs = frame_non_zero_acc * max_cnt;
assign cur_gt_max_rhs = max_acc            * frame_non_zero_counts;

assign cur_lt_min_lhs = frame_non_zero_acc * min_cnt;
assign cur_lt_min_rhs = min_acc            * frame_non_zero_counts;

wire cur_is_larger;    // Current frame centroid > stored maximum
wire cur_is_smaller;   // Current frame centroid < stored minimum

assign cur_is_larger  = (cur_gt_max_lhs > cur_gt_max_rhs);
assign cur_is_smaller = (cur_lt_min_lhs < cur_lt_min_rhs);

// True when the current frame contains at least one above-threshold pixel
wire cur_frame_valid_data;
assign cur_frame_valid_data = (frame_non_zero_counts != 0);

// =============================================================================
// Stage 0: 16-frame sliding window — maintain min/max centroid records
// On frame_cnt == 0 (first valid frame of a new window): initialise both
//   max and min to the current frame.
// On subsequent frames: update max/min records if the current centroid is
//   strictly greater/less than the stored record.
// At end of window (frame_cnt == FRAME_NUM-1): reset counters for next window.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_index <= 4'd0;
        frame_cnt   <= 5'd0;
        max_acc     <= 18'd0;  max_cnt <= 12'd0;  max_index <= 4'd0;
        min_acc     <= 18'd0;  min_cnt <= 12'd0;  min_index <= 4'd0;
    end
    else begin
        if (frame_valid) begin
            if (cur_frame_valid_data) begin
                if (frame_cnt == 0) begin
                    // First valid frame: seed both max and min records
                    max_acc   <= frame_non_zero_acc;
                    max_cnt   <= frame_non_zero_counts;
                    max_index <= frame_index;
                    min_acc   <= frame_non_zero_acc;
                    min_cnt   <= frame_non_zero_counts;
                    min_index <= frame_index;
                    frame_cnt <= 5'd1;
                end
                else begin
                    // Update max record if current centroid is strictly higher
                    if (cur_is_larger) begin
                        max_acc   <= frame_non_zero_acc;
                        max_cnt   <= frame_non_zero_counts;
                        max_index <= frame_index;
                    end
                    // Update min record if current centroid is strictly lower
                    if (cur_is_smaller) begin
                        min_acc   <= frame_non_zero_acc;
                        min_cnt   <= frame_non_zero_counts;
                        min_index <= frame_index;
                    end
                    frame_cnt <= frame_cnt + 1'b1;
                end
            end

            // Advance or wrap frame index
            if (frame_cnt == FRAME_NUM - 1 && cur_frame_valid_data) begin
                frame_cnt   <= 5'd0;
                frame_index <= 4'd0;
            end
            else begin
                frame_index <= frame_index + 1'b1;
            end
        end
    end
end

// =============================================================================
// Stage 1: latch heavy multiply results for delta threshold pipeline
// Computes cross-multiplied operands for the inequality:
//   |max_acc*min_cnt - min_acc*max_cnt| > DELTA_THRESHOLD * max_cnt * min_cnt
// final_frame_s1 gates the pipeline: only propagates on the last frame of a window.
// =============================================================================
reg [29:0] diff_lhs_a_r;    // max_acc * min_cnt
reg [29:0] diff_lhs_b_r;    // min_acc * max_cnt
reg [41:0] diff_rhs_r;      // DELTA_THRESHOLD * max_cnt * min_cnt

reg order_ok_s1;             // min_index < max_index (ascending motion)
reg final_frame_s1;          // True on the FRAME_NUM-th valid frame of the window

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        diff_lhs_a_r   <= 30'd0;
        diff_lhs_b_r   <= 30'd0;
        diff_rhs_r     <= 42'd0;
        order_ok_s1    <= 1'b0;
        final_frame_s1 <= 1'b0;
    end
    else begin
        final_frame_s1 <= 1'b0;   // default: deassert

        if (frame_valid) begin
            diff_lhs_a_r   <= max_acc * min_cnt;
            diff_lhs_b_r   <= min_acc * max_cnt;
            diff_rhs_r     <= DELTA_THRESHOLD * max_cnt * min_cnt;
            order_ok_s1    <= (min_index < max_index);
            final_frame_s1 <= (frame_cnt == FRAME_NUM - 1) && cur_frame_valid_data;
        end
    end
end

// =============================================================================
// Stage 2: compute absolute difference and compare against threshold
// diff_abs_w  = max(diff_lhs_a_r - diff_lhs_b_r, 0)  (saturates at 0)
// delta_over_th_w asserted when the centroid spread exceeds the threshold.
// Results are registered to close timing before stage 3.
// =============================================================================
wire [30:0] diff_abs_w;
wire        delta_over_th_w;

assign diff_abs_w      = (diff_lhs_a_r >= diff_lhs_b_r)
                         ? (diff_lhs_a_r - diff_lhs_b_r) : 31'd0;
assign delta_over_th_w = (diff_abs_w > diff_rhs_r);

reg delta_over_th_s2;   // Registered delta comparison result
reg order_ok_s2;        // Registered motion-order flag
reg final_frame_s2;     // Registered window-end flag

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        delta_over_th_s2 <= 1'b0;
        order_ok_s2      <= 1'b0;
        final_frame_s2   <= 1'b0;
    end
    else begin
        delta_over_th_s2 <= delta_over_th_w;
        order_ok_s2      <= order_ok_s1;
        final_frame_s2   <= final_frame_s1;
    end
end

// =============================================================================
// Stage 3: final trigger pulse
// Assert trigger_pluse for one cycle when all three conditions hold:
//   · final_frame_s2 : we have just completed a full FRAME_NUM-frame window
//   · order_ok_s2    : max centroid occurred after min (ascending motion)
//   · delta_over_th_s2 : centroid spread exceeds DELTA_THRESHOLD
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trigger_pluse <= 1'b0;
    end
    else begin
        trigger_pluse <= final_frame_s2 && order_ok_s2 && delta_over_th_s2;
    end
end

// =============================================================================
// frame_ctrl instance — supplies per-frame centroid statistics
// =============================================================================
frame_ctrl #(
    .DATA_WIDTH         (DATA_WIDTH)
) inst_frame_ctrl (
    .clk                   (clk                  ),
    .rst_n                 (rst_n                ),
    .raw_data              (raw_data             ),
    .din_valid             (din_valid            ),
    .frame_non_zero_acc    (frame_non_zero_acc   ),
    .frame_non_zero_counts (frame_non_zero_counts),
    .frame_done            (frame_done           ),
    .frame_valid           (frame_valid          )
);

endmodule