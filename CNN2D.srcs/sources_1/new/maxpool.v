`timescale 1ns / 1ps
// =============================================================================
// Module  : maxpool
// Function: 2×2 Max Pooling (stride=2), supports up to 64×64 feature maps.
//           Odd-width columns and odd-height rows are dropped automatically.
// Latency : 0 (output registered, valid same cycle as last pixel of 2×2 window)
// =============================================================================
module maxpool #(
    parameter DIN_WIDTH  = 8,   // Input  pixel bit-width
    parameter MAX_WIDTH  = 6,   // Address bit-width (max image dim = 2^MAX_WIDTH)
    parameter DOUT_WIDTH = 8    // Output pixel bit-width
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- Pixel stream input ------------------------------------------------
    input  wire [DIN_WIDTH-1:0]   din,
    input  wire [MAX_WIDTH-1:0]   img_width,   // Actual image width  (columns)
    input  wire [MAX_WIDTH-1:0]   img_height,  // Actual image height (rows)
    input  wire                   din_valid,   // High when din is valid

    // ---- Pooling control ---------------------------------------------------
    input  wire                   pool_en,     // Enable pooling output

    // ---- Pooled output -----------------------------------------------------
    output reg  [DOUT_WIDTH-1:0]  dout,
    output reg                    flag         // High when dout is valid
);

// =============================================================================
// Local parameters
// =============================================================================
localparam BUF_DEPTH = 25;   // Max pool columns = img_width/2 ≤ 32 (6-bit addr)

// =============================================================================
// Pixel counters
// =============================================================================
reg [MAX_WIDTH-1:0] col;   // Current column index (0 … img_width-1)
reg [MAX_WIDTH-1:0] row;   // Current row    index (0 … img_height-1)

wire [MAX_WIDTH-1:0] col_last = img_width  - 1'b1;
wire [MAX_WIDTH-1:0] row_last = img_height - 1'b1;

// Pool-grid coordinates: which 2×2 cell does current pixel belong to?
wire [MAX_WIDTH-2:0] pool_col = col >> 1;   // 0 … pool_w-1
// wire [MAX_WIDTH-2:0] pool_row = row >> 1; // (unused in output logic)

wire [MAX_WIDTH-2:0] pool_w   = img_width >> 1;  // Number of output columns

// =============================================================================
// Gate: disable pool output for odd-edge pixels that fall outside 2×2 grid
//
//   - If img_width  is odd, the last column  (col == col_last) is dropped.
//   - If img_height is odd and > 1, the last row (row == row_last) is dropped.
//   - pool_en_gated combines user pool_en with these masking conditions.
// =============================================================================
wire width_is_odd  =  img_width[0];
wire height_is_odd =  img_height[0] && (img_height != 6'd1);

wire drop_col = (col == col_last) &&  width_is_odd;
wire drop_row = (row == row_last) && height_is_odd;

wire pool_en_gated = pool_en && !drop_col && !drop_row;

// =============================================================================
// Output timing: emit result at the bottom-right pixel of each 2×2 window
//
//   Single-row images  → only column parity matters (row is always 0).
//   Normal images      → both row[0] and col[0] must be 1.
// =============================================================================
wire output_time = (img_height == 6'd1) ? col[0]
                                        : (row[0] && col[0]);

// =============================================================================
// Per-column max register buffer
//   max_reg[k] holds the running maximum of column k for the current 2-row band.
// =============================================================================
reg [DOUT_WIDTH-1:0] max_reg [0:BUF_DEPTH-1];
integer i;

// Compare incoming pixel against buffered max for this pool column
wire [DOUT_WIDTH-1:0] candidate = (din > max_reg[pool_col]) ? din
                                                             : max_reg[pool_col];

// Detect the start of a new 2-row band (even row, first column)
wire new_band = (row[0] == 1'b0) && (col == {MAX_WIDTH{1'b0}});

// =============================================================================
// Pixel counter FSM
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row <= {MAX_WIDTH{1'b0}};
        col <= {MAX_WIDTH{1'b0}};
    end else if (din_valid) begin
        if (col == col_last) begin
            col <= {MAX_WIDTH{1'b0}};
            row <= (row == row_last) ? {MAX_WIDTH{1'b0}} : row + 1'b1;
        end else begin
            col <= col + 1'b1;
        end
    end else begin
        // No valid data: reset counters (assumes frame-by-frame streaming)
        row <= {MAX_WIDTH{1'b0}};
        col <= {MAX_WIDTH{1'b0}};
    end
end

// =============================================================================
// Per-column max accumulation
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < BUF_DEPTH; i = i + 1)
            max_reg[i] <= {DOUT_WIDTH{1'b0}};
    end else if (din_valid && pool_en_gated) begin
        if (new_band) begin
            // Clear all active columns and load the first pixel of the new band
            for (i = 0; i < pool_w; i = i + 1)begin
                max_reg[i] <= {DOUT_WIDTH{1'b0}};
            end
            max_reg[0] <= din;
        end else begin
            // Update running max for this pool column
            max_reg[pool_col] <= candidate;
        end
    end
    // else: hold (implicit; avoids latch-like explicit hold assignments)
end

// =============================================================================
// Output register
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dout <= {DOUT_WIDTH{1'b0}};
        flag <= 1'b0;
    end else if (output_time && pool_en_gated) begin
        dout <= candidate;
        flag <= 1'b1;
    end else begin
        dout <= {DOUT_WIDTH{1'b0}};
        flag <= 1'b0;
    end
end

endmodule