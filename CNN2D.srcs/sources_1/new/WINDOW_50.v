`timescale 1ns / 1ps
module WINDOW_50#(
    parameter DIN_WIDTH  = 8,
    parameter DOUT_WIDTH = 8,
    parameter NUM        = 9
)
(
    input wire clk,
    input wire rst_n,

    input wire [DIN_WIDTH-1:0] din_select,
    input wire                 din_valid,
    input wire                 window_en,

    output reg                       window_out_valid,
    output wire [DOUT_WIDTH*NUM-1:0] window_out
);

reg [DOUT_WIDTH-1:0] window_out_ff [0:NUM-1];

reg [DIN_WIDTH-1:0]  cov_buffer0 [0:51];
reg [DIN_WIDTH-1:0]  cov_buffer1 [0:51];
reg [DIN_WIDTH-1:0]  cov_buffer2 [0:51];
reg [DIN_WIDTH-1:0]  cov_buffer3 [0:51];

reg [5:0] col;
reg [5:0] row;
reg window_out_valid_ff;

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        col <= 6'b0;
        row <= 6'b0;
    end
    else if(din_valid && window_en) begin
        if (col == 6'd49) begin
            if (row == 6'd61) begin
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
end

integer j;

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        for (j = 0; j < 9; j = j + 1) begin
            window_out_ff[j] <= 8'b0;
        end
    end
    else if(window_out_valid_ff)begin
        if (col == 6'b0) begin
            window_out_ff[0] <= 8'b0;
            window_out_ff[1] <= cov_buffer0[1];
            window_out_ff[2] <= cov_buffer0[2];
            window_out_ff[3] <= 8'b0;
            window_out_ff[4] <= cov_buffer1[1];
            window_out_ff[5] <= cov_buffer1[2];
            window_out_ff[6] <= 8'b0;
            window_out_ff[7] <= cov_buffer2[1];
            window_out_ff[8] <= cov_buffer2[2];
        end
        else if (col == 6'd49) begin
            window_out_ff[0] <= window_out_ff[1];
            window_out_ff[1] <= window_out_ff[2];
            window_out_ff[2] <= 8'b0;
            window_out_ff[3] <= window_out_ff[4];
            window_out_ff[4] <= window_out_ff[5];
            window_out_ff[5] <= 8'b0;
            window_out_ff[6] <= window_out_ff[7];
            window_out_ff[7] <= window_out_ff[8];
            window_out_ff[8] <= 8'b0;
        end
        else begin
            window_out_ff[0] <= window_out_ff[1];
            window_out_ff[1] <= window_out_ff[2];
            window_out_ff[2] <= cov_buffer0[2];
            window_out_ff[3] <= window_out_ff[4];
            window_out_ff[4] <= window_out_ff[5];
            window_out_ff[5] <= cov_buffer1[2];
            window_out_ff[6] <= window_out_ff[7];
            window_out_ff[7] <= window_out_ff[8];
            window_out_ff[8] <= cov_buffer2[2];
        end
    end
    else begin
        for (j = 0; j < 9; j = j + 1) begin
            window_out_ff[j] <= 8'b0;
        end
    end
end

assign window_out =  {window_out_ff[8],window_out_ff[7],window_out_ff[6],
                      window_out_ff[5],window_out_ff[4],window_out_ff[3],
                      window_out_ff[2],window_out_ff[1],window_out_ff[0]};

reg [3:0] cur_state;
reg [3:0] next_state;
localparam IDLE     = 4'b0000;
localparam INIT     = 4'b0010;
localparam COV      = 4'b0100;
localparam LAST_COV = 4'b1000;

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        cur_state <= IDLE;
    end
    else begin
        cur_state <= next_state;
    end
end

always @(*) begin
    case (cur_state)
        IDLE:begin
           next_state = window_en ? INIT : IDLE; 
        end
        INIT:begin
            if (col == 6'd49 && row == 6'd1) begin
                next_state = COV;
            end
            else next_state = INIT;
        end
        COV:begin
            if (col == 6'd49 && row == 6'd59) begin
                next_state = LAST_COV;
            end
            else next_state = COV;
        end
        LAST_COV:begin
            if (col == 6'd49 && row == 6'd61) begin
                next_state = IDLE;
            end
            else next_state = LAST_COV;
        end
        default:begin
            next_state = IDLE;
        end 
    endcase
end

integer i;

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        for (i = 0; i < 52; i = i + 1) begin
            cov_buffer0[i] <= 8'b0; 
            cov_buffer1[i] <= 8'b0; 
            cov_buffer2[i] <= 8'b0; 
            cov_buffer3[i] <= 8'b0; 
        end
    end
    else begin
        case (cur_state)
            IDLE:begin
                for (i = 0; i < 52; i = i + 1) begin
                    cov_buffer0[i] <= 8'b0; 
                    cov_buffer1[i] <= 8'b0; 
                    cov_buffer2[i] <= 8'b0; 
                    cov_buffer3[i] <= 8'b0; 
                end
            end
            INIT:begin
                for (i = 0; i < 52; i = i + 1) begin
                    cov_buffer0[i] <= 8'b0;  
                end
                cov_buffer1[0]  <= 8'b0;
                cov_buffer1[51] <= 8'b0;
                cov_buffer2[0]  <= 8'b0;
                cov_buffer2[51] <= 8'b0;
                cov_buffer3[0]  <= 8'b0;
                cov_buffer3[51] <= 8'b0;
                if(din_valid)begin
                    if (row[0] == 1'b0) begin
                        for (i = 2; i < 51 ; i = i + 1) begin
                            cov_buffer1[i-1] <= cov_buffer1[i];
                        end
                        cov_buffer1[50] <= din_select;
                    end
                    else if (row[0] == 1'b1) begin
                        for (i = 2; i < 51 ; i = i + 1) begin
                            cov_buffer2[i-1] <= cov_buffer2[i];
                        end
                        cov_buffer2[50] <= din_select;
                    end
                end
            end 
            COV:begin
                if(col == 6'd49)begin
                    for (i = 2; i < 51 ; i = i + 1) begin
                        cov_buffer0[i-1] <= cov_buffer1[i];
                        cov_buffer1[i-1] <= cov_buffer2[i];
                        cov_buffer2[i-1] <= cov_buffer3[i];
                    end
                    cov_buffer0[50] <= cov_buffer1[1];
                    cov_buffer1[50] <= cov_buffer2[1];
                    cov_buffer2[50] <= din_select;

                    cov_buffer0[0]  <= 8'b0;
                    cov_buffer0[51] <= 8'b0;
                    cov_buffer1[0]  <= 8'b0;
                    cov_buffer1[51] <= 8'b0;
                    cov_buffer2[0]  <= 8'b0;
                    cov_buffer2[51] <= 8'b0;
                    cov_buffer3[0]  <= 8'b0;
                    cov_buffer3[51] <= 8'b0;
                end
                else begin
                    for (i = 2; i < 52 ; i = i + 1) begin
                        cov_buffer0[i-1] <= cov_buffer0[i];
                        cov_buffer1[i-1] <= cov_buffer1[i];
                        cov_buffer2[i-1] <= cov_buffer2[i];
                        cov_buffer3[i-1] <= cov_buffer3[i];
                    end
                    cov_buffer0[50] <= cov_buffer0[1];
                    cov_buffer1[50] <= cov_buffer1[1];
                    cov_buffer2[50] <= cov_buffer2[1];
                    cov_buffer3[50] <= din_select;
                end
            end
            LAST_COV:begin
                for (i = 2; i < 51 ; i = i + 1) begin
                    cov_buffer0[i-1] <= cov_buffer0[i];
                    cov_buffer1[i-1] <= cov_buffer1[i];
                    cov_buffer2[i-1] <= 8'b0;
                end
            end
            default: begin
                for (i = 0; i < 52; i = i + 1) begin
                    cov_buffer0[i] <= 8'b0; 
                    cov_buffer1[i] <= 8'b0; 
                    cov_buffer2[i] <= 8'b0; 
                    cov_buffer3[i] <= 8'b0; 
                end
            end
        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        window_out_valid_ff <= 1'b0;
    end
    else if(col == 6'd49 && row == 6'd1) begin
        window_out_valid_ff <= 1'b1;
    end
    else if (col == 6'd49 && row == 6'd61) begin
        window_out_valid_ff <= 1'b0;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        window_out_valid <= 1'b0;
    end
    else begin
        window_out_valid <= window_out_valid_ff;
    end
end

endmodule