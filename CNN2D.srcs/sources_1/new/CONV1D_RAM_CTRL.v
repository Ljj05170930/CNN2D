module CONV1D_RAM_CTRL#(
    parameter DIN_WIDTH = 8,
    parameter DOUT_WIDTH = 8
)
(
    input wire                  clk,
    input wire                  rst_n,

    input wire [8:0]            top_state,
    input wire                  avg_dout_valid,
    input wire [DIN_WIDTH-1:0]  avg_pool_dout,

    output reg [5:0]            cov1D_ram_addr,
    output wire [DOUT_WIDTH*8-1:0] ram_out
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

wire [8*DIN_WIDTH-1:0] cov1D_ram_din;
reg                    cov1D_ram_wr;
reg  [2:0]             ram_cnt;

reg  [DIN_WIDTH-1:0] ram_din_mem[0:7];
integer i;
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        for (i = 0; i < 8; i = i + 1) begin
            ram_din_mem[i] <= 8'b0;
        end
    end
    else if(avg_dout_valid)begin
        ram_din_mem[ram_cnt] <= avg_pool_dout;
    end
end

generate
    genvar j;
    for (j = 0; j < 8; j = j + 1) begin
        assign cov1D_ram_din[DIN_WIDTH*j+:DIN_WIDTH] = ram_din_mem[j];
    end
endgenerate


always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        ram_cnt <= 3'b0;
    end
    else if(avg_dout_valid) begin
        ram_cnt <= ram_cnt + 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        cov1D_ram_addr <= 6'b0;
    end
    else if (cov1D_ram_wr) begin
        cov1D_ram_addr <= cov1D_ram_addr + 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(~rst_n)begin
        cov1D_ram_wr <= 1'b0;
    end
    else if(ram_cnt == 3'b111 && avg_dout_valid) begin
        cov1D_ram_wr <= 1'b1;
    end
    else begin
        cov1D_ram_wr <= 1'b0;
    end
end

(* dont_touch = "true" *)
CONV1D_RAM u_CONV1D_RAM(
    .clka  (clk           ),
    .ena   (1'b1          ),
    .wea   (cov1D_ram_wr  ),
    .addra (cov1D_ram_addr),
    .dina  (cov1D_ram_din ),
    .douta (ram_out       )
);



endmodule