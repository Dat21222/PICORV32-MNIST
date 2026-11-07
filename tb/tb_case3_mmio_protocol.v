`timescale 1ns/1ps
// tb_case3_mmio_protocol.v
// Test Case 3: MMIO Handshake & Protocol Guardrail Verification
// Directly tests mmio_mlp + mlp_acc for:
//   - Subtest 3A: Reset state of ADDR_STATUS (0x04) and ADDR_PIXEL_COUNT (0x0C)
//   - Subtest 3B: Partial pixel load (100 pixels) & Premature Start Guardrail (req_ready == 0)
//   - Subtest 3C: Mid-stream Clear (acc_clear resets pixel_count to 0)
//   - Subtest 3D: Full 784-pixel load & Overflow Guardrail (785th pixel blocked with req_ready == 0)
module tb_case3_mmio_protocol;
    reg         clk;
    reg         resetn;
    reg         req_valid;
    reg  [31:0] req_addr;
    reg  [31:0] req_wdata;
    reg  [3:0]  req_wstrb;
    wire        req_ready;
    wire [31:0] req_rdata;

    wire        acc_start;
    wire        acc_clear;
    wire        pixel_valid;
    wire [7:0]  pixel_data;
    wire        acc_busy;
    wire        acc_done;
    wire [3:0]  acc_result;
    wire        weight_en;
    wire [15:0] weight_addr;
    reg  [31:0] weight_rdata;

    initial clk = 1'b0;
    always #5 clk = ~clk; // 100 MHz

    mmio_mlp #(
        .INPUTS(784)
    ) u_mmio (
        .clk(clk),
        .resetn(resetn),
        .req_valid(req_valid),
        .req_addr(req_addr),
        .req_wdata(req_wdata),
        .req_wstrb(req_wstrb),
        .req_ready(req_ready),
        .req_rdata(req_rdata),
        .acc_start(acc_start),
        .acc_clear(acc_clear),
        .pixel_valid(pixel_valid),
        .pixel_data(pixel_data),
        .weights_loaded(1'b1),
        .acc_busy(acc_busy),
        .acc_done(acc_done),
        .acc_result(acc_result)
    );

    mlp_acc #(
        .INPUTS(784),
        .HIDDEN(64),
        .OUTPUTS(10)
    ) u_mlp (
        .clk(clk),
        .resetn(resetn),
        .clear_input(acc_clear),
        .pixel_valid(pixel_valid),
        .pixel_data(pixel_data),
        .start(acc_start),
        .weights_loaded(1'b1),
        .weight_en(weight_en),
        .weight_addr(weight_addr),
        .weight_rdata(weight_rdata),
        .busy(acc_busy),
        .done(acc_done),
        .result_class(acc_result)
    );

    always @(posedge clk) begin
        if (weight_en)
            weight_rdata <= 32'h0001_0001;
    end

    integer i;
    integer err_count;
    reg [31:0] rval;

    task mmio_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            req_valid <= 1'b1;
            req_addr  <= addr;
            req_wdata <= data;
            req_wstrb <= 4'b1111;
            @(posedge clk);
            req_valid <= 1'b0;
            req_wstrb <= 4'b0000;
        end
    endtask

    task mmio_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            req_valid <= 1'b1;
            req_addr  <= addr;
            req_wstrb <= 4'b0000;
            #1;
            data = req_rdata;
            @(posedge clk);
            req_valid <= 1'b0;
        end
    endtask

    initial begin
        $timeformat(-9, 0, " ns", 12);
        err_count    = 0;
        resetn       = 1'b0;
        req_valid    = 1'b0;
        req_addr     = 32'd0;
        req_wdata    = 32'd0;
        req_wstrb    = 4'd0;
        weight_rdata = 32'd0;

        $display("================================================================");
        $display("TEST CASE 3: MMIO Handshake & Protocol Guardrail Verification");
        $display("================================================================");

        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        // -----------------------------------------------------------------
        // Subtest 3A: Reset State Check
        // -----------------------------------------------------------------
        mmio_read(32'h1000_0004, rval);
        $display("[Subtest 3A] Initial STATUS = 0x%08x (Expected 0x00000004: can_accept_pixel=1)", rval);
        if (rval !== 32'h0000_0004) err_count = err_count + 1;

        mmio_read(32'h1000_000C, rval);
        $display("[Subtest 3A] Initial PIXEL_COUNT = %0d (Expected 0)", rval);
        if (rval !== 32'd0) err_count = err_count + 1;

        // -----------------------------------------------------------------
        // Subtest 3B: Partial Load (100 pixels) & Premature Start Guardrail
        // -----------------------------------------------------------------
        for (i = 0; i < 100; i = i + 1) begin
            mmio_write(32'h1000_0008, i & 8'hFF);
        end
        mmio_read(32'h1000_000C, rval);
        $display("[Subtest 3B] After 100 writes: PIXEL_COUNT = %0d (Expected 100)", rval);
        if (rval !== 32'd100) err_count = err_count + 1;

        // Attempt premature start (ADDR_CONTROL = 1 when pixel_count == 100 < 784)
        @(posedge clk);
        req_valid <= 1'b1;
        req_addr  <= 32'h1000_0000;
        req_wdata <= 32'h0000_0001;
        req_wstrb <= 4'b1111;
        #1;
        $display("[Subtest 3B] Premature START attempt at count=100: req_ready=%b, acc_start=%b (Expected 0, 0)",
                 req_ready, acc_start);
        if (req_ready !== 1'b0 || acc_start !== 1'b0) err_count = err_count + 1;
        @(posedge clk);
        req_valid <= 1'b0;
        req_wstrb <= 4'b0000;

        // -----------------------------------------------------------------
        // Subtest 3C: Mid-stream Clear (acc_clear)
        // -----------------------------------------------------------------
        mmio_write(32'h1000_0000, 32'h0000_0002); // acc_clear = 1
        mmio_read(32'h1000_000C, rval);
        $display("[Subtest 3C] After acc_clear: PIXEL_COUNT = %0d (Expected 0)", rval);
        if (rval !== 32'd0) err_count = err_count + 1;

        // -----------------------------------------------------------------
        // Subtest 3D: Full 784-Pixel Load & 785th Pixel Overflow Guardrail
        // -----------------------------------------------------------------
        for (i = 0; i < 784; i = i + 1) begin
            mmio_write(32'h1000_0008, (i * 7) & 8'hFF);
        end
        mmio_read(32'h1000_000C, rval);
        $display("[Subtest 3D] After 784 writes: PIXEL_COUNT = %0d (Expected 784)", rval);
        if (rval !== 32'd784) err_count = err_count + 1;

        mmio_read(32'h1000_0004, rval);
        $display("[Subtest 3D] STATUS at full buffer = 0x%08x (Expected 0x00000008: input_full=1, can_accept=0)", rval);
        if (rval !== 32'h0000_0008) err_count = err_count + 1;

        // Attempt 785th pixel write (overflow attempt)
        @(posedge clk);
        req_valid <= 1'b1;
        req_addr  <= 32'h1000_0008;
        req_wdata <= 32'h0000_00AA;
        req_wstrb <= 4'b1111;
        #1;
        $display("[Subtest 3D] 785th pixel overflow attempt: req_ready=%b, pixel_valid=%b (Expected 0, 0)",
                 req_ready, pixel_valid);
        if (req_ready !== 1'b0 || pixel_valid !== 1'b0) err_count = err_count + 1;
        @(posedge clk);
        req_valid <= 1'b0;
        req_wstrb <= 4'b0000;

        $display("================================================================");
        if (err_count == 0)
            $display("TEST CASE 3 RESULT: PASS (0 errors across all 4 protocol subtests)");
        else
            $display("TEST CASE 3 RESULT: FAIL (%0d errors detected)", err_count);
        $display("================================================================");
        $finish;
    end
endmodule
