`timescale 1ns / 1ps
// =============================================================================
// Module  : avg_9
// Function: 9-pixel 1D average pooling.
//           Accumulates 9 consecutive valid input pixels, then computes the
//           average using a shift-based approximation of 1/9:
//             result = (sum >> 4) + (sum >> 5) + (sum >> 6)
//                    = sum * (0.0625 + 0.03125 + 0.015625)
//                    = sum * 0.109375 ≈ sum * 0.111 ≈ sum / 9
//           Rounding offsets (+8, +16, +32) are applied per shift to reduce
//           truncation error.
// Latency : 2 cycles after the 9th valid pixel (valid_ff -> output register)
// =============================================================================
module avg_9#(
    parameter DIN_WIDTH        = 8,
    parameter DOUT_WIDTH       = 8
)
(
    input wire                    clk,
    input wire                    rst_n,
    input wire                    en,

    input wire [DIN_WIDTH-1:0]    avg_pool_din,
    input wire                    avg_din_valid,

    output reg [DOUT_WIDTH-1:0]   avg_pool_dout,
    output reg                    avg_dout_valid
);

// Pixel counter: counts 0~9, resets after 9 valid inputs
reg [3:0]  cnt;
// Accumulator: sums up to 9 pixels (max 9 x 255 = 2295, fits in 12-bit)
reg [11:0] avg_pool_dout_ff;
// One-cycle pulse indicating accumulation of 9 pixels is complete
reg        avg_dout_valid_ff;

// =============================================================================
// Pixel counter: increments on each valid input, resets at 9
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        cnt <= 4'b0;
    end
    else if (cnt == 4'd9) begin      // reset after reaching 9
        cnt <= 4'b0;
    end 
    else if (avg_din_valid && en)begin
        cnt <= cnt + 1'b1;
    end
end

// =============================================================================
// Accumulator and output:
//   - When avg_dout_valid_ff is high: compute approximated average and output
//       result = sum * (1/16 + 1/32 + 1/64) ≈ sum * 0.109375 ≈ sum / 9
//       rounding offsets (+8, +16, +32) reduce truncation error per shift stage
//       then clear accumulator for next window
//   - When valid input arrives: accumulate into avg_pool_dout_ff
//   - Otherwise: hold accumulator, clear output
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        avg_pool_dout    <= 8'b0;
        avg_pool_dout_ff <= 12'b0;
    end
    else if (avg_dout_valid_ff) begin
        // Approximate division by 9 using shifts with rounding
        avg_pool_dout <= ((avg_pool_dout_ff + 8) >> 4) + ((avg_pool_dout_ff + 16) >> 5) + ((avg_pool_dout_ff + 32) >> 6);
        // avg_pool_dout <= (avg_pool_dout_ff >> 4) + (avg_pool_dout_ff >> 5) + (avg_pool_dout_ff >> 6);
        avg_pool_dout_ff <= 12'b0;   // clear accumulator for next window
    end
    else if(avg_din_valid && en)begin
        avg_pool_dout_ff <= avg_pool_dout_ff + avg_pool_din;  // accumulate pixel
    end
    else begin
        avg_pool_dout <= 8'b0;
        avg_pool_dout_ff <= avg_pool_dout_ff;   // hold accumulator
    end
end

// =============================================================================
// Stage 1 valid flag: pulses high for one cycle when cnt reaches 9
// Indicates accumulation is complete and output should be computed next cycle
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        avg_dout_valid_ff <= 1'b0;
    end
    else if(cnt == 4'd9 && en)begin
        avg_dout_valid_ff <= 1'b1;
    end
    else avg_dout_valid_ff <= 1'b0;
end

// =============================================================================
// Stage 2 valid flag: delayed by one cycle from avg_dout_valid_ff
// Aligns with avg_pool_dout which is also registered one cycle after valid_ff
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        avg_dout_valid <= 1'b0;
    end
    else avg_dout_valid <= avg_dout_valid_ff;
end

endmodule