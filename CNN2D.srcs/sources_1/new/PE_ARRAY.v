`timescale 1ns / 1ps
module PE_ARRAY#(
    parameter DIN_WIDTH   = 8,
    parameter DOUT_WIDTH  = 8,
    parameter BIAS_WIDTH  = 12,
    parameter SCALE_WIDTH = 3,
    parameter NUM         = 9
)
(
    input wire clk,
    input wire rst_n,

    input wire [DIN_WIDTH-1:0] pe_din,

    
);

endmodule
