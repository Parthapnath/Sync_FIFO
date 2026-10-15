`timescale 1ns/1ps
//==============================================================================
// sram_ctrl.v : FIFO-buffered SRAM controller
//
//   Host --cmd--> [CMD FIFO] --> FSM --> SRAM
//   Host <-rsp--- [RSP FIFO] <-- FSM <-- SRAM (read data)
//
//  Command word = { we, addr, wdata }
//  FSM: IDLE -> POP -> ACCESS -> (write: IDLE | read: RESP -> IDLE)
//==============================================================================
module sram_ctrl #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 8,
    parameter FIFO_ADDR_WIDTH = 3        // FIFO depth = 8 entries
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- Host command interface ----
    input  wire                   cmd_valid,   // host: "I have a command"
    output wire                   cmd_ready,   // ctrl: "I can take it" (CMD FIFO not full)
    input  wire                   cmd_we,      // 1 = write, 0 = read
    input  wire [ADDR_WIDTH-1:0]  cmd_addr,
    input  wire [DATA_WIDTH-1:0]  cmd_wdata,

    // ---- Host read-response interface ----
    input  wire                   rsp_rd_en,   // host pops one response
    output wire [DATA_WIDTH-1:0]  rsp_rd_data,
    output wire                   rsp_rd_valid,
    output wire                   rsp_empty,
    output wire                   rsp_full,

    output wire                   busy         // FSM active OR commands still queued
);

    localparam CMD_W = 1 + ADDR_WIDTH + DATA_WIDTH;

    // ---------------- Command FIFO ----------------
    wire [CMD_W-1:0] cmd_fifo_rdata;
    wire             cmd_fifo_rvalid, cmd_fifo_empty, cmd_fifo_full;
    reg              cmd_fifo_rd_en;

    assign cmd_ready = !cmd_fifo_full;

    sync_fifo #(.DATA_WIDTH(CMD_W), .ADDR_WIDTH(FIFO_ADDR_WIDTH)) u_cmd_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(cmd_valid && cmd_ready),
        .wr_data({cmd_we, cmd_addr, cmd_wdata}),
        .rd_en(cmd_fifo_rd_en),
        .rd_data(cmd_fifo_rdata),
        .rd_valid(cmd_fifo_rvalid),
        .full(cmd_fifo_full), .empty(cmd_fifo_empty),
        .almost_full(), .almost_empty(), .count(),
        .overflow(), .underflow()
    );

    // Unpack the command currently held at the FIFO output
    wire                  c_we    = cmd_fifo_rdata[CMD_W-1];
    wire [ADDR_WIDTH-1:0] c_addr  = cmd_fifo_rdata[DATA_WIDTH +: ADDR_WIDTH];
    wire [DATA_WIDTH-1:0] c_wdata = cmd_fifo_rdata[DATA_WIDTH-1:0];

    // ---------------- SRAM ----------------
    reg                   sram_en, sram_we;
    wire [DATA_WIDTH-1:0] sram_rdata;

    sram_model #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_sram (
        .clk(clk), .en(sram_en), .we(sram_we),
        .addr(c_addr), .wdata(c_wdata), .rdata(sram_rdata)
    );

    // ---------------- Response FIFO ----------------
    reg rsp_wr_en;

    sync_fifo #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(FIFO_ADDR_WIDTH)) u_rsp_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(rsp_wr_en),
        .wr_data(sram_rdata),
        .rd_en(rsp_rd_en),
        .rd_data(rsp_rd_data),
        .rd_valid(rsp_rd_valid),
        .full(rsp_full), .empty(rsp_empty),
        .almost_full(), .almost_empty(), .count(),
        .overflow(), .underflow()
    );

    // ---------------- FSM ----------------
    localparam [1:0] S_IDLE = 2'd0, S_POP = 2'd1, S_ACCESS = 2'd2, S_RESP = 2'd3;
    reg [1:0] state, next_state;

    assign busy = (state != S_IDLE) || !cmd_fifo_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    always @* begin
        next_state     = state;
        cmd_fifo_rd_en = 1'b0;
        sram_en        = 1'b0;
        sram_we        = 1'b0;
        rsp_wr_en      = 1'b0;

        case (state)
            S_IDLE: begin
                if (!cmd_fifo_empty) begin
                    cmd_fifo_rd_en = 1'b1;     // pop a command
                    next_state     = S_POP;
                end
            end
            S_POP: begin                        // FIFO output becomes valid this cycle
                next_state = S_ACCESS;
            end
            S_ACCESS: begin                     // drive the SRAM for one cycle
                sram_en = 1'b1;
                sram_we = c_we;
                next_state = c_we ? S_IDLE : S_RESP;
            end
            S_RESP: begin                       // SRAM rdata valid now; push to RSP FIFO
                if (!rsp_full) begin
                    rsp_wr_en  = 1'b1;
                    next_state = S_IDLE;
                end                             // else stall here (backpressure)
            end
        endcase
    end

endmodule