`timescale 1ns/1ps
//==============================================================================
// tb_sync_fifo.v : self-checking testbench for sync_fifo
//  Tests: reset, fill, overflow, drain (order check), underflow,
//         simultaneous read+write, random stress with a scoreboard.
//==============================================================================
module tb_sync_fifo;

    parameter DATA_WIDTH = 8;
    parameter ADDR_WIDTH = 4;
    parameter DEPTH      = 1 << ADDR_WIDTH;

    reg                   clk = 0, rst_n = 0;
    reg                   wr_en = 0, rd_en = 0;
    reg  [DATA_WIDTH-1:0] wr_data = 0;
    wire [DATA_WIDTH-1:0] rd_data;
    wire                  rd_valid, full, empty, almost_full, almost_empty;
    wire                  overflow, underflow;
    wire [ADDR_WIDTH:0]   count;

    sync_fifo #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_data(wr_data),
        .rd_en(rd_en), .rd_data(rd_data), .rd_valid(rd_valid),
        .full(full), .empty(empty),
        .almost_full(almost_full), .almost_empty(almost_empty),
        .count(count), .overflow(overflow), .underflow(underflow)
    );

    always #5 clk = ~clk;                       // 100 MHz

    // ------------------------------------------------------------------
    // Scoreboard: a software queue that predicts what the FIFO must return
    // ------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] exp_mem [0:8191];
    integer exp_wr = 0, exp_rd = 0;
    integer errors = 0, checks = 0, reads_checked = 0;

    always @(posedge clk) if (rst_n) begin
        if (wr_en && !full) begin               // DUT accepts this write
            exp_mem[exp_wr] = wr_data;
            exp_wr = exp_wr + 1;
        end
        if (rd_valid) begin                     // data from last cycle's accepted read
            reads_checked = reads_checked + 1;
            if (rd_data !== exp_mem[exp_rd]) begin
                errors = errors + 1;
                $display("[FAIL] t=%0t DATA MISMATCH got=%0h expected=%0h",
                         $time, rd_data, exp_mem[exp_rd]);
            end
            exp_rd = exp_rd + 1;
        end
    end

    // ------------------------------------------------------------------
    // Helper tasks (inputs change on the falling edge -> no race with DUT)
    // ------------------------------------------------------------------
    task check(input cond, input [8*56-1:0] name);
        begin
            checks = checks + 1;
            if (cond) $display("[PASS] %0s", name);
            else begin
                errors = errors + 1;
                $display("[FAIL] t=%0t %0s", $time, name);
            end
        end
    endtask

    task push(input [DATA_WIDTH-1:0] d);
        begin
            @(negedge clk); wr_en = 1; wr_data = d;
            @(negedge clk); wr_en = 0;
        end
    endtask

    task pop;
        begin
            @(negedge clk); rd_en = 1;
            @(negedge clk); rd_en = 0;
        end
    endtask

    integer i;

    initial begin
        $dumpfile("sim/fifo.vcd");
        $dumpvars(0, tb_sync_fifo);

        // ---------- TEST 1: reset ----------
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        check(empty === 1 && full === 0 && count === 0, "T1 after reset: empty, not full, count=0");

        // ---------- TEST 2: fill to full ----------
        for (i = 0; i < DEPTH; i = i + 1) begin
            push(8'hA0 + i);
            if (i == DEPTH-3) check(almost_full === 1 && full === 0, "T2 almost_full asserts at DEPTH-2");
        end
        @(negedge clk);
        check(full === 1 && count === DEPTH, "T2 full asserted, count=DEPTH");

        // ---------- TEST 3: overflow ----------
        push(8'hFF);                            // should be ignored
        @(negedge clk);
        check(count === DEPTH, "T3 write when full is ignored (count unchanged)");

        // ---------- TEST 4: drain, order checked by scoreboard ----------
        for (i = 0; i < DEPTH; i = i + 1) begin
            pop;
            if (i == DEPTH-3) check(almost_empty === 1 && empty === 0, "T4 almost_empty asserts at count<=2");
        end
        repeat (2) @(negedge clk);
        check(empty === 1 && count === 0, "T4 empty asserted, count=0");
        check(reads_checked === DEPTH, "T4 all 16 words read back");

        // ---------- TEST 5: underflow ----------
        pop;                                    // should be ignored
        @(negedge clk);
        check(empty === 1 && count === 0, "T5 read when empty is ignored");

        // ---------- TEST 6: simultaneous read + write ----------
        push(8'h11); push(8'h22);               // preload 2 words
        @(negedge clk);
        wr_en = 1; rd_en = 1; wr_data = 8'h33;  // do both in the same cycle
        @(negedge clk);
        wr_en = 0; rd_en = 0;
        @(negedge clk);
        check(count === 2, "T6 simultaneous rd+wr keeps count constant");
        for (i = 0; i < 2; i = i + 1) pop;      // drain remaining words
        repeat (2) @(negedge clk);

        // ---------- TEST 7: random stress ----------
        for (i = 0; i < 2000; i = i + 1) begin
            @(negedge clk);
            wr_en   = ($urandom % 100) < 55;    // slightly write-heavy -> hits full
            rd_en   = ($urandom % 100) < 45;
            wr_data = $urandom;
        end
        @(negedge clk); wr_en = 0; rd_en = 1;   // drain everything
        repeat (DEPTH + 4) @(negedge clk);
        rd_en = 0;
        repeat (3) @(negedge clk);
        check(empty === 1, "T7 FIFO empty after stress + drain");
        check(exp_wr === exp_rd, "T7 every accepted write was read exactly once");

        // ---------- Summary ----------
        $display("--------------------------------------------------");
        $display("Directed checks: %0d | Words verified: %0d | Errors: %0d",
                 checks, reads_checked, errors);
        if (errors == 0) $display("*** SYNC FIFO: ALL TESTS PASSED ***");
        else             $display("*** SYNC FIFO: TESTS FAILED ***");
        $finish;
    end

    // Safety net: stop a hung simulation
    initial begin #2000000; $display("[FAIL] TIMEOUT"); $finish; end

endmodule