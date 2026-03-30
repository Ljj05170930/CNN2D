`timescale 1ns / 1ps
module conv1D_data_select#(
    parameter DIN_WIDTH        = 8,
    parameter DOUT_WIDTH       = 8
)
(
    input wire                       clk,
    input wire                       rst_n,
    input wire [8:0]                 top_state,
    input wire                       conv1D_din_valid,
    input wire [DIN_WIDTH*4-1:0]     ram_out,

    output wire [DOUT_WIDTH*8*3-1:0] conv1D_select_dout,
    output wire                      control,
    output reg                       conv1D_dout_valid
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

reg [3:0] out_cnt;
always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        out_cnt <= 4'b0;
    end
    else begin
        case (top_state)
            LAYER4:begin
                if (conv1D_din_valid) begin
                    if (out_cnt == 4'd15) begin
                        out_cnt <= 4'b0;
                    end
                    else begin
                        out_cnt <= out_cnt + 1'b1;
                    end
                end
            end 
            LAYER5:begin
                if (conv1D_din_valid) begin
                    if (out_cnt == 4'd6) begin
                        out_cnt <= 4'b0;
                    end
                    else begin
                        out_cnt <= out_cnt + 1'b1;
                    end
                end
            end 
            default:out_cnt <= 4'b0;
        endcase
    end
end

assign control = (out_cnt == 5'd15 && top_state == LAYER4) || (out_cnt == 5'd6 && top_state == LAYER5);

wire [DIN_WIDTH-1:0] conv1D_din0, conv1D_din1, conv1D_din2, conv1D_din3;

reg [DIN_WIDTH-1:0] buffer_conv0 [0:3];
reg [DIN_WIDTH-1:0] buffer_conv1 [0:3];
reg [DIN_WIDTH-1:0] buffer_conv2 [0:3];
reg conv1D_valid_ff0, conv1D_valid_ff1;

assign {conv1D_din3, conv1D_din2, conv1D_din1, conv1D_din0} = conv1D_din_valid ? ram_out : 32'b0;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        conv1D_dout_valid <= 1'b0;
        conv1D_valid_ff0  <= 1'b0;
        conv1D_valid_ff1  <= 1'b0;
    end
    else if (control) begin
        conv1D_dout_valid <= conv1D_valid_ff1;
        conv1D_valid_ff0  <= 1'b0;
        conv1D_valid_ff1  <= 1'b0;
    end
    else begin
        conv1D_valid_ff0  <= conv1D_din_valid;
        conv1D_valid_ff1  <= conv1D_valid_ff0;
        conv1D_dout_valid <= conv1D_valid_ff1;
    end
end

integer i;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0;i < 4;i = i + 1) begin
            buffer_conv0[i] <= 8'b0;
            buffer_conv1[i] <= 8'b0;
            buffer_conv2[i] <= 8'b0;
        end
    end
    else if(conv1D_din_valid)begin
        for (i = 0;i < 4;i = i + 1) begin
            buffer_conv0[i] <= buffer_conv1[i];
            buffer_conv1[i] <= buffer_conv2[i];
        end
            buffer_conv2[0] <= conv1D_din0;
            buffer_conv2[1] <= conv1D_din1;
            buffer_conv2[2] <= conv1D_din2;
            buffer_conv2[3] <= conv1D_din3;
    end
    else begin
        for (i = 0;i < 4;i = i + 1) begin
            buffer_conv0[i] <= 8'b0;
            buffer_conv1[i] <= 8'b0;
            buffer_conv2[i] <= 8'b0;
        end
    end
end

assign conv1D_select_dout = {
    buffer_conv2[3], buffer_conv1[3], buffer_conv0[3],
    buffer_conv2[2], buffer_conv1[2], buffer_conv0[2],
    buffer_conv2[1], buffer_conv1[1], buffer_conv0[1],
    buffer_conv2[0], buffer_conv1[0], buffer_conv0[0],
    buffer_conv2[3], buffer_conv1[3], buffer_conv0[3],
    buffer_conv2[2], buffer_conv1[2], buffer_conv0[2],
    buffer_conv2[1], buffer_conv1[1], buffer_conv0[1],
    buffer_conv2[0], buffer_conv1[0], buffer_conv0[0]
};


endmodule