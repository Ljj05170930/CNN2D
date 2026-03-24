`timescale 1ns / 1ps
// =============================================================================
// Module  : WINDOW_25
// Function: 3×3 Sliding-Window Extractor for a single feature-map channel.
//           Internally maintains three circular line buffers (conv_buffer0/1/2)
//           indexed by a rotating pointer (buf_ptr).  At each valid clock the
//           nine neighbours of the current pixel are assembled into window_out.
// Latency : 1 cycle (window registers updated on posedge following valid pixel)
// =============================================================================
module WINDOW_25#(
    parameter DIN_WIDTH  = 8,
    parameter NUM        = 9,
    parameter MAX_WIDTH  = 6,
    parameter DOUT_WIDTH = 8
)
(
    input wire                     clk,
    input wire                     rst_n,
    input wire                     cnn_start,

    input wire [MAX_WIDTH-1:0]     img_width,
    input wire [MAX_WIDTH-1:0]     img_height,

    input wire [3:0]               cur_state,   // FSM state from DATA_SELECT
    input wire [MAX_WIDTH-1:0]     col,          // Current input column pointer
    input wire [MAX_WIDTH-1:0]     col_select,   // Current output (convolution) column pointer
    input wire                     conv_start,   // High once first full row has been buffered
    input wire                     sw_line,      // Pulses high at the last valid pixel of every row

    input wire [DIN_WIDTH-1:0]     din_select,   // Pixel data input for this channel
    input wire                     din_valid,
    
    output wire [DOUT_WIDTH*NUM-1:0] window_out  // 9-pixel flattened 3×3 window (row-major)
);

// =============================================================================
// Local parameters  –  replicated from DATA_SELECT to decode cur_state
// =============================================================================
localparam IDLE      = 4'b0001;
localparam PRE       = 4'b0010;
localparam CONV      = 4'b0100;
localparam LAST_CONV = 4'b1000;

// =============================================================================
// Circular line buffers
//   Three buffers of depth 25 store up to three consecutive input rows.
//   buf_ptr rotates among {0,1,2} on every row boundary (sw_line).
//     ptr_write → buffer currently receiving new pixels  (current row)
//     ptr_new   → buffer that holds the previous row     (row N-1)
//     ptr_old   → buffer that holds the row before that  (row N-2)
// =============================================================================
reg [DIN_WIDTH-1:0]  conv_buffer0 [0:24];
reg [DIN_WIDTH-1:0]  conv_buffer1 [0:24];
reg [DIN_WIDTH-1:0]  conv_buffer2 [0:24];

// buf_ptr | ptr_write | ptr_new | ptr_old
// --------+-----------+---------+--------
// 0       | buf0      | buf2    | buf1
// 1       | buf1      | buf0    | buf2
// 2       | buf2      | buf1    | buf0
wire [1:0] ptr_write;
wire [1:0] ptr_new;
wire [1:0] ptr_old;

// Read-out wires: one set per buffer role, for columns 0, 1, and col_select+1
wire [DIN_WIDTH-1:0] rd_old_c0,  rd_new_c0,  rd_write_c0;
wire [DIN_WIDTH-1:0] rd_old_c1,  rd_new_c1,  rd_write_c1;
wire [DIN_WIDTH-1:0] rd_old_cp, rd_new_cp, rd_write_cp;

reg [1:0] buf_ptr;   // Rotating write-pointer (0, 1, 2)

// =============================================================================
// 3×3 window register array
//   win[0..2] = top    row (oldest),  win[3..5] = middle row,  win[6..8] = bottom row
//   Flattened MSB-first: {win[8], win[7], ..., win[0]}
// =============================================================================
reg [DOUT_WIDTH-1:0] win [0:8];

assign window_out = {win[8], win[7], win[6],
                     win[5], win[4], win[3],
                     win[2], win[1], win[0]};

// =============================================================================
// buf_ptr rotation
//   Resets to 0 in IDLE; advances by 1 (mod 3) on every sw_line pulse.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)
        buf_ptr <= 2'd0;
    else if (cur_state == IDLE)begin
        buf_ptr <= 2'd0;
    end
    else if (sw_line)begin
        buf_ptr <= (buf_ptr == 2'd2) ? 2'd0 : buf_ptr + 2'd1;
    end
end

// =============================================================================
// Line buffer write logic
//   On din_valid, write din_select into the active buffer at address col.
//   All buffers are cleared in reset and whenever the FSM returns to IDLE.
// =============================================================================
integer i;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 25; i = i + 1) begin
            conv_buffer0[i] <= 8'd0;
            conv_buffer1[i] <= 8'd0;
            conv_buffer2[i] <= 8'd0;
        end
    end
    else if (cur_state == IDLE) begin
        for (i = 0; i < 25; i = i + 1) begin
            conv_buffer0[i] <= 8'd0;
            conv_buffer1[i] <= 8'd0;
            conv_buffer2[i] <= 8'd0;
        end
    end 
    else if (din_valid) begin
        case (ptr_write)
            2'd0: conv_buffer0[col] <= din_select;
            2'd1: conv_buffer1[col] <= din_select;
            2'd2: conv_buffer2[col] <= din_select;
            default:begin
                for (i = 0; i < 25; i = i + 1) begin
                    conv_buffer0[i] <= 8'd0;
                    conv_buffer1[i] <= 8'd0;
                    conv_buffer2[i] <= 8'd0;
                end
            end
        endcase
    end
end

// =============================================================================
// Buffer pointer decode
// =============================================================================
assign ptr_write = buf_ptr;

assign ptr_new = (buf_ptr == 2'd0) ? 2'd2 :
                     (buf_ptr == 2'd1) ? 2'd0 : 2'd1;

assign ptr_old = (buf_ptr == 2'd0) ? 2'd1 :
                     (buf_ptr == 2'd1) ? 2'd2 : 2'd0;

// =============================================================================
// Read-out: column 0  (left edge of the 3×3 window at the start of each row)
// =============================================================================
assign rd_old_c0    = (ptr_old == 2'd0) ? conv_buffer0[0] :
                      (ptr_old == 2'd1) ? conv_buffer1[0] :
                                          conv_buffer2[0];

assign rd_new_c0    = (ptr_new == 2'd0) ? conv_buffer0[0] :
                      (ptr_new == 2'd1) ? conv_buffer1[0] :
                                          conv_buffer2[0];

// In LAST_CONV there is no new incoming row, so the write buffer is zeroed.
assign rd_write_c0  = cur_state == LAST_CONV ? 8'b0 :
                      (ptr_write == 2'd0) ? conv_buffer0[0] :
                      (ptr_write == 2'd1) ? conv_buffer1[0] :
                                            conv_buffer2[0];

// =============================================================================
// Read-out: column 1  (used only during the left-edge initialisation)
// =============================================================================
assign rd_old_c1    = (ptr_old == 2'd0) ? conv_buffer0[1] :
                      (ptr_old == 2'd1) ? conv_buffer1[1] :
                                          conv_buffer2[1];

assign rd_new_c1    = (ptr_new == 2'd0) ? conv_buffer0[1] :
                      (ptr_new == 2'd1) ? conv_buffer1[1] :
                                          conv_buffer2[1];

// During LAST_CONV or before conv_start, treat column 1 as zero.
assign rd_write_c1  = cur_state == LAST_CONV ? 8'b0 : (~conv_start) ? 8'b0 :din_select;

// =============================================================================
// Read-out: column col_select+1  (leading pixel for the sliding window advance)
// =============================================================================
assign rd_old_cp   = (ptr_old == 2'd0) ? conv_buffer0[col_select + 1] :
                      (ptr_old == 2'd1) ? conv_buffer1[col_select + 1] :
                                          conv_buffer2[col_select + 1];

assign rd_new_cp   = (ptr_new == 2'd0) ? conv_buffer0[col_select + 1] :
                      (ptr_new == 2'd1) ? conv_buffer1[col_select + 1] :
                                          conv_buffer2[col_select + 1];

// During LAST_CONV or before conv_start, treat the leading pixel as zero.
assign rd_write_cp = cur_state == LAST_CONV ? 8'b0 : (~conv_start) ? 8'b0 :din_select;

// =============================================================================
// 3×3 window shift register
//   Three update cases:
//     1. col_select == 0  (left-edge init): load columns 0 and 1 with zero
//        padding on the left, and the first two buffer values on the right.
//     2. col_select == img_width-1 (right-edge): shift left and zero-pad
//        the right column to handle the boundary.
//     3. General case: shift left and load rd_{old,new,write}_cp as the
//        new right column from the three row buffers.
// =============================================================================
integer j;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (j = 0; j < 9; j = j + 1)
            win[j] <= 8'd0;
    end 
    else if (col_select == 6'b0 && conv_start) begin
        // Left-edge initialisation: pad left column with zeros
        win[0] <= 8'b0;
        win[1] <= rd_old_c0;
        win[2] <= rd_old_c1;
        win[3] <= 8'b0;
        win[4] <= rd_new_c0;
        win[5] <= rd_new_c1;
        win[6] <= 8'b0;
        win[7] <= rd_write_c0;
        win[8] <= rd_write_c1;
    end 
    else if(col_select == img_width - 1'b1) begin
        // Right-edge: shift and zero-pad the rightmost column
        win[0] <= win[1];
        win[1] <= win[2];
        win[2] <= 8'b0;
        win[3] <= win[4];
        win[4] <= win[5];
        win[5] <= 8'b0;
        win[6] <= win[7];
        win[7] <= win[8];
        win[8] <= 8'b0;
    end
    else begin
        // General case: shift left and load new right column from line buffers
        win[0] <= win[1];
        win[1] <= win[2];
        win[2] <= rd_old_cp;
        win[3] <= win[4];
        win[4] <= win[5];
        win[5] <= rd_new_cp;
        win[6] <= win[7];
        win[7] <= win[8];
        win[8] <= rd_write_cp;
    end
end

endmodule