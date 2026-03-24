`timescale 1ns / 1ps
module scale_relu_layer#(
    parameter SCALE_IN_WIDTH = 20,
    parameter DOUT_WIDTH     = 8,
    parameter BIAS_WIDTH     = 12,
    parameter SCALE_WIDTH    = 3
)
(
    input wire clk,
    input wire rst_n,
    input wire [8:0]top_state,
    input wire shift_en,

    input wire [SCALE_WIDTH-1:0]       scale,
    input wire signed [BIAS_WIDTH-1:0] bias,
    input wire signed [SCALE_IN_WIDTH*4-1:0] scale_din,
    output wire [DOUT_WIDTH*4-1:0] scale_dout
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

reg [BIAS_WIDTH-1:0]  bias_reg [3:0];
reg [SCALE_WIDTH-1:0] scale_reg[3:0];

integer j;
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        for (j = 0; j < 4; j = j + 1) begin
            bias_reg[j] <= 12'b0;
            scale_reg[j] <= 3'b0;
        end
    end
    else begin
        case (top_state)
            IDLE:begin
                for (j = 0; j < 4; j = j + 1) begin
                    bias_reg[j] <= 12'b0;
                    scale_reg[j] <= 3'b0;
                end
            end 
            LAYER0:begin
                if (shift_en) begin
                    for (j = 0; j < 3; j = j + 1) begin
                        bias_reg[j+1]  <= bias_reg[j];
                        scale_reg[j+1] <= scale_reg[j];
                    end
                    bias_reg[0]  <= bias;
                    scale_reg[0] <= scale;
                end
            end
            LAYER1,LAYER2,LAYER3,LAYER7:begin
                for (j = 0; j < 4; j = j + 1) begin
                    bias_reg[j] <= bias;
                    scale_reg[j] <= scale;
                end
            end
            default: begin
                for (j = 0; j < 4; j = j + 1) begin
                    bias_reg[j] <= 12'b0;
                    scale_reg[j] <= 3'b0;
                end
            end
        endcase
    end
end

generate
    genvar i;
    for (i = 0; i < 4; i = i + 1) begin : scale_4channel
        scale_relu #(
            .SCALE_IN_WIDTH (SCALE_IN_WIDTH),
            .DOUT_WIDTH     (DOUT_WIDTH),
            .BIAS_WIDTH     (BIAS_WIDTH),
            .SCALE_WIDTH    (SCALE_WIDTH)
        ) u_scale_relu (
            .scale (scale_reg [i]  ),
            .bias  (bias_reg  [i]  ),
            .din   (scale_din [i*SCALE_IN_WIDTH+:SCALE_IN_WIDTH]),
            .dout  (scale_dout[i*SCALE_WIDTH+:SCALE_WIDTH])
        );
    end
endgenerate

endmodule
