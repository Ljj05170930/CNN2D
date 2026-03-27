`timescale 1ns / 1ps
module tb_CNN2D;
localparam CLK_PERIOD = 10;          
localparam DIN_WIDTH  = 8;
localparam DOUT_WIDTH = 8;
localparam NUM        = 9;
localparam MAX_WIDTH  = 6;

localparam IMAGE_WIDTH  = 50;
localparam IMAGE_HEIGHT = 62;
localparam PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT; // 3100
localparam TOTAL_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT*16; // 3100*16

reg                             clk;
reg                             rst_n;
reg  [DIN_WIDTH-1:0]            din_select;
reg                             din_valid;
reg                             cnn_start;

reg [DIN_WIDTH-1:0]             data_ram [0:TOTAL_PIXELS-1];

CNN2D u_CNN2D(
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .cnn_start  (cnn_start  ),
    .din        (din_select ),
    .din_valid  (din_valid  ),
    .dout(),
    .dout_valid()
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

always #(CLK_PERIOD/2) clk = ~clk;

initial begin
    clk = 1;
    rst_n = 0;
    #(200);          // 保持复位 200 ns
    rst_n = 1;
end

task automatic open_file_w;
    output integer fd;
    input  string  filepath;
    begin
    fd = $fopen(filepath, "w");
    if (!fd) begin
        $display("ERROR: cannot open file %s", filepath);
        $finish;
    end
    end
endtask

task automatic open_file_r;
    output integer fd;
    input  string  filepath;
    begin
    fd = $fopen(filepath, "r");
    if (!fd) begin
        $display("ERROR: cannot open file %s", filepath);
        $finish;
    end
    end
endtask

integer DATA_STORE, x1;
initial begin
    open_file_r(
        .fd(DATA_STORE),
        .filepath("../../../../data/layer_0_input.txt")
    );
    for (int i = 0; i < 3100*16; i=i+1) begin
        x1 = $fscanf(DATA_STORE, "%d", data_ram[i]);
    end
    $fclose(DATA_STORE);
end

integer layer_0_mid;
integer layer_0_out;
integer layer_1_out;
integer layer_2_out;
integer layer_3_out;
integer layer_3_mid;
initial begin
    open_file_w(
        .fd(layer_0_mid),
        .filepath("../../../../DUT/layer_0_mid.txt")
    );
    open_file_w(
        .fd(layer_0_out),
        .filepath("../../../../DUT/layer_0_out.txt")
    );
    open_file_w(
        .fd(layer_1_out),
        .filepath("../../../../DUT/layer_1_out.txt")
    );
    open_file_w(
        .fd(layer_2_out),
        .filepath("../../../../DUT/layer_2_out.txt")
    );
    open_file_w(
        .fd(layer_3_out),
        .filepath("../../../../DUT/layer_3_out.txt")
    );
    open_file_w(
        .fd(layer_3_mid),
        .filepath("../../../../DUT/layer_3_mid.txt")
    );
end

dump_if_dec #(.WIDTH(20)) 
u_dump_layer0_mid (
    .clk  (clk),
    .fd   (layer_0_mid),
    .cond (u_CNN2D.maxpool_valid_ff && u_CNN2D.top_state == LAYER0),
    .data (u_CNN2D.u_scale_relu_layer.scale_4channel[0].u_scale_relu.dout_reg)
);

dump_array_if #(
    .POOL_WIDTH(8),
    .PE_NUM    (4)
) u_dump_layer_0_out (
    .clk (clk),
    .fd  (layer_0_out),
    .cond(u_CNN2D.maxpool_flag && u_CNN2D.top_state == LAYER0),
    .data(u_CNN2D.maxpool_dout_all)
);

dump_if_dec #(.WIDTH(8)) 
u_dump_layer1_mid (
    .clk  (clk),
    .fd   (layer_1_out),
    .cond(u_CNN2D.maxpool_flag && u_CNN2D.top_state == LAYER1),
    .data (u_CNN2D.maxpool_dout0)
);

dump_if_dec #(.WIDTH(8)) 
u_dump_layer2_out (
    .clk  (clk),
    .fd   (layer_2_out),
    .cond(u_CNN2D.maxpool_flag && u_CNN2D.top_state == LAYER2),
    .data (u_CNN2D.maxpool_dout0)
);

dump_if_dec #(.WIDTH(8)) 
u_dump_layer3_out (
    .clk  (clk),
    .fd   (layer_3_out),
    .cond(u_CNN2D.avg_dout_valid),
    .data (u_CNN2D.avg_pool_dout)
);

dump_if_dec #(.WIDTH(20)) 
u_dump_layer3_mid (
    .clk  (clk),
    .fd   (layer_3_mid),
    .cond (u_CNN2D.maxpool_valid_ff && u_CNN2D.top_state == LAYER3),
    .data (u_CNN2D.u_scale_relu_layer.scale_4channel[0].u_scale_relu.dout_reg)
);


initial begin
    integer addr;
    integer i;
    din_select = 0;
    din_valid  = 0;
    cnn_start  = 0;
    wait (rst_n == 1);
    #(CLK_PERIOD * 2);

    cnn_start = 1;
    addr = 0;
    i = 0;
    #200
    repeat(16) begin
        while (addr < PIXELS) begin
            @(posedge clk);
            #5
            din_valid <= 1;
            din_select <= data_ram[addr+i*3100];
            addr <= addr + 1;
        end
        din_select  <= 0;
        din_valid <= 0;
        i <= i + 1;
        addr <= 0;
        #120000;
    end
end



endmodule

module dump_if_dec #(
    parameter int WIDTH = 1024
)(
    input  logic        clk,
    input  integer      fd,
    input  bit          cond,
    input  logic signed [WIDTH-1:0] data
);
    always @(posedge clk) begin
        if (cond) begin
            $fdisplay(fd, "%0d", data);
            $fflush(fd);
        end
    end
endmodule

module dump_array_if #(
    parameter int POOL_WIDTH = 8,
    parameter int PE_NUM     = 16
)(
    input  logic                  clk,
    input  integer                fd,
    input  bit                    cond,
    input  logic [POOL_WIDTH-1:0] data [0:PE_NUM-1]
);
    integer i;

    // always @(posedge clk) begin
    //     if (cond) begin
    //         for (i = 0; i < PE_NUM; i = i + 1) begin
    //             $fdisplay(fd, "%0d", $signed(data[i]));
    //         end
    //         $fflush(fd);
    //     end
    // end
    always @(posedge clk) begin
        if (cond) begin
            for (i = 0; i < PE_NUM; i = i + 1) begin
                $fdisplay(fd, "%0d", (data[i]));
            end
            $fflush(fd);
        end
    end

endmodule
