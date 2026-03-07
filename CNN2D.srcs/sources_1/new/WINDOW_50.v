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

reg [DOUT_WIDTH-1:0] win [0:8];

assign window_out = {
    win[8], win[7], win[6],   
    win[5], win[4], win[3],   
    win[2], win[1], win[0]    
};

reg window_out_valid_ff;
reg [5:0] col;
reg [5:0] row;

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


reg  [5:0]           bram_waddr;
reg  [DIN_WIDTH-1:0] bram_wdata;
reg                  bram_we    [0:3];
wire [DIN_WIDTH-1:0] bram_dout  [0:3];
reg  [5:0]           bram_raddr;

LINE_RAM u_LINE_RAM_0 (
    .clka   (clk),
    .ena    (1'b1),
    .wea    (bram_we[0]),
    .addra  (bram_we[0] ? bram_waddr : bram_raddr),
    .dina   (bram_wdata),
    .douta  (bram_dout[0])
);

LINE_RAM u_LINE_RAM_1 (
    .clka   (clk),
    .ena    (1'b1),
    .wea    (bram_we[1]),
    .addra  (bram_we[1] ? bram_waddr : bram_raddr),
    .dina   (bram_wdata),
    .douta  (bram_dout[1])
);

LINE_RAM u_LINE_RAM_2 (
    .clka   (clk),
    .ena    (1'b1),
    .wea    (bram_we[2]),
    .addra  (bram_we[2] ? bram_waddr : bram_raddr),
    .dina   (bram_wdata),
    .douta  (bram_dout[2])
);

LINE_RAM u_LINE_RAM_3 (
    .clka   (clk),
    .ena    (1'b1),
    .wea    (bram_we[3]),
    .addra  (bram_we[3] ? bram_waddr : bram_raddr),
    .dina   (bram_wdata),
    .douta  (bram_dout[3])
);

reg [1:0] buf_sel;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        buf_sel <= 2'd1;
    end else if (din_valid && window_en && col == 6'd49) begin
        buf_sel <= buf_sel + 2'd1;
    end
end

always @(*) begin
    bram_waddr = col;
    bram_wdata = din_select;
    case (buf_sel)
        2'b00:begin
            bram_we[0] = 1'b1;
            bram_we[1] = 1'b0;
            bram_we[2] = 1'b0;
            bram_we[3] = 1'b0;
        end
        2'b01:begin
            bram_we[0] = 1'b0;
            bram_we[1] = 1'b1;
            bram_we[2] = 1'b0;
            bram_we[3] = 1'b0;
        end
        2'b10:begin
            bram_we[0] = 1'b0;
            bram_we[1] = 1'b0;
            bram_we[2] = 1'b1;
            bram_we[3] = 1'b0;
        end
        2'b11:begin
            bram_we[0] = 1'b0;
            bram_we[1] = 1'b0;
            bram_we[2] = 1'b0;
            bram_we[3] = 1'b1;
        end
        default: begin
            bram_we[0] = 1'b0;
            bram_we[1] = 1'b0;
            bram_we[2] = 1'b0;
            bram_we[3] = 1'b0;
        end
    endcase
end

reg [DIN_WIDTH-1:0] head [0:7];
integer i;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0;i < 8;i = i + 1) begin
            head[i] <= 8'b0;
        end
    end
    else if (din_valid && window_en) begin
        if (col == 6'd0)begin
            head[{buf_sel, 1'b0}] <= din_select;
        end
        else if (col == 6'd1)begin
            head[{buf_sel, 1'b1}] <= din_select;
        end
    end
    else begin
        for (i = 0;i < 8;i = i + 1) begin
            head[i] <= 8'b0;
        end
    end
end

wire [1:0] bidx_top = buf_sel - 2'd3;
wire [1:0] bidx_mid = buf_sel - 2'd2;
wire [1:0] bidx_bot = buf_sel - 2'd1;

always @(*) begin
    bram_raddr = col + 2'd2;
end

wire [DIN_WIDTH-1:0] rd_top = bram_dout[bidx_top];
wire [DIN_WIDTH-1:0] rd_mid = bram_dout[bidx_mid];
wire [DIN_WIDTH-1:0] rd_bot = bram_dout[bidx_bot];

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        win[0]<=8'd0; win[1]<=8'd0; win[2]<=8'd0;
        win[3]<=8'd0; win[4]<=8'd0; win[5]<=8'd0;
        win[6]<=8'd0; win[7]<=8'd0; win[8]<=8'd0;
    end
    else if(col == 6'd0)begin
        win[0] <= 8'd0;
        win[1] <= head[{bidx_top, 1'b0}];
        win[2] <= head[{bidx_top, 1'b1}];
        win[3] <= 8'd0;
        win[4] <= head[{bidx_mid, 1'b0}];
        win[5] <= head[{bidx_mid, 1'b1}];
        win[6] <= 8'd0;
        win[7] <= row == 6'd61 ? 8'd0 : head[{bidx_bot, 1'b0}];
        win[8] <= row == 6'd61 ? 8'd0 : head[{bidx_bot, 1'b1}];
    end 
    else begin
        win[0] <= win[1];
        win[1] <= win[2];
        win[2] <= (col == 6'd49 || row == 6'd1) ? 8'd0 : rd_top;
        // 中行
        win[3] <= win[4];
        win[4] <= win[5];
        win[5] <= (col == 6'd49) ? 8'd0 : rd_mid;
        // 下行
        win[6] <= win[7];
        win[7] <= win[8];
        win[8] <= (col == 6'd49|| row == 6'd61) ? 8'd0 : rd_bot;
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

endmodule