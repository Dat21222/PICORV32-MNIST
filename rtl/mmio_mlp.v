`timescale 1ns/1ps

module mmio_mlp #(
    parameter INPUTS = 784
)(
    input  wire        clk,
    input  wire        resetn,

    // Interconnect -> MMIO
    input  wire        req_valid,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,

    // MMIO -> Interconnect
    output wire        req_ready,
    output reg  [31:0] req_rdata,

    // MMIO -> mlp_acc
    output wire        acc_start,
    output wire        acc_clear,
    output wire        pixel_valid,
    output wire [7:0]  pixel_data,

    // mlp_acc -> MMIO
    input  wire        weights_loaded,
    input  wire        acc_busy,
    input  wire        acc_done,
    input  wire [3:0]  acc_result
);

    // Register offsets
    localparam ADDR_CONTROL     = 8'h00;
    localparam ADDR_STATUS      = 8'h04;
    localparam ADDR_PIXEL_DATA  = 8'h08;
    localparam ADDR_PIXEL_COUNT = 8'h0C;
    localparam ADDR_RESULT      = 8'h10;

    localparam COUNT_WIDTH = $clog2(INPUTS + 1);

    reg [COUNT_WIDTH-1:0] pixel_count;
    reg                   done_latched;
    reg [3:0]             result_reg;

    wire [7:0] reg_addr;
    wire       bus_write;
    wire       bus_read;
    wire       bus_handshake;

    reg ready_internal;

    assign reg_addr = req_addr[7:0];

    // req_wstrb = 0: read
    // req_wstrb != 0: write
    assign bus_write = (req_wstrb != 4'b0000);
    assign bus_read  = (req_wstrb == 4'b0000);

    //================================================
    // BUS READY
    //================================================
    always @(*) begin
        ready_internal = 1'b1;

        if (req_valid && bus_write) begin
            case (reg_addr)

                ADDR_PIXEL_DATA: begin
                    ready_internal =
                        !acc_busy &&
                        (pixel_count < INPUTS);
                end

                ADDR_CONTROL: begin
                    if (req_wdata[0]) begin
                        ready_internal =
                            !acc_busy &&
                            (pixel_count == INPUTS) &&
                            weights_loaded;
                    end
                    else if (req_wdata[1]) begin
                        ready_internal = !acc_busy;
                    end
                end

                default: begin
                    ready_internal = 1'b1;
                end

            endcase
        end
    end

    assign req_ready = ready_internal;

    assign bus_handshake = req_valid && req_ready;

    //================================================
    // CONTROL SIGNALS
    //================================================

    assign acc_start =
        bus_handshake &&
        bus_write &&
        (reg_addr == ADDR_CONTROL) &&
        req_wdata[0] &&
        (pixel_count == INPUTS) &&
        !acc_busy &&
        weights_loaded;

    assign acc_clear =
        bus_handshake &&
        bus_write &&
        (reg_addr == ADDR_CONTROL) &&
        !req_wdata[0] &&
        req_wdata[1] &&
        !acc_busy;

    //================================================
    // PIXEL INPUT
    //================================================

    assign pixel_valid =
        bus_handshake &&
        bus_write &&
        (reg_addr == ADDR_PIXEL_DATA) &&
        req_wstrb[0] &&
        !acc_busy &&
        (pixel_count < INPUTS);

    assign pixel_data = req_wdata[7:0];

    //================================================
    // PIXEL COUNTER AND RESULT
    //================================================
    always @(posedge clk) begin
        if (!resetn) begin
            pixel_count <= 0;
            done_latched <= 1'b0;
            result_reg <= 4'd0;
        end
        else begin
            if (acc_clear) begin
                pixel_count <= 0;
                done_latched <= 1'b0;
                result_reg <= 4'd0;
            end
            else if (pixel_valid) begin
                pixel_count <= pixel_count + 1'b1;
            end

            if (acc_start)
                done_latched <= 1'b0;

            if (acc_done) begin
                done_latched <= 1'b1;
                result_reg <= acc_result;
            end
        end
    end

    //================================================
    // READ REGISTER
    //================================================
    always @(*) begin
        req_rdata = 32'd0;

        if (req_valid && bus_read) begin
            case (reg_addr)

                ADDR_STATUS: begin
                    req_rdata[0] = acc_busy;
                    req_rdata[1] = done_latched;
                    req_rdata[2] =
                        !acc_busy && (pixel_count < INPUTS);
                    req_rdata[3] =
                        (pixel_count == INPUTS);
                end

                ADDR_PIXEL_COUNT: begin
                    req_rdata = pixel_count;
                end

                ADDR_RESULT: begin
                    req_rdata = {28'd0, result_reg};
                end

                default: begin
                    req_rdata = 32'd0;
                end

            endcase
        end
    end

endmodule