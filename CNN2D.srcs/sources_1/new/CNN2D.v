`timescale 1ns / 1ps
module CNN2D#(
    parameter DIN_WIDTH   = 8,
    parameter DOUT_WIDTH  = 8,
    parameter BIAS_WIDTH  = 12,
    parameter SCALE_WIDTH = 3,
    parameter NUM         = 9
)
(
    input wire clk,
    input wire rst_n,

    input wire [DIN_WIDTH-1:0] din,
    input wire din_valid,

    output wire [DOUT_WIDTH-1:0] dout,
    output wire dout_valid
);




endmodule
