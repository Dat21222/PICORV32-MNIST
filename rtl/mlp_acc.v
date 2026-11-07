`timescale 1ns/1ps

module mlp_acc #(
    parameter INPUTS  = 784,
    parameter HIDDEN  = 64,
    parameter OUTPUTS = 10,

    // Word addresses for packed 32-bit BRAM
    parameter W1_BASE = 0,
    parameter B1_BASE = 25088,
    parameter W2_BASE = 25152,
    parameter B2_BASE = 25472
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        clear_input,
    input  wire        pixel_valid,
    input  wire [7:0]  pixel_data,
    input  wire        start,
    input  wire        weights_loaded,

    // Single-port, synchronous 32-bit BRAM interface
    output reg         weight_en,
    output reg  [15:0] weight_addr,
    input  wire [31:0] weight_rdata,

    output reg         busy,
    output reg         done,
    output reg  [3:0]  result_class
);

    // ---------------------------------------------------------
    // Internal memories
    // ---------------------------------------------------------
    // Raw MNIST pixels: unsigned integer range 0..255 (Q0).
    // W1, B1, W2 in bram_init_adat.coe are Q15; B2 is Q30.
    // Layer-1 activations fit in 25-bit signed Q15 (up to +512.0),
    // which maps Layer-2 25x16 multiplies to a single DSP48E1.
    reg [7:0] x_mem [0:INPUTS-1];
    reg signed [24:0] h_mem [0:HIDDEN-1];
    reg signed [31:0] logits_mem [0:OUTPUTS-1];

    reg [9:0] pixel_count;
    reg       input_full;

    // ---------------------------------------------------------
    // FSM
    // ---------------------------------------------------------
    localparam [4:0]
        IDLE        = 0,
        L1_BIAS_REQ = 1,
        L1_BIAS_USE = 2,
        L1_W_REQ    = 3,
        L1_MUL      = 4,
        L1_PAIR     = 5,
        L1_ACC      = 6,
        L1_FINISH   = 7,
        L2_BIAS_REQ = 8,
        L2_BIAS_USE = 9,
        L2_W_REQ    = 10,
        L2_MUL      = 11,
        L2_PAIR     = 12,
        L2_ACC      = 13,
        L2_FINISH   = 14,
        ARGMAX_INIT = 15,
        ARGMAX_SCAN = 16,
        L1_W_LATCH  = 17,
        L2_W_LATCH  = 18;

    reg [4:0] state;

    // i_count and i2_count are even indices of each pair.
    reg [9:0] i_count;
    reg [6:0] h_count;
    reg [6:0] i2_count;
    reg [3:0] o_count;
    reg [3:0] arg_count;

    (* keep = "true" *) reg signed [31:0] bias1;
    (* keep = "true" *) reg signed [31:0] bias2;

    // Two INT16 weights unpacked from one 32-bit BRAM word.
    // Kept in fabric flip-flops to break the long BRAM-mux-to-DSP timing path.
    (* keep = "true" *) reg signed [15:0] w1_a_reg, w1_b_reg;
    (* keep = "true" *) reg signed [15:0] w2_a_reg, w2_b_reg;

    // Layer 1 with bram_init_adat.coe / weights_original.coe:
    // Pixel (0..255) is converted to Q15 via ((p << 8) + p + 1) >> 1,
    // which is 100% bit-identical to (p * 32768 + 127) // 255 for all p in 0..255.
    // 17-bit signed Q15 pixel x 16-bit signed Q15 W1 = 33-bit signed Q30 product
    // (fits in 1 single 25x18 DSP48E1 per lane).
    reg signed [32:0] l1_prod_a, l1_prod_b;
    reg signed [33:0] l1_pair;
    reg signed [43:0] acc1;

    // Layer 2 arithmetic (25-bit Q16 hidden x 16-bit Q15 W2 = 41-bit Q31 product,
    // fitting into a single 25x18 DSP48E1 multiplier per lane).
    reg signed [47:0] l2_prod_a, l2_prod_b;
    reg signed [48:0] l2_pair;
    reg signed [55:0] acc2;

    reg signed [31:0] max_logit;
    reg [3:0] max_class;

    // B1 in bram_init_adat.coe is signed 32-bit Q30, aligned with acc1 (Q30).
    wire signed [43:0] l1_sum_bias = acc1 + {{12{bias1[31]}}, bias1};
    // Shift right by 14 (Q30 -> Q16) to match reference model.
    wire signed [43:0] l1_q16_full = l1_sum_bias >>> 14;

    wire [7:0] x1_a = x_mem[i_count];
    wire [7:0] x1_b = x_mem[i_count + 10'd1];

    // Exact Q15 normalization: (p * 32768 + 127) // 255 == ((p << 8) + p + 1) >> 1
    wire [15:0] x1_a_q15 = ({1'b0, x1_a, 8'd0} + {9'd0, x1_a} + 17'd1) >> 1;
    wire [15:0] x1_b_q15 = ({1'b0, x1_b, 8'd0} + {9'd0, x1_b} + 17'd1) >> 1;
    wire signed [16:0] x1_a_ext = $signed({1'b0, x1_a_q15});
    wire signed [16:0] x1_b_ext = $signed({1'b0, x1_b_q15});
    wire signed [15:0] w1_a_ext = w1_a_reg;
    wire signed [15:0] w1_b_ext = w1_b_reg;

    wire signed [24:0] h2_a = h_mem[i2_count];
    wire signed [24:0] h2_b = h_mem[i2_count + 7'd1];

    // 25-bit Q15 activation x 16-bit Q15 weight fits in a single 25x18 DSP48E1.
    wire signed [40:0] l2_mult_a = h2_a * w2_a_reg;
    wire signed [40:0] l2_mult_b = h2_b * w2_b_reg;
    wire signed [47:0] l2_mult_a_ext = {{7{l2_mult_a[40]}}, l2_mult_a};
    wire signed [47:0] l2_mult_b_ext = {{7{l2_mult_b[40]}}, l2_mult_b};

    // ---------------------------------------------------------
    // BRAM control.
    // Single read port, 32-bit word, synchronous latency = 1.
    //
    // Packed W1 word:
    //   [15:0]  = W1[i_count,   h_count]
    //   [31:16] = W1[i_count+1, h_count]
    //
    // Packed W2 word:
    //   [15:0]  = W2[i2_count,   o_count]
    //   [31:16] = W2[i2_count+1, o_count]
    // ---------------------------------------------------------
    always @(*) begin
        weight_en   = 1'b0;
        weight_addr = 16'd0;

        case (state)
            L1_BIAS_REQ: begin
                weight_en   = 1'b1;
                weight_addr = B1_BASE + h_count;
            end

            L1_W_REQ: begin
                weight_en   = 1'b1;
                weight_addr =
                    W1_BASE + (i_count >> 1) * HIDDEN + h_count;
            end

            L2_BIAS_REQ: begin
                weight_en   = 1'b1;
                weight_addr = B2_BASE + o_count;
            end

            L2_W_REQ: begin
                weight_en   = 1'b1;
                weight_addr =
                    W2_BASE + (i2_count >> 1) * OUTPUTS + o_count;
            end

            default: begin
                weight_en   = 1'b0;
                weight_addr = 16'd0;
            end
        endcase
    end

    // ---------------------------------------------------------
    // Sequential logic
    // ---------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            state        <= IDLE;
            pixel_count  <= 0;
            input_full   <= 1'b0;

            i_count      <= 0;
            h_count      <= 0;
            i2_count     <= 0;
            o_count      <= 0;
            arg_count    <= 0;

            bias1        <= 0;
            bias2        <= 0;

            w1_a_reg     <= 0;
            w1_b_reg     <= 0;
            w2_a_reg     <= 0;
            w2_b_reg     <= 0;

            l1_prod_a    <= 0;
            l1_prod_b    <= 0;
            l1_pair      <= 0;
            acc1         <= 0;

            l2_prod_a    <= 0;
            l2_prod_b    <= 0;
            l2_pair      <= 0;
            acc2         <= 0;

            busy         <= 1'b0;
            done         <= 1'b0;
            result_class <= 0;

            max_logit    <= 0;
            max_class    <= 0;
        end else begin
            done <= 1'b0;

            // Receive an image from the CPU.
            if (clear_input && !busy) begin
                pixel_count  <= 0;
                input_full   <= 1'b0;
                acc1         <= 0;
                acc2         <= 0;
                max_logit    <= 0;
                max_class    <= 0;
                result_class <= 0;
            end

            if (pixel_valid && !busy &&
                !clear_input && !input_full) begin

                // Store the original 8-bit pixel directly (Q0).
                x_mem[pixel_count] <= pixel_data;

                if (pixel_count == INPUTS-1) begin
                    pixel_count <= INPUTS;
                    input_full  <= 1'b1;
                end else begin
                    pixel_count <= pixel_count + 1'b1;
                end
            end

            case (state)

                // ---------------------------------------------
                // IDLE
                // ---------------------------------------------
                IDLE: begin
                    busy <= 1'b0;

                    if (start && input_full && weights_loaded) begin
                        busy    <= 1'b1;
                        h_count <= 0;
                        i_count <= 0;
                        acc1    <= 0;
                        state   <= L1_BIAS_REQ;
                    end
                end

                // ---------------------------------------------
                // Layer 1: read bias
                // ---------------------------------------------
                L1_BIAS_REQ: begin
                    state <= L1_BIAS_USE;
                end

                L1_BIAS_USE: begin
                    bias1   <= $signed(weight_rdata);
                    i_count <= 0;
                    acc1    <= 0;
                    state   <= L1_W_REQ;
                end

                // Read one packed word from BRAM.
                L1_W_REQ: begin
                    state <= L1_W_LATCH;
                end

                // Split the word into two signed INT16 weights.
                L1_W_LATCH: begin
                    w1_a_reg <= $signed(weight_rdata[15:0]);
                    w1_b_reg <= $signed(weight_rdata[31:16]);
                    state    <= L1_MUL;
                end

                L1_MUL: begin
                    // 17-bit signed Q15 pixel x 16-bit signed Q15 weight = 33-bit Q30 product.
                    l1_prod_a <= x1_a_ext * w1_a_ext;
                    l1_prod_b <= x1_b_ext * w1_b_ext;
                    state     <= L1_PAIR;
                end

                L1_PAIR: begin
                    l1_pair <=
                        {l1_prod_a[32], l1_prod_a} +
                        {l1_prod_b[32], l1_prod_b};

                    state <= L1_ACC;
                end

                L1_ACC: begin
                    acc1 <= acc1 +
                            {{10{l1_pair[33]}}, l1_pair};

                    if (i_count == INPUTS-2) begin
                        state <= L1_FINISH;
                    end else begin
                        i_count <= i_count + 10'd2;
                        state   <= L1_W_REQ;
                    end
                end

                L1_FINISH: begin
                    // Shift Q30 sum+bias right by 14 to produce Q16 hidden activation.
                    // ReLU is applied before storing the activation.
                    if (l1_sum_bias > 0)
                        h_mem[h_count] <= l1_q16_full[24:0];
                    else
                        h_mem[h_count] <= 25'sd0;

                    acc1    <= 0;
                    i_count <= 0;

                    if (h_count == HIDDEN-1) begin
                        h_count  <= 0;
                        o_count  <= 0;
                        i2_count <= 0;
                        acc2     <= 0;
                        state    <= L2_BIAS_REQ;
                    end else begin
                        h_count <= h_count + 1'b1;
                        state   <= L1_BIAS_REQ;
                    end
                end

                // ---------------------------------------------
                // Layer 2: read bias
                // ---------------------------------------------
                L2_BIAS_REQ: begin
                    state <= L2_BIAS_USE;
                end

                L2_BIAS_USE: begin
                    bias2    <= $signed(weight_rdata);
                    i2_count <= 0;
                    acc2     <= 0;
                    state    <= L2_W_REQ;
                end

                // Read one packed word from BRAM.
                L2_W_REQ: begin
                    state <= L2_W_LATCH;
                end

                // Split the word into two signed INT16 weights.
                L2_W_LATCH: begin
                    w2_a_reg <= $signed(weight_rdata[15:0]);
                    w2_b_reg <= $signed(weight_rdata[31:16]);
                    state    <= L2_MUL;
                end

                L2_MUL: begin
                    l2_prod_a <= l2_mult_a_ext;
                    l2_prod_b <= l2_mult_b_ext;
                    state     <= L2_PAIR;
                end

                L2_PAIR: begin
                    l2_pair <=
                        {l2_prod_a[47], l2_prod_a} +
                        {l2_prod_b[47], l2_prod_b};

                    state <= L2_ACC;
                end

                L2_ACC: begin
                    acc2 <= acc2 +
                            {{7{l2_pair[48]}}, l2_pair};

                    if (i2_count == HIDDEN-2) begin
                        state <= L2_FINISH;
                    end else begin
                        i2_count <= i2_count + 7'd2;
                        state    <= L2_W_REQ;
                    end
                end

                L2_FINISH: begin
                    logits_mem[o_count] <=
                        (acc2 + {{24{bias2[31]}}, bias2}) >>> 14;

                    acc2     <= 0;
                    i2_count <= 0;

                    if (o_count == OUTPUTS-1) begin
                        arg_count <= 0;
                        state     <= ARGMAX_INIT;
                    end else begin
                        o_count <= o_count + 1'b1;
                        state   <= L2_BIAS_REQ;
                    end
                end

                // ---------------------------------------------
                // Argmax
                // ---------------------------------------------
                ARGMAX_INIT: begin
                    max_logit <= logits_mem[0];
                    max_class <= 0;
                    arg_count <= 1;
                    state     <= ARGMAX_SCAN;
                end

                ARGMAX_SCAN: begin
                    if (logits_mem[arg_count] > max_logit) begin
                        max_logit <= logits_mem[arg_count];
                        max_class <= arg_count;
                    end

                    if (arg_count == OUTPUTS-1) begin
                        result_class <=
                            (logits_mem[arg_count] > max_logit)
                            ? arg_count : max_class;

                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= IDLE;
                    end else begin
                        arg_count <= arg_count + 1'b1;
                    end
                end

                default: begin
                    state <= IDLE;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule