`timescale 1ns / 1ps
// =============================================================================
// Module  : pixel_ctrl
// Function: Per-row above-threshold pixel counter.
//           Scans an input pixel stream row by row (COL_NUMS pixels per row).
//           For each valid pixel, checks whether it meets or exceeds
//           AMP_THRESHOLD; counts qualifying pixels across the row.
//           At end of row (curr_col == COL_NUMS-1), latches the count into
//           row_non_zero_cnt_final and pulses row_done for one cycle.
// =============================================================================
module pixel_ctrl #(
    parameter DATA_WIDTH    = 8,   // Input pixel bit-width
    parameter AMP_THRESHOLD = 85,  // Minimum amplitude to count as non-zero
    parameter COL_NUMS      = 50   // Pixels per row
) (
    input  wire                   clk,    // Clock
    input  wire                   rst_n,  // Asynchronous reset, active low

    // ---- Pixel stream input ------------------------------------------------
    input  wire [DATA_WIDTH-1:0]  raw_data,    // Incoming pixel value
    input  wire                   din_valid,   // Pixel data valid strobe

    // ---- Row result outputs ------------------------------------------------
    output reg  [5:0]             row_non_zero_cnt_final, // Latched count at row end
    output reg                    row_done                // One-cycle pulse at row end
);

// =============================================================================
// Internal wires & registers
// =============================================================================

// Asserted when the current pixel is valid and meets the amplitude threshold
wire        pixel_valid;

// Combinational next value of the running counter (avoids read-modify-write
// across the clock edge; allows row_non_zero_cnt_final to capture the
// final pixel of the row in the same cycle)
wire [5:0]  row_non_zero_cnt_next;

reg  [5:0]  row_non_zero_cnt;  // Running above-threshold count for current row
reg  [5:0]  curr_col;          // Current column index within the row [0..COL_NUMS-1]

// =============================================================================
// Combinational threshold check & counter increment
// =============================================================================
assign pixel_valid          = din_valid && (raw_data >= AMP_THRESHOLD);
assign row_non_zero_cnt_next = row_non_zero_cnt + (pixel_valid ? 1'b1 : 1'b0);

// =============================================================================
// Column counter & row-end logic
// On the last column of a valid row:
//   · latch row_non_zero_cnt_next into row_non_zero_cnt_final
//   · reset running counter and column index
//   · pulse row_done for exactly one cycle
// Otherwise: accumulate count and advance column pointer.
// row_done is cleared to 0 at the start of every cycle to produce a
// single-cycle pulse without an explicit counter.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        curr_col               <= 6'd0;
        row_done               <= 1'b0;
        row_non_zero_cnt       <= 6'd0;
        row_non_zero_cnt_final <= 6'd0;
    end
    else begin
        row_done <= 1'b0;   // default: deassert pulse each cycle

        if (din_valid) begin
            if (curr_col == COL_NUMS - 1) begin
                // End of row: latch final count and reset for next row
                row_non_zero_cnt_final <= row_non_zero_cnt_next;
                row_non_zero_cnt       <= 6'd0;
                curr_col               <= 6'd0;
                row_done               <= 1'b1;
            end
            else begin
                // Mid-row: accumulate and advance column
                row_non_zero_cnt <= row_non_zero_cnt_next;
                curr_col         <= curr_col + 6'd1;
            end
        end
    end
end

endmodule