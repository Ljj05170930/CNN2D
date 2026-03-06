`timescale 1ns / 1ps
module tb_WINDOW_50();
localparam CLK_PERIOD = 100;          
localparam DIN_WIDTH  = 8;
localparam DOUT_WIDTH = 8;
localparam NUM        = 9;

localparam IMAGE_WIDTH  = 50;
localparam IMAGE_HEIGHT = 62;
localparam PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT; // 3100
localparam TOTAL_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT*16; // 3100*16

reg                             clk;
reg                             rst_n;
reg  [DIN_WIDTH-1:0]            din_select;
reg                             din_valid;
reg                             window_en;
wire                            window_out_valid;
wire [DOUT_WIDTH*NUM-1:0]       window_out;

reg [DIN_WIDTH-1:0]             data_ram [0:TOTAL_PIXELS-1];

WINDOW_50 #(
    .DIN_WIDTH (DIN_WIDTH),
    .DOUT_WIDTH(DOUT_WIDTH),
    .NUM       (NUM)
) dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .din_select     (din_select),
    .din_valid      (din_valid),
    .window_en      (window_en),
    .window_out_valid(window_out_valid),
    .window_out     (window_out)
);

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

initial begin
    integer addr;

    din_select = 0;
    din_valid  = 0;
    window_en  = 0;

    wait (rst_n == 1);
    #(CLK_PERIOD * 2);

    window_en = 1;
    addr = 0;
    #200
    while (addr < PIXELS) begin
        @(posedge clk);
        din_valid <= 1;
        din_select <= data_ram[addr];
        addr <= addr + 1;
    end

    @(posedge clk);
        din_valid <= 0;
        window_en <= 0;

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
            $fdisplay(fd, "%d", data);
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

    always @(posedge clk) begin
        if (cond) begin
            for (i = 0; i < PE_NUM; i = i + 1) begin
                $fdisplay(fd, "%0d", $signed(data[i]));
            end
            $fflush(fd);
        end
    end

endmodule
