`timescale 1ns / 1ps
module DATA_FLOW#(
    parameter DIN_WIDTH        = 8,
    parameter DOUT_WIDTH       = 8,
    parameter NUM              = 9
)
(
    input wire clk,
    input wire rst_n,
    input wire [8:0] top_state,
    input wire [DIN_WIDTH-1:0] din,

    input wire [DIN_WIDTH-1:0] select_dout0,
    input wire [DIN_WIDTH-1:0] select_dout1,
    input wire [DIN_WIDTH-1:0] select_dout2,
    input wire [DIN_WIDTH-1:0] select_dout3,

    output reg [DIN_WIDTH*9-1:0] conv_din0,
    output reg [DIN_WIDTH*9-1:0] conv_din1,
    output reg [DIN_WIDTH*9-1:0] conv_din2,
    output reg [DIN_WIDTH*9-1:0] conv_din3
);

localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;
localparam LAYER5 = 9'b001000000;
localparam LAYER6 = 9'b010000000;
localparam LAYER7 = 9'b100000000;


always @(*) begin
    case (top_state)
        LAYER0:begin
            conv_din0 = select_dout0;
            conv_din1 = select_dout0;
            conv_din2 = select_dout0;
            conv_din3 = select_dout0;
        end 
        LAYER1:begin
            conv_din0 = select_dout0;
            conv_din1 = select_dout1;
            conv_din2 = select_dout2;
            conv_din3 = select_dout3;
        end
        LAYER2:begin
            conv_din0 = select_dout0;
            conv_din1 = select_dout1;
            conv_din2 = select_dout2;
            conv_din3 = select_dout3;
        end
        LAYER3:begin
            conv_din0 = select_dout0;
            conv_din1 = select_dout1;
            conv_din2 = select_dout2;
            conv_din3 = select_dout3;
        end
        default: begin
            conv_din0 = 72'b0;
            conv_din1 = 72'b0;
            conv_din2 = 72'b0;
            conv_din3 = 72'b0;
        end
    endcase
end

endmodule