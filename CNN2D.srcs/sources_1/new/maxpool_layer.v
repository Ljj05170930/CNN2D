`timescale 1ns / 1ps
// =============================================================================
// Module  : maxpool_layer
// Function: 4-channel parallel 2×2 max-pooling wrapper.
//           Each channel is an independent maxpool instance sharing the same
//           pixel counter (img_width / img_height / din_valid / pool_en[i]).
//           Global output flag is driven by all channel
// =============================================================================
module maxpool_layer #(
    parameter DIN_WIDTH  = 8,
    parameter MAX_WIDTH  = 6,
    parameter DOUT_WIDTH = 8
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- 4-channel pixel inputs --------------------------------------------
    input  wire [DIN_WIDTH-1:0]   maxpool_din0,
    input  wire [DIN_WIDTH-1:0]   maxpool_din1,
    input  wire [DIN_WIDTH-1:0]   maxpool_din2,
    input  wire [DIN_WIDTH-1:0]   maxpool_din3,

    // ---- Shared spatial config & control -----------------------------------
    input  wire [MAX_WIDTH-1:0]   img_width,
    input  wire [MAX_WIDTH-1:0]   img_height,

    input  wire                   maxpool_in_valid,
    input  wire [3:0]             pool_en,             // per-channel enable

    // ---- 4-channel pooled outputs ------------------------------------------
    output wire [DOUT_WIDTH-1:0]  maxpool_dout0,
    output wire [DOUT_WIDTH-1:0]  maxpool_dout1,
    output wire [DOUT_WIDTH-1:0]  maxpool_dout2,
    output wire [DOUT_WIDTH-1:0]  maxpool_dout3,

    // ---- Global valid flag ---- ------------------------------------
    output wire                   maxpool_flag
);

// =============================================================================
// Internal wires
// =============================================================================
wire [DOUT_WIDTH-1:0] dout_ch [0:3];
wire [3:0]            flag_ch;

// Pack channel inputs into an array for clean generate indexing
wire [DIN_WIDTH-1:0]  din_ch [0:3];
assign din_ch[0] = maxpool_din0;
assign din_ch[1] = maxpool_din1;
assign din_ch[2] = maxpool_din2;
assign din_ch[3] = maxpool_din3;

// =============================================================================
// 4-channel generate: one maxpool instance per channel
// =============================================================================
generate
    genvar i;
    for (i = 0; i < 4; i = i + 1) begin : gen_ch
        maxpool #(
            .DIN_WIDTH  (DIN_WIDTH ),
            .MAX_WIDTH  (MAX_WIDTH ),
            .DOUT_WIDTH (DOUT_WIDTH)
        ) u_maxpool (
            .clk        (clk               ),
            .rst_n      (rst_n             ),
            .din        (din_ch[i]         ),
            .img_width  (img_width         ),
            .img_height (img_height        ),
            .din_valid  (maxpool_in_valid  ),
            .pool_en    (pool_en[i]        ),
            .dout       (dout_ch[i]        ),
            .flag       (flag_ch[i]        )
        );
    end
endgenerate

// =============================================================================
// Output mapping
// =============================================================================
assign maxpool_dout0 = dout_ch[0];
assign maxpool_dout1 = dout_ch[1];
assign maxpool_dout2 = dout_ch[2];
assign maxpool_dout3 = dout_ch[3];

// Global flag
assign maxpool_flag = &flag_ch;

endmodule