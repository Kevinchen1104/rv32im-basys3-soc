`timescale 1ns / 1ps

// Module: uart_packet_boot_imem
// Role: Byte-parallel packet boot path for loading instruction memory in simulation and FPGA wrappers.
// Interface: Clock/reset, byte-valid/data stream, 128-bit instruction-line read port, and loader status outputs.
// Key behavior: Checks packet fields and checksum, scrubs failed payloads or stale tail words, then releases the CPU only for a clean image.

module uart_packet_boot_imem #(
    parameter MEMORY_WORD_COUNT = 1024
) (
    input clock,
    input external_reset,
    input [7:0] rx_data,
    input rx_valid,
    output rx_ready,
    output cpu_reset,
    output boot_waiting,
    output loader_done,
    output loader_busy,
    output boot_error,
    input [31:0] imem_addr,
    input imem_read,
    output [127:0] imem_rdata,
    output imem_ready
);

    localparam STORAGE_WORD_COUNT =
        (MEMORY_WORD_COUNT < 1) ? 1 : MEMORY_WORD_COUNT;
    localparam ADDR_WIDTH =
        (STORAGE_WORD_COUNT <= 1) ? 1 : $clog2(STORAGE_WORD_COUNT);
    localparam BANK_WORD_COUNT = (STORAGE_WORD_COUNT + 3) / 4;
    localparam BANK_ADDR_WIDTH =
        (BANK_WORD_COUNT <= 1) ? 1 : $clog2(BANK_WORD_COUNT);
    localparam [ADDR_WIDTH-1:0] LAST_WORD_ADDR =
        ADDR_WIDTH'(STORAGE_WORD_COUNT - 1);
    // A one-word memory is supported. Zero capacity uses a dummy storage word
    // only to keep elaboration well-formed and is permanently rejected.
    localparam CONFIG_VALID = (MEMORY_WORD_COUNT >= 1);
    localparam NOP = 32'h0000_0013;
    localparam MAGIC_WORD = 32'h5256_4254;  // "RVBT"
    localparam VERSION_WORD = 32'h0000_0001;

    localparam STATE_MAGIC = 4'd0;
    localparam STATE_VERSION = 4'd1;
    localparam STATE_START = 4'd2;
    localparam STATE_COUNT = 4'd3;
    localparam STATE_CHECKSUM = 4'd4;
    localparam STATE_PAYLOAD = 4'd5;
    localparam STATE_DONE = 4'd6;
    localparam STATE_ERROR = 4'd7;
    localparam STATE_CLEAR_TAIL = 4'd8;
    localparam STATE_CLEAR_ERROR = 4'd9;

    // Packet words are little-endian on the byte stream:
    // magic, version, start word address, word count, checksum, payload words.
    reg [3:0] state = STATE_MAGIC;
    reg [1:0] byte_index = 2'd0;
    reg [31:0] word_buffer = 32'h0;
    reg [31:0] start_word_addr = 32'h0;
    reg [31:0] word_count = 32'h0;
    reg [31:0] expected_checksum = 32'h0;
    reg [31:0] checksum_accum = 32'h0;
    reg [31:0] words_loaded = 32'h0;
    reg [ADDR_WIDTH-1:0] current_addr = {ADDR_WIDTH{1'b0}};
    reg [ADDR_WIDTH-1:0] clear_addr = {ADDR_WIDTH{1'b0}};
    reg done_reg = 1'b0;
    reg error_reg = 1'b0;

    wire [31:0] received_word = {rx_data, word_buffer[23:0]};
    wire received_word_valid = rx_valid && rx_ready && (byte_index == 2'd3);
    wire [31:0] next_checksum = checksum_accum + received_word;
    wire [31:0] line_word_addr = {2'b00, imem_addr[31:4], 2'b00};
    wire [31:0] payload_end_addr = start_word_addr + word_count;

    wire clearing_memory = (state == STATE_CLEAR_TAIL) || (state == STATE_CLEAR_ERROR);
    wire memory_write = !external_reset &&
        (clearing_memory || ((state == STATE_PAYLOAD) && received_word_valid));
    wire [ADDR_WIDTH-1:0] write_word_addr = clearing_memory ? clear_addr : current_addr;
    wire [1:0] write_bank = 2'(write_word_addr);
    wire [BANK_ADDR_WIDTH-1:0] write_row = BANK_ADDR_WIDTH'(write_word_addr >> 2);
    wire [31:0] write_data = clearing_memory ? NOP : received_word;
    wire [BANK_ADDR_WIDTH-1:0] read_row = BANK_ADDR_WIDTH'(imem_addr >> 4);

    assign rx_ready = CONFIG_VALID && (
        (state == STATE_MAGIC) ||
        (state == STATE_VERSION) ||
        (state == STATE_START) ||
        (state == STATE_COUNT) ||
        (state == STATE_CHECKSUM) ||
        (state == STATE_PAYLOAD));
    assign loader_done = done_reg;
    assign loader_busy = CONFIG_VALID && !done_reg && !error_reg;
    assign boot_error = !CONFIG_VALID || error_reg;
    assign imem_ready = loader_done && imem_read;

    // A line always contains words 4*k through 4*k+3. Interleave those words
    // across four single-read banks instead of replicating a four-read memory.
    // A loader/scrub write updates one bank; a line read uses all four banks.
    genvar bank;
    generate
        for (bank = 0; bank < 4; bank = bank + 1) begin : imem_banks
            reg [31:0] words[0:BANK_WORD_COUNT-1];
            integer row;
            initial begin
                for (row = 0; row < BANK_WORD_COUNT; row = row + 1)
                    words[row] = NOP;
            end
            always @(posedge clock) begin
                if (memory_write && (write_bank == bank))
                    words[write_row] <= write_data;
            end
            assign imem_rdata[32*bank +: 32] =
                ((line_word_addr + bank) < MEMORY_WORD_COUNT) ? words[read_row] : NOP;
        end
    endgenerate

    boot_reset_controller #(
        .BOOT_FROM_LOADER(1)
    ) reset_controller (
        .external_reset(external_reset),
        .loader_done(loader_done),
        .cpu_reset(cpu_reset),
        .boot_waiting(boot_waiting)
    );

    always @(posedge clock) begin
        if (external_reset) begin
            state <= STATE_MAGIC;
            byte_index <= 2'd0;
            word_buffer <= 32'h0;
            start_word_addr <= 32'h0;
            word_count <= 32'h0;
            expected_checksum <= 32'h0;
            checksum_accum <= 32'h0;
            words_loaded <= 32'h0;
            current_addr <= {ADDR_WIDTH{1'b0}};
            clear_addr <= {ADDR_WIDTH{1'b0}};
            done_reg <= 1'b0;
            error_reg <= 1'b0;
        end else begin
            if (state == STATE_CLEAR_TAIL) begin
                if (clear_addr == LAST_WORD_ADDR) begin
                    state <= STATE_DONE;
                    done_reg <= 1'b1;
                end else begin
                    clear_addr <= clear_addr + 1'b1;
                end
            end else if (state == STATE_CLEAR_ERROR) begin
                if (clear_addr == LAST_WORD_ADDR) begin
                    state <= STATE_ERROR;
                    error_reg <= 1'b1;
                end else begin
                    clear_addr <= clear_addr + 1'b1;
                end
            end else if (rx_valid && rx_ready) begin
                case (byte_index)
                    2'd0: begin
                        word_buffer[7:0] <= rx_data;
                        byte_index <= 2'd1;
                    end
                    2'd1: begin
                        word_buffer[15:8] <= rx_data;
                        byte_index <= 2'd2;
                    end
                    2'd2: begin
                        word_buffer[23:16] <= rx_data;
                        byte_index <= 2'd3;
                    end
                    default: begin
                        byte_index <= 2'd0;
                        word_buffer <= 32'h0;
                    end
                endcase

                if (received_word_valid) begin
                    // The parser rejects unexpected magic/version, nonzero
                    // start addresses, oversized payloads, and checksum
                    // mismatches before releasing the CPU from boot reset.
                    case (state)
                        STATE_MAGIC: begin
                            if (received_word == MAGIC_WORD) begin
                                state <= STATE_VERSION;
                            end else begin
                                state <= STATE_ERROR;
                                error_reg <= 1'b1;
                            end
                        end

                        STATE_VERSION: begin
                            if (received_word == VERSION_WORD) begin
                                state <= STATE_START;
                            end else begin
                                state <= STATE_ERROR;
                                error_reg <= 1'b1;
                            end
                        end

                        STATE_START: begin
                            if (received_word == 32'h0) begin
                                start_word_addr <= received_word;
                                current_addr <= received_word[ADDR_WIDTH-1:0];
                                state <= STATE_COUNT;
                            end else begin
                                state <= STATE_ERROR;
                                error_reg <= 1'b1;
                            end
                        end

                        STATE_COUNT: begin
                            if ((received_word != 32'h0) &&
                                (received_word <= MEMORY_WORD_COUNT) &&
                                ((start_word_addr + received_word) <= MEMORY_WORD_COUNT)) begin
                                word_count <= received_word;
                                state <= STATE_CHECKSUM;
                            end else begin
                                state <= STATE_ERROR;
                                error_reg <= 1'b1;
                            end
                        end

                        STATE_CHECKSUM: begin
                            expected_checksum <= received_word;
                            checksum_accum <= 32'h0;
                            words_loaded <= 32'h0;

                            state <= STATE_PAYLOAD;
                        end

                        STATE_PAYLOAD: begin
                            current_addr <= current_addr + 1'b1;
                            checksum_accum <= next_checksum;
                            words_loaded <= words_loaded + 32'd1;

                            if (words_loaded == word_count - 32'd1) begin
                                if (next_checksum == expected_checksum) begin
                                    if (payload_end_addr < MEMORY_WORD_COUNT) begin
                                        state <= STATE_CLEAR_TAIL;
                                        clear_addr <= payload_end_addr[ADDR_WIDTH-1:0];
                                    end else begin
                                        state <= STATE_DONE;
                                        done_reg <= 1'b1;
                                    end
                                end else begin
                                    state <= STATE_CLEAR_ERROR;
                                    clear_addr <= {ADDR_WIDTH{1'b0}};
                                end
                            end
                        end

                        default: begin
                            state <= state;
                        end
                    endcase
                end
            end
        end
    end

endmodule
