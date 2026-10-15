`timescale 1ns/1ps
//==============================================================================
// sync_fifo.v : Synchronous FIFO (single clock)
//  - Registered read: rd_data is valid ONE clock after an accepted rd_en,
//    and rd_valid pulses high in that same cycle.
//  - Writes when full / reads when empty are ignored and flagged.
//==============================================================================
module sync_fifo #(
    parameter DATA_WIDTH          = 8,
    parameter ADDR_WIDTH          = 4,   // depth = 2**ADDR_WIDTH
    parameter ALMOST_FULL_MARGIN  = 2,   // almost_full  when count >= DEPTH-2
    parameter ALMOST_EMPTY_MARGIN = 2    // almost_empty when count <= 2
)(
    input  wire                   clk,
    input  wire                   rst_n,        // active-low async reset

    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  wr_data,

    input  wire                   rd_en,
    output reg  [DATA_WIDTH-1:0]  rd_data,
    output reg                    rd_valid,

    output wire                   full,
    output wire                   empty,
    output wire                   almost_full,
    output wire                   almost_empty,
    output wire [ADDR_WIDTH:0]    count,
    output reg                    overflow,     // wr_en while full  (1-cycle pulse)
    output reg                    underflow     // rd_en while empty (1-cycle pulse)
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr, rd_ptr;
    reg [ADDR_WIDTH:0]   count_r;

    assign full         = (count_r == DEPTH);
    assign empty        = (count_r == 0);
    assign almost_full  = (count_r >= DEPTH - ALMOST_FULL_MARGIN);
    assign almost_empty = (count_r <= ALMOST_EMPTY_MARGIN);
    assign count        = count_r;

    wire do_wr = wr_en && !full;    // write actually accepted
    wire do_rd = rd_en && !empty;   // read actually accepted

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= 0;
            rd_ptr    <= 0;
            count_r   <= 0;
            rd_data   <= 0;
            rd_valid  <= 1'b0;
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            overflow  <= wr_en && full;
            underflow <= rd_en && empty;
            rd_valid  <= do_rd;

            if (do_wr) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= wr_ptr + 1'b1;   // wraps automatically
            end

            if (do_rd) begin
                rd_data <= mem[rd_ptr];
                rd_ptr  <= rd_ptr + 1'b1;
            end

            case ({do_wr, do_rd})
                2'b10:   count_r <= count_r + 1'b1;
                2'b01:   count_r <= count_r - 1'b1;
                default: count_r <= count_r;     // idle or simultaneous rd+wr
            endcase
        end
    end

endmodule