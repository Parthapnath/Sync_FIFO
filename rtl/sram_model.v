`timescale 1ns/1ps
//==============================================================================
// sram_model.v : Single-port synchronous SRAM (behavioural model)
//  - en=1, we=1 : write wdata to addr on the clock edge
//  - en=1, we=0 : read  addr; rdata updates on the clock edge (1-cycle latency)
//  - rdata HOLDS its value until the next read
//==============================================================================
module sram_model #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 8
)(
    input  wire                  clk,
    input  wire                  en,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire [DATA_WIDTH-1:0] wdata,
    output reg  [DATA_WIDTH-1:0] rdata
);

    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    integer i;
    initial begin                       // simulation only: avoid X on first read
        for (i = 0; i < (1<<ADDR_WIDTH); i = i + 1) mem[i] = {DATA_WIDTH{1'b0}};
        rdata = {DATA_WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        if (en) begin
            if (we) mem[addr] <= wdata;
            else    rdata     <= mem[addr];
        end
    end

endmodule