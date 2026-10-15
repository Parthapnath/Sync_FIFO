`timescale 1ns/1ps
//==============================================================================
// tb_sram_ctrl.v : self-checking testbench for sram_ctrl (FIFO + SRAM)
//  The testbench keeps its own reference memory ("golden model") and compares
//  every read response against it.
//  Tests: write-then-read, overwrite, back-to-back commands (CMD FIFO fills),
//         response backpressure (RSP FIFO fills), random read/write mix.
//==============================================================================
module tb_sram_ctrl;

    parameter DATA_WIDTH = 8;
    parameter ADDR_WIDTH = 8;

    reg                   clk = 0, rst_n = 0;
    reg                   cmd_valid = 0, cmd_we = 0;
    reg  [ADDR_WIDTH-1:0] cmd_addr  = 0;
    reg  [DATA_WIDTH-1:0] cmd_wdata = 0;
    wire                  cmd_ready;
    reg                   rsp_rd_en = 0;
    wire [DATA_WIDTH-1:0] rsp_rd_data;
    wire                  rsp_rd_valid, rsp_empty, rsp_full, busy;

    sram_ctrl #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we),
        .cmd_addr(cmd_addr), .cmd_wdata(cmd_wdata),
        .rsp_rd_en(rsp_rd_en), .rsp_rd_data(rsp_rd_data),
        .rsp_rd_valid(rsp_rd_valid), .rsp_empty(rsp_empty),
        .rsp_full(rsp_full), .busy(busy)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Golden model: reference memory + queue of expected read results
    // ------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] ref_mem  [0:(1<<ADDR_WIDTH)-1];
    reg [DATA_WIDTH-1:0] exp_q    [0:8191];
    integer exp_wr = 0, exp_rd = 0;
    integer errors = 0, checks = 0, cmds_sent = 0, reads_sent = 0;
    integer k;

    initial for (k = 0; k < (1<<ADDR_WIDTH); k = k + 1) ref_mem[k] = 0;

    // A command is accepted when valid && ready at a rising edge
    always @(posedge clk) if (rst_n && cmd_valid && cmd_ready) begin
        cmds_sent = cmds_sent + 1;
        if (cmd_we) ref_mem[cmd_addr] = cmd_wdata;
        else begin
            exp_q[exp_wr] = ref_mem[cmd_addr];   // what this read MUST return
            exp_wr = exp_wr + 1;
            reads_sent = reads_sent + 1;
        end
    end

    // Every response coming out must match, in order
    always @(posedge clk) if (rst_n && rsp_rd_valid) begin
        if (rsp_rd_data !== exp_q[exp_rd]) begin
            errors = errors + 1;
            $display("[FAIL] t=%0t read #%0d got=%0h expected=%0h",
                     $time, exp_rd, rsp_rd_data, exp_q[exp_rd]);
        end
        exp_rd = exp_rd + 1;
    end

    // ------------------------------------------------------------------
    // Tasks
    // ------------------------------------------------------------------
    task check(input cond, input [8*56-1:0] name);
        begin
            checks = checks + 1;
            if (cond) $display("[PASS] %0s", name);
            else begin errors = errors + 1; $display("[FAIL] t=%0t %0s", $time, name); end
        end
    endtask

    // Send one command; waits (stalls) while the CMD FIFO is full
    task send(input we, input [ADDR_WIDTH-1:0] a, input [DATA_WIDTH-1:0] d);
        begin
            @(negedge clk);
            cmd_valid = 1; cmd_we = we; cmd_addr = a; cmd_wdata = d;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);   // held until accepted
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    task wait_idle;                              // all commands finished
        begin
            repeat (3) @(negedge clk);
            while (busy) @(negedge clk);
            repeat (2) @(negedge clk);
        end
    endtask

    // Background "host": pops responses according to pop_mode
    //   0 = never pop, 1 = pop whenever possible, 2 = pop randomly
    integer pop_mode = 0;
    always @(negedge clk) begin
        case (pop_mode)
            1:       rsp_rd_en = !rsp_empty;
            2:       rsp_rd_en = (($urandom % 4) == 0) && !rsp_empty;
            default: rsp_rd_en = 1'b0;
        endcase
    end

    task drain_responses;                        // let the host pop everything
        begin
            pop_mode = 1;
            repeat (3) @(negedge clk);
            while (!rsp_empty || busy) @(negedge clk);
            repeat (4) @(negedge clk);
            pop_mode = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    integer i;
    reg [ADDR_WIDTH-1:0] ra;

    initial begin
        $dumpfile("sim/ctrl.vcd");
        $dumpvars(0, tb_sram_ctrl);

        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        check(!busy && rsp_empty && cmd_ready, "T1 idle after reset");

        // ---------- TEST 2: write 8 locations, read them back ----------
        for (i = 0; i < 8; i = i + 1) send(1, i, 8'h10 + i);
        for (i = 0; i < 8; i = i + 1) send(0, i, 0);
        wait_idle;
        drain_responses;
        check(exp_rd === 8 && errors === 0, "T2 write-then-read of 8 locations");

        // ---------- TEST 3: overwrite same address ----------
        send(1, 8'h05, 8'hAA);
        send(1, 8'h05, 8'h55);
        send(0, 8'h05, 0);
        wait_idle; drain_responses;
        check(exp_rd === 9 && errors === 0, "T3 overwrite returns the latest value");

        // ---------- TEST 4: backpressure (host does NOT pop at first) ----------
        for (i = 0; i < 40; i = i + 1) send(1, 8'h40 + i, 8'hC0 + i);
        wait_idle;
        for (i = 0; i < 14; i = i + 1) send(0, 8'h40 + i, 0);
        repeat (20) @(negedge clk);
        check(rsp_full === 1, "T4 RSP FIFO full -> controller stalls safely");
        check(busy === 1,     "T4 controller still holding pending work");
        pop_mode = 1;                            // host wakes up and pops
        for (i = 14; i < 40; i = i + 1) send(0, 8'h40 + i, 0);
        drain_responses;
        check(exp_rd === exp_wr, "T4 no read response lost or duplicated");

        // ---------- TEST 5: random mix of reads and writes ----------
        pop_mode = 2;
        for (i = 0; i < 1500; i = i + 1) begin
            ra = $urandom % 32;                  // small address range -> many hits
            send(($urandom % 100) < 50, ra, $urandom);
        end
        drain_responses;
        check(exp_rd === exp_wr, "T5 random test: all responses accounted for");

        $display("--------------------------------------------------");
        $display("Commands: %0d | Reads checked: %0d | Errors: %0d",
                 cmds_sent, exp_rd, errors);
        if (errors == 0) $display("*** SRAM CONTROLLER: ALL TESTS PASSED ***");
        else             $display("*** SRAM CONTROLLER: TESTS FAILED ***");
        $finish;
    end

    initial begin #20000000; $display("[FAIL] TIMEOUT"); $finish; end

endmodule