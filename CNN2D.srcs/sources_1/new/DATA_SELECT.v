`timescale 1ns / 1ps
// =============================================================================
// Module  : DATA_SELECT
// Function: Pixel-stream router and convolution sequencer for 4 input channels.
//           Drives four WINDOW_25/WINDOW_50 sliding-window instances with shared
//           control signals (col, col_select, conv_start, sw_line, cur_state).
// FSM     : IDLE → PRE → CONV → LAST_CONV → IDLE  (one-hot, 4-bit)
// =============================================================================
module DATA_SELECT#(
    parameter DIN_WIDTH  = 8,
    parameter DOUT_WIDTH = 8,
    parameter MAX_WIDTH  = 6,
    parameter NUM        = 9
)

(
    input wire clk,
    input wire rst_n,
    input wire cnn_start,

    input wire [DIN_WIDTH-1:0] select_din0,
    input wire [DIN_WIDTH-1:0] select_din1,
    input wire [DIN_WIDTH-1:0] select_din2,
    input wire [DIN_WIDTH-1:0] select_din3,

    input wire                  din_valid,
    input wire  [MAX_WIDTH-1:0] img_width,
    input wire  [MAX_WIDTH-1:0] img_height,

    output wire [DOUT_WIDTH*NUM-1:0]        select_dout0,
    output wire [DOUT_WIDTH*NUM-1:0]        select_dout1,
    output wire [DOUT_WIDTH*NUM-1:0]        select_dout2,
    output wire [DOUT_WIDTH*NUM-1:0]        select_dout3,

    output reg                              data_select_valid
);

// =============================================================================
// FSM state encoding  (one-hot)
// =============================================================================
reg [3:0] cur_state,next_state;

localparam IDLE      = 4'b0001;
localparam PRE       = 4'b0010;   // Wait until the first full row is buffered
localparam CONV      = 4'b0100;   // Active convolution over input rows
localparam LAST_CONV = 4'b1000;   // Drain remaining output pixels after input ends

// =============================================================================
// Pixel counters and derived control signals
//   col / row            : track position in the incoming pixel stream
//   col_select / row_select : track the output (convolution-window) position
//   conv_start           : set when row 1, col 0 is reached; cleared at frame end
//   sw_line              : single-cycle pulse at the last valid pixel of each row
// =============================================================================
reg [MAX_WIDTH-1:0] col, row;
reg [MAX_WIDTH-1:0]col_select,row_select;
reg conv_start;

wire col_last    = (col == img_width - 1'b1);
wire row_last    = (row == img_height - 1'b1);
wire conv_rs_end = col_last && row_last;          // Input frame complete
wire conv_end    = (col_select == img_width - 1'b1) && (row_select == img_height - 1'b1);  // Output frame complete

wire sw_line  = din_valid && col_last;            // End-of-row strobe

// =============================================================================
// FSM sequential  –  state register
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        cur_state <= IDLE;
    end
    else begin
        cur_state <= next_state; 
    end
end

// =============================================================================
// FSM combinational  –  next-state logic
// =============================================================================
always @(*) begin
    case (cur_state)
        IDLE:next_state = cnn_start ? PRE : IDLE;
        PRE:begin
            next_state  = conv_start ? CONV : PRE;
        end 
        CONV:begin
            next_state = conv_rs_end ? LAST_CONV : CONV;
        end
        LAST_CONV:begin
            next_state = conv_end ? IDLE : LAST_CONV;
        end
        default:next_state  = IDLE; 
    endcase
end

// =============================================================================
// Input pixel counter  (col / row)
//   Increments on every valid pixel; wraps at frame boundaries.
//   Resets to zero when din_valid is de-asserted (frame gap).
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        col <= 6'b0;
        row <= 6'b0;
    end
    else if(din_valid) begin
        if (col_last) begin
            if (row_last) begin
                col <= 6'b0;
                row <= 6'b0;
            end
            else begin
                col <= 6'b0;
                row <= row + 1'b1;
            end
        end
        else begin
            col <= col + 1'b1;
        end
    end
    else begin
        col <= 6'b0;
        row <= 6'b0;
    end
end

// =============================================================================
// conv_start flag
//   Set  : when the second input row begins (row==1, col==0),
//          meaning one full row has been buffered and windows can open.
//   Clear: when the output frame is fully consumed.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n)begin
        conv_start <= 1'b0;
    end
    else if (col == 6'd0 && row == 6'd1)begin
        conv_start <= 1'b1;
    end
    else if ((col_select == img_width - 1'b1) && (row_select == img_height - 1'b1))begin
        conv_start <= 1'b0;
    end
end

// =============================================================================
// Output pixel counter  (col_select / row_select)
//   Advances whenever conv_start is high and either a new input pixel arrives
//   (CONV state) or the FSM is draining the last row (LAST_CONV state).
// =============================================================================
always@(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        col_select <= 6'b0;
        row_select <= 6'b0;
    end else if (conv_start && (din_valid || cur_state == LAST_CONV)) begin
        if (col_select == img_width - 1'b1) begin
            if (row_select == img_height - 1'b1)begin
                row_select <= 6'b0;
                col_select <= 6'b0;
            end
            else begin
                row_select <= row_select + 1'b1;
                col_select <= 6'd0;
            end
        end 
        else col_select <= col_select + 1'b1;
    end else begin
        col_select <= 6'd0;
        row_select <= 6'd0;
    end 
end

// =============================================================================
// Output valid flag
//   Mirrors conv_start: high for the entire duration that window data is valid.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        data_select_valid <= 1'b0;
    end else if (conv_start) begin
        data_select_valid <= 1'b1;
    end 
    else data_select_valid <= 1'b0;
end

// =============================================================================
// WINDOW_25 / WINDOW_50 Instantiations
//   Each channel (din0~din3) is fed into its own sliding-window generator.
//   All four instances share the same control/address signals produced above;
//   only the per-channel data input (din_select) and module type differ.
// =============================================================================

// Channel 0: 3x3 sliding window for select_din0
WINDOW_50 #(
    .DIN_WIDTH  (DIN_WIDTH),
    .NUM        (NUM),
    .MAX_WIDTH  (MAX_WIDTH),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_window50_ch0 (
    .clk        (clk),
    .rst_n      (rst_n),
    .cnn_start  (cnn_start),
    .img_width  (img_width),
    .img_height (img_height),
    .cur_state  (cur_state),    // FSM state forwarded to window controller
    .col        (col),          // Current input column pointer
    .col_select (col_select),   // Current output (convolution) column pointer
    .conv_start (conv_start),   // Asserted once the first full row has been buffered
    .sw_line    (sw_line),      // Pulses high at the last valid pixel of every row
    .din_select (select_din0),  // Pixel data for channel 0
    .din_valid  (din_valid),
    .window_out (select_dout0)  // 9-pixel (NUM) flattened window output
);

// Channel 1: 3x3 sliding window for select_din1
WINDOW_25 #(
    .DIN_WIDTH  (DIN_WIDTH),
    .NUM        (NUM),
    .MAX_WIDTH  (MAX_WIDTH),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_window25_ch1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .cnn_start  (cnn_start),
    .img_width  (img_width),
    .img_height (img_height),
    .cur_state  (cur_state),
    .col        (col),
    .col_select (col_select),
    .conv_start (conv_start),
    .sw_line    (sw_line),
    .din_select (select_din1),  // Pixel data for channel 1
    .din_valid  (din_valid),
    .window_out (select_dout1)
);

// Channel 2: 3x3 sliding window for select_din2
WINDOW_25 #(
    .DIN_WIDTH  (DIN_WIDTH),
    .NUM        (NUM),
    .MAX_WIDTH  (MAX_WIDTH),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_window25_ch2 (
    .clk        (clk),
    .rst_n      (rst_n),
    .cnn_start  (cnn_start),
    .img_width  (img_width),
    .img_height (img_height),
    .cur_state  (cur_state),
    .col        (col),
    .col_select (col_select),
    .conv_start (conv_start),
    .sw_line    (sw_line),
    .din_select (select_din2),  // Pixel data for channel 2
    .din_valid  (din_valid),
    .window_out (select_dout2)
);

// Channel 3: 3x3 sliding window for select_din3
WINDOW_25 #(
    .DIN_WIDTH  (DIN_WIDTH),
    .NUM        (NUM),
    .MAX_WIDTH  (MAX_WIDTH),
    .DOUT_WIDTH (DOUT_WIDTH)
) u_window25_ch3 (
    .clk        (clk),
    .rst_n      (rst_n),
    .cnn_start  (cnn_start),
    .img_width  (img_width),
    .img_height (img_height),
    .cur_state  (cur_state),
    .col        (col),
    .col_select (col_select),
    .conv_start (conv_start),
    .sw_line    (sw_line),
    .din_select (select_din3),  // Pixel data for channel 3
    .din_valid  (din_valid),
    .window_out (select_dout3)
);


endmodule