`timescale 1ns / 1ps
module CTRL#(
    parameter MAX_WIDTH  = 6,
    parameter SRAM_WIDTH = 10,
    parameter DIN_WIDTH  = 8
)
(
    input wire                                     clk,
    input wire                                     rst_n,
    input wire                                     cnn_start,

    output reg  [MAX_WIDTH-1:0]                    img_width, 
    output reg  [MAX_WIDTH-1:0]                    img_height
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

reg [8:0] current_state, next_state;
reg layer0_ready, layer1_ready, layer2_ready, layer3_ready;
reg [SRAM_WIDTH-1:0] sram_write_num, sram_read_num;
reg [5:0]            sram_write_id;
reg [1:0]            sram_write_select;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        current_state <= IDLE;
    end 
    else begin
        current_state <= next_state;
    end
end

always @(*) begin
    case (current_state)
        IDLE:   next_state = cnn_start ? LAYER0 : IDLE;
        LAYER0: next_state = layer0_ready ? LAYER1 : LAYER0;
        LAYER1: next_state = layer1_ready ? LAYER2 : LAYER1;
        LAYER2: next_state = layer2_ready ? LAYER3 : LAYER2;
        default: next_state = IDLE;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        img_height <= 6'b0;
        img_width  <= 6'b0;
    end 
    else begin
        case (current_state)
            IDLE: begin
                img_height <= 6'b0;
                img_width  <= 6'b0;
            end 
            LAYER0: begin
                img_height <= 6'd62;
                img_width  <= 6'd50;
            end
            LAYER1: begin
                img_height <= 6'd31;
                img_width  <= 6'd25;
            end
            LAYER2: begin
                img_height <= 6'd15;
                img_width  <= 6'd12;
            end
            LAYER3: begin
                img_height <= 6'd7;
                img_width  <= 6'd6;

            end  
            LAYER4:begin
                img_height <= 6'd1;
                img_width  <= 6'd16;
            end
            default: begin
                img_height <= 6'b0;
                img_width  <= 6'b0;
            end
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        sram_write_select <= 2'b0;
        sram_write_id     <= 6'b0;
        sram_write_num    <= 10'b0;
        layer0_ready      <= 1'b0;
        layer1_ready      <= 1'b0;
        layer2_ready      <= 1'b0;
        layer3_ready      <= 1'b0;
    end 
    else begin
        
    end
    // else begin
    //     sram_write_num    <= sram_write_num;
    //     sram_write_id     <= sram_write_id;
    //     sram_write_select <= sram_write_select;
    //     layer0_ready      <= 1'b0;
    //     layer1_ready      <= 1'b0;
    //     layer2_ready      <= 1'b0;
    //     layer3_ready      <= 1'b0;
    // end
end




endmodule
