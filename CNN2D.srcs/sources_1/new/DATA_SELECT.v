`timescale 1ns / 1ps
module DATA_SELECT#(
    parameter DIN_WIDTH  = 8,
    parameter DOUT_WIDTH = 8,
    parameter NUM        = 9
)

(
    input wire clk,
    input wire rst_n,

    input wire [DIN_WIDTH-1:0] select_din0,
    input wire [DIN_WIDTH-1:0] select_din1,
    input wire [DIN_WIDTH-1:0] select_din2,
    input wire [DIN_WIDTH-1:0] select_din3


);


endmodule
