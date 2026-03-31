`timescale 1ns / 1ps
// =============================================================================
// Module  : CNN_top
// Function: Top-level integration wrapper for the Radar-AI CNN accelerator.
//           Connects the behaviour-difference detector (bdd) to the 2-D CNN
//           pipeline (CNN2D) with a simple start/stop handshake:
//             · bdd monitors the raw pixel stream and asserts trigger_pluse
//               when ascending motion is detected across a frame window.
//             · trigger_pluse sets cnn_start, which arms the CNN2D pipeline.
//             · cnn_start is held high until CNN2D asserts dout_valid,
//               indicating that inference is complete.
//           The same din / din_valid stream is shared by both sub-modules.
// =============================================================================
module CNN_top #(
    parameter DIN_WIDTH  = 8,   // Input pixel bit-width
    parameter DOUT_WIDTH = 8    // CNN classification output bit-width
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- Pixel stream input (shared by bdd and CNN2D) ----------------------
    input  wire [DIN_WIDTH-1:0]   din,
    input  wire                   din_valid,

    // ---- CNN inference result ----------------------------------------------
    output wire [DOUT_WIDTH-1:0]  dout,       // Classification output
    output wire                   dout_valid  // One-cycle pulse: inference done
);

// =============================================================================
// bdd → CNN2D start handshake
// trigger_pluse : one-cycle pulse from bdd when motion criterion is met
// cnn_start     : level signal; set by trigger_pluse, cleared by dout_valid
// =============================================================================
wire trigger_pluse;   // Motion-detection trigger from bdd
reg  cnn_start;       // CNN pipeline arm signal

// =============================================================================
// bdd instance — monitors raw pixel stream for ascending centroid motion
// =============================================================================
bdd u_bdd (
    .clk           (clk          ),
    .rst_n         (rst_n        ),
    .raw_data      (din          ),
    .din_valid     (din_valid    ),
    .trigger_pluse (trigger_pluse)
);

// =============================================================================
// cnn_start SR latch (implemented as clocked logic)
// Set   : trigger_pluse asserted by bdd (motion detected)
// Clear : dout_valid    asserted by CNN2D (inference complete)
// Held high across the entire CNN inference window so that CNN2D can use it
// as a continuous enable rather than a one-cycle strobe.
// =============================================================================
always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        cnn_start <= 1'b0;
    end
    else if (trigger_pluse) begin
        cnn_start <= 1'b1;   // arm CNN pipeline on motion trigger
    end
    else if (dout_valid) begin
        cnn_start <= 1'b0;   // disarm after inference result is ready
    end
end

// =============================================================================
// CNN2D instance — full 2-D CNN inference pipeline
// =============================================================================
CNN2D u_CNN2D (
    .clk        (clk       ),
    .rst_n      (rst_n     ),
    .cnn_start  (cnn_start ),
    .din        (din       ),
    .din_valid  (din_valid ),
    .dout       (dout      ),
    .dout_valid (dout_valid)
);

endmodule