`timescale 1ns / 1ps
module DATA_FLOW#(
    parameter DIN_WIDTH        = 8,
    parameter DOUT_WIDTH       = 8,
    parameter SCALE_IN_WIDTH   = 20,
    parameter DOUT_WIDTH_1D    = 14,
    parameter DOUT_WIDTH_2D    = 16,
    parameter NUM              = 9
)
(
    input wire clk,
    input wire rst_n,
    input wire [8:0] top_state,
    input wire maxpool_in_valid,
    input wire [DIN_WIDTH-1:0] din,
    input wire [1:0] sram_write_select,

    input wire [DIN_WIDTH*NUM-1:0] select_dout0,
    input wire [DIN_WIDTH*NUM-1:0] select_dout1,
    input wire [DIN_WIDTH*NUM-1:0] select_dout2,
    input wire [DIN_WIDTH*NUM-1:0] select_dout3,
    input wire [DOUT_WIDTH*8*3-1:0] conv1D_select_dout,
    input wire [32*DOUT_WIDTH-1:0] fc_din,
    output reg [DIN_WIDTH*NUM-1:0] conv_din0,
    output reg [DIN_WIDTH*NUM-1:0] conv_din1,
    output reg [DIN_WIDTH*NUM-1:0] conv_din2,
    output reg [DIN_WIDTH*NUM-1:0] conv_din3,

    output reg  [DIN_WIDTH-1:0]  select_din0,     
    output reg  [DIN_WIDTH-1:0]  select_din1,
    output reg  [DIN_WIDTH-1:0]  select_din2,
    output reg  [DIN_WIDTH-1:0]  select_din3,

    input wire signed [DOUT_WIDTH_2D-1:0] conv_2D_dout0,
    input wire signed [DOUT_WIDTH_2D-1:0] conv_2D_dout1,
    input wire signed [DOUT_WIDTH_2D-1:0] conv_2D_dout2,
    input wire signed [DOUT_WIDTH_2D-1:0] conv_2D_dout3,
    input wire signed [DOUT_WIDTH_1D*3*4-1:0] conv1D_dout,
    output wire signed [SCALE_IN_WIDTH*4-1:0] scale_din,

    input wire [DIN_WIDTH-1:0] sram_dout0,
    input wire [DIN_WIDTH-1:0] sram_dout1,
    input wire [DIN_WIDTH-1:0] sram_dout2,
    input wire [DIN_WIDTH-1:0] sram_dout3,
    input wire [DIN_WIDTH-1:0] sram_dout4,
    input wire [DIN_WIDTH-1:0] sram_dout5,
    input wire [DIN_WIDTH-1:0] sram_dout6,
    input wire [DIN_WIDTH-1:0] sram_dout7,

    input wire [DIN_WIDTH-1:0] maxpool_dout0,
    input wire [DIN_WIDTH-1:0] maxpool_dout1,
    input wire [DIN_WIDTH-1:0] maxpool_dout2,
    input wire [DIN_WIDTH-1:0] maxpool_dout3,
    output reg [DOUT_WIDTH-1:0] sram_din0,
    output reg [DOUT_WIDTH-1:0] sram_din1,
    output reg [DOUT_WIDTH-1:0] sram_din2,
    output reg [DOUT_WIDTH-1:0] sram_din3,
    output reg [DOUT_WIDTH-1:0] sram_din4,
    output reg [DOUT_WIDTH-1:0] sram_din5,
    output reg [DOUT_WIDTH-1:0] sram_din6,
    output reg [DOUT_WIDTH-1:0] sram_din7

);
wire signed [DOUT_WIDTH_1D-1:0] conv1D_dout_part0, conv1D_dout_part1, conv1D_dout_part2, conv1D_dout_part3;
wire signed [DOUT_WIDTH_1D-1:0] conv1D_dout_part4, conv1D_dout_part5, conv1D_dout_part6, conv1D_dout_part7;    
assign {conv1D_dout_part7, conv1D_dout_part6, conv1D_dout_part5, conv1D_dout_part4, 
        conv1D_dout_part3, conv1D_dout_part2, conv1D_dout_part1, conv1D_dout_part0} = conv1D_dout[DOUT_WIDTH_1D*8-1:0];
reg signed [SCALE_IN_WIDTH-1:0] scale_din_ff [0:3];
assign scale_din = {scale_din_ff[3],scale_din_ff[2],scale_din_ff[1],scale_din_ff[0]};

localparam IDLE   = 9'b000000001;
localparam LAYER0 = 9'b000000010;
localparam LAYER1 = 9'b000000100;
localparam LAYER2 = 9'b000001000;
localparam LAYER3 = 9'b000010000;
localparam LAYER4 = 9'b000100000;
localparam LAYER5 = 9'b001000000;
localparam LAYER6 = 9'b010000000;
localparam LAYER7 = 9'b100000000;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        select_din0 <= 8'b0;
        select_din1 <= 8'b0;
        select_din2 <= 8'b0;
        select_din3 <= 8'b0;
    end 
    else begin
        case (top_state)
            IDLE: begin
                select_din0 <= 8'b0;
                select_din1 <= 8'b0;
                select_din2 <= 8'b0;
                select_din3 <= 8'b0;
            end 
            LAYER0: begin
                select_din0 <= din;
                select_din1 <= 8'b0;
                select_din2 <= 8'b0;
                select_din3 <= 8'b0;
            end
            LAYER1: begin
                select_din0 <= sram_dout0;
                select_din1 <= sram_dout1;
                select_din2 <= sram_dout2;
                select_din3 <= sram_dout3;
            end
            LAYER2: begin
                select_din0 <= sram_dout4;
                select_din1 <= sram_dout5;
                select_din2 <= sram_dout6;
                select_din3 <= sram_dout7;
            end
            LAYER3: begin
                select_din0 <= sram_dout0;
                select_din1 <= sram_dout1;
                select_din2 <= sram_dout2;
                select_din3 <= sram_dout3;
            end
            default: begin
                select_din0 <= 8'b0;
                select_din1 <= 8'b0;
                select_din2 <= 8'b0;
                select_din3 <= 8'b0;
            end
        endcase
    end 
end

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
        LAYER4:begin
            conv_din0 = conv1D_select_dout[DIN_WIDTH*NUM-1:0];
            conv_din1 = conv1D_select_dout[DIN_WIDTH*NUM*2-1:DIN_WIDTH*NUM];
            conv_din2 = {24'b0,conv1D_select_dout[DIN_WIDTH*8*3-1:DIN_WIDTH*NUM*2]};
            conv_din3 = 72'b0;
        end
       LAYER5:begin
            conv_din0 = conv1D_select_dout[DIN_WIDTH*NUM-1:0];
            conv_din1 = conv1D_select_dout[DIN_WIDTH*NUM*2-1:DIN_WIDTH*NUM];
            conv_din2 = {24'b0,conv1D_select_dout[DIN_WIDTH*8*3-1:DIN_WIDTH*NUM*2]};
            conv_din3 = 72'b0;
        end
        LAYER6,LAYER7:begin
            conv_din0 = fc_din[DIN_WIDTH*NUM-1:0];
            conv_din1 = fc_din[DIN_WIDTH*NUM*2-1:DIN_WIDTH*NUM];
            conv_din2 = fc_din[DIN_WIDTH*NUM*3-1:2*DIN_WIDTH*NUM];
            conv_din3 = {32'b0,fc_din[32*DIN_WIDTH-1:3*DIN_WIDTH*NUM]};
        end
        default: begin
            conv_din0 = 72'b0;
            conv_din1 = 72'b0;
            conv_din2 = 72'b0;
            conv_din3 = 72'b0;
        end
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        scale_din_ff[0] <= 20'b0;
        scale_din_ff[1] <= 20'b0;
        scale_din_ff[2] <= 20'b0;
        scale_din_ff[3] <= 20'b0;
    end 
    else if (maxpool_in_valid) begin
        case (top_state)
            LAYER0: begin
                scale_din_ff[0] <= conv_2D_dout0;
                scale_din_ff[1] <= conv_2D_dout1;
                scale_din_ff[2] <= conv_2D_dout2;
                scale_din_ff[3] <= conv_2D_dout3;
            end
            LAYER1: begin
                scale_din_ff[0] <= conv_2D_dout0 + conv_2D_dout1 + conv_2D_dout2 + conv_2D_dout3;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER2: begin
                scale_din_ff[0] <= conv_2D_dout0 + conv_2D_dout1 + conv_2D_dout2 + conv_2D_dout3;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER3: begin
                scale_din_ff[0] <= conv_2D_dout0 + conv_2D_dout1 + conv_2D_dout2 + conv_2D_dout3;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER4:begin
                scale_din_ff[0] <= conv1D_dout_part0 + conv1D_dout_part1 + conv1D_dout_part2 + conv1D_dout_part3;
                scale_din_ff[1] <= conv1D_dout_part4 + conv1D_dout_part5 + conv1D_dout_part6 + conv1D_dout_part7;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER5:begin
                scale_din_ff[0] <= conv1D_dout_part0 + conv1D_dout_part1 + conv1D_dout_part2 + conv1D_dout_part3;
                scale_din_ff[1] <= conv1D_dout_part4 + conv1D_dout_part5 + conv1D_dout_part6 + conv1D_dout_part7;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER6:begin
                scale_din_ff[0] <= conv_2D_dout0 + conv_2D_dout1 + conv_2D_dout2 + conv_2D_dout3;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
            LAYER7:begin
                scale_din_ff[0] <= conv_2D_dout0 + conv_2D_dout1 + conv_2D_dout2 + conv_2D_dout3;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end 
            default: begin
                scale_din_ff[0] <= 20'b0;
                scale_din_ff[1] <= 20'b0;
                scale_din_ff[2] <= 20'b0;
                scale_din_ff[3] <= 20'b0;
            end
        endcase
    end 
    else begin 
        scale_din_ff[0] <= 20'b0;
        scale_din_ff[1] <= 20'b0;
        scale_din_ff[2] <= 20'b0;
        scale_din_ff[3] <= 20'b0;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        sram_din0 <= 8'b0;
        sram_din1 <= 8'b0;
        sram_din2 <= 8'b0;
        sram_din3 <= 8'b0;
        sram_din4 <= 8'b0;
        sram_din5 <= 8'b0;
        sram_din6 <= 8'b0;
        sram_din7 <= 8'b0;
    end
    else begin
        case (top_state)
            IDLE:begin
                sram_din0 <= 8'b0;
                sram_din1 <= 8'b0;
                sram_din2 <= 8'b0;
                sram_din3 <= 8'b0;
                sram_din4 <= 8'b0;
                sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;
                sram_din7 <= 8'b0;
            end 
            LAYER0:begin
                sram_din0 <= maxpool_dout0;
                sram_din1 <= maxpool_dout1;
                sram_din2 <= maxpool_dout2;
                sram_din3 <= maxpool_dout3;
                sram_din4 <= 8'b0;
                sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;
                sram_din7 <= 8'b0;
            end
            LAYER1:begin
                sram_din0 <= 8'b0;
                sram_din1 <= 8'b0;
                sram_din2 <= 8'b0;
                sram_din3 <= 8'b0;
                case (sram_write_select)
                    2'b00: sram_din4 <= maxpool_dout0;
                    2'b01: sram_din5 <= maxpool_dout0;
                    2'b10: sram_din6 <= maxpool_dout0;
                    2'b11: sram_din7 <= maxpool_dout0;
                    default: begin
                        sram_din4 <= 8'b0;
                        sram_din5 <= 8'b0;
                        sram_din6 <= 8'b0;
                        sram_din7 <= 8'b0;
                    end
                endcase
            end
            LAYER2:begin
                case (sram_write_select)
                    2'b00: sram_din0 <= maxpool_dout0;
                    2'b01: sram_din1 <= maxpool_dout0;
                    2'b10: sram_din2 <= maxpool_dout0;
                    2'b11: sram_din3 <= maxpool_dout0;
                    default: begin
                        sram_din1 <= 8'b0;
                        sram_din2 <= 8'b0;
                        sram_din3 <= 8'b0;
                        sram_din4 <= 8'b0;
                    end
                endcase
                sram_din4 <= 8'b0;
                sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;
                sram_din7 <= 8'b0;
            end
            default: begin
                sram_din0 <= 8'b0;
                sram_din1 <= 8'b0;
                sram_din2 <= 8'b0;
                sram_din3 <= 8'b0;
                sram_din4 <= 8'b0;
                sram_din5 <= 8'b0;
                sram_din6 <= 8'b0;
                sram_din7 <= 8'b0;
            end
        endcase
    end
end


endmodule