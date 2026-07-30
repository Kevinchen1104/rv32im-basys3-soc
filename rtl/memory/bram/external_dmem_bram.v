`timescale 1ns / 1ps

// Module: external_dmem_bram
// Role: One-outstanding-request external data memory for 128-bit cache lines.
// Interface: Line request/data ports, 16 byte enables, registered read data, pulsed completion, and configuration validity.
// Key behavior: Latches one request, performs a synchronous line read or byte-enabled write, and responds for one cycle without reaccepting a held request.
// Simulation setup: SIM_INIT_HEX initializes the simulation model only; synthesized hardware memory is populated by runtime writes.

module external_dmem_bram #(
    parameter WORD_COUNT = 1024,
    parameter SIM_INIT_HEX = "",
    parameter SIM_INIT_WORD_COUNT = WORD_COUNT
) (
    input clock,
    input reset,
    input [31:0] dmem_addr,
    input dmem_read,
    input dmem_write,
    input [127:0] dmem_wdata,
    input [15:0] dmem_byte_enable,
    output [127:0] dmem_rdata,
    output dmem_ready,
    output config_error,
    output reg read_seen,
    output reg write_seen
);

    localparam STORAGE_WORD_COUNT = (WORD_COUNT < 1) ? 1 : WORD_COUNT;
    localparam LINE_COUNT = (STORAGE_WORD_COUNT + 3) / 4;
    localparam LINE_ADDR_WIDTH = (LINE_COUNT <= 1) ? 1 : $clog2(LINE_COUNT);
    localparam EFFECTIVE_INIT_WORD_COUNT =
        (SIM_INIT_WORD_COUNT < WORD_COUNT) ? SIM_INIT_WORD_COUNT : WORD_COUNT;
    localparam INIT_CONFIG_VALID =
        (SIM_INIT_HEX == "") ||
        ((SIM_INIT_WORD_COUNT >= 0) && (SIM_INIT_WORD_COUNT <= WORD_COUNT));
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_EXECUTE = 2'd1;
    localparam [1:0] STATE_RESPOND = 2'd2;
    localparam [1:0] STATE_REJECT = 2'd3;

    wire [LINE_ADDR_WIDTH-1:0] request_line_addr =
        dmem_addr[LINE_ADDR_WIDTH+3:4];
    wire [31:0] request_word_addr = {2'b00, dmem_addr[31:4], 2'b00};
    wire request_in_range =
        (request_word_addr < WORD_COUNT) &&
        ((request_word_addr + 32'd3) < WORD_COUNT);

    (* ram_style = "block" *) reg [127:0] line_memory [0:LINE_COUNT-1];

    reg [1:0] state;
    reg [LINE_ADDR_WIDTH-1:0] pending_line_addr;
    reg [31:0] pending_word_addr;
    reg pending_write;
    reg [127:0] pending_wdata;
    reg [15:0] pending_byte_enable;
    reg [127:0] line_read_data;
    reg response_is_error;

`ifndef SYNTHESIS
    // Tests observe external storage through this word-addressed mirror. It is
    // excluded from synthesis and never feeds the hardware read datapath.
    reg [31:0] memory[0:STORAGE_WORD_COUNT-1];
`endif

    integer i;

    assign dmem_ready = (state == STATE_RESPOND);
    assign dmem_rdata = response_is_error ? 128'h0 : line_read_data;
    assign config_error =
        (WORD_COUNT < 4) ||
        ((WORD_COUNT % 4) != 0) ||
        !INIT_CONFIG_VALID;

    initial begin
        line_read_data = 128'h0;
        response_is_error = 1'b0;
        state = STATE_IDLE;
        pending_line_addr = {LINE_ADDR_WIDTH{1'b0}};
        pending_word_addr = 32'h0;
        pending_write = 1'b0;
        pending_wdata = 128'h0;
        pending_byte_enable = 16'h0;
        read_seen = 1'b0;
        write_seen = 1'b0;

`ifndef SYNTHESIS
        for (i = 0; i < STORAGE_WORD_COUNT; i = i + 1) begin
            memory[i] = 32'h0;
        end

        if ((SIM_INIT_HEX != "") && (EFFECTIVE_INIT_WORD_COUNT > 0)) begin
            $readmemh(SIM_INIT_HEX, memory, 0, EFFECTIVE_INIT_WORD_COUNT - 1);
        end

        for (i = 0; i < LINE_COUNT; i = i + 1) begin
            line_memory[i] = 128'h0;
        end

        // Word zero occupies bits [31:0] of each line, matching the cache and
        // DMA line ordering used throughout the external-memory interface.
        for (i = 0; i < WORD_COUNT; i = i + 1) begin
            case (i[1:0])
                2'd0: line_memory[i >> 2][31:0] = memory[i];
                2'd1: line_memory[i >> 2][63:32] = memory[i];
                2'd2: line_memory[i >> 2][95:64] = memory[i];
                default: line_memory[i >> 2][127:96] = memory[i];
            endcase
        end
`endif
    end

    always @(posedge clock) begin
        if (reset) begin
            state <= STATE_IDLE;
            pending_line_addr <= {LINE_ADDR_WIDTH{1'b0}};
            pending_word_addr <= 32'h0;
            pending_write <= 1'b0;
            pending_wdata <= 128'h0;
            pending_byte_enable <= 16'h0;
            line_read_data <= 128'h0;
            response_is_error <= 1'b0;
            read_seen <= 1'b0;
            write_seen <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (dmem_read || dmem_write) begin
                        if (request_in_range) begin
                            response_is_error <= 1'b0;
                            pending_line_addr <= request_line_addr;
                            pending_word_addr <= request_word_addr;
                            pending_write <= dmem_write;
                            pending_wdata <= dmem_wdata;
                            pending_byte_enable <= dmem_byte_enable;
                            state <= STATE_EXECUTE;
                        end else begin
                            // Reject out-of-range traffic before the RAM access
                            // state so the synchronous BRAM template stays
                            // simple and cannot alias a low line.
                            response_is_error <= 1'b1;
                            state <= STATE_REJECT;
                        end

                        // A simultaneous read/write is defined as a write.
                        // Current CPU/DMA arbitration never generates both.
                        if (dmem_write) begin
                            write_seen <= 1'b1;
                        end else begin
                            read_seen <= 1'b1;
                        end
                    end
                end

                STATE_EXECUTE: begin
                    if (pending_write) begin
                        if (pending_byte_enable[0])  line_memory[pending_line_addr][7:0] <= pending_wdata[7:0];
                        if (pending_byte_enable[1])  line_memory[pending_line_addr][15:8] <= pending_wdata[15:8];
                        if (pending_byte_enable[2])  line_memory[pending_line_addr][23:16] <= pending_wdata[23:16];
                        if (pending_byte_enable[3])  line_memory[pending_line_addr][31:24] <= pending_wdata[31:24];
                        if (pending_byte_enable[4])  line_memory[pending_line_addr][39:32] <= pending_wdata[39:32];
                        if (pending_byte_enable[5])  line_memory[pending_line_addr][47:40] <= pending_wdata[47:40];
                        if (pending_byte_enable[6])  line_memory[pending_line_addr][55:48] <= pending_wdata[55:48];
                        if (pending_byte_enable[7])  line_memory[pending_line_addr][63:56] <= pending_wdata[63:56];
                        if (pending_byte_enable[8])  line_memory[pending_line_addr][71:64] <= pending_wdata[71:64];
                        if (pending_byte_enable[9])  line_memory[pending_line_addr][79:72] <= pending_wdata[79:72];
                        if (pending_byte_enable[10]) line_memory[pending_line_addr][87:80] <= pending_wdata[87:80];
                        if (pending_byte_enable[11]) line_memory[pending_line_addr][95:88] <= pending_wdata[95:88];
                        if (pending_byte_enable[12]) line_memory[pending_line_addr][103:96] <= pending_wdata[103:96];
                        if (pending_byte_enable[13]) line_memory[pending_line_addr][111:104] <= pending_wdata[111:104];
                        if (pending_byte_enable[14]) line_memory[pending_line_addr][119:112] <= pending_wdata[119:112];
                        if (pending_byte_enable[15]) line_memory[pending_line_addr][127:120] <= pending_wdata[127:120];

`ifndef SYNTHESIS
                        if (pending_byte_enable[0])  memory[pending_word_addr + 0][7:0] <= pending_wdata[7:0];
                        if (pending_byte_enable[1])  memory[pending_word_addr + 0][15:8] <= pending_wdata[15:8];
                        if (pending_byte_enable[2])  memory[pending_word_addr + 0][23:16] <= pending_wdata[23:16];
                        if (pending_byte_enable[3])  memory[pending_word_addr + 0][31:24] <= pending_wdata[31:24];
                        if (pending_byte_enable[4])  memory[pending_word_addr + 1][7:0] <= pending_wdata[39:32];
                        if (pending_byte_enable[5])  memory[pending_word_addr + 1][15:8] <= pending_wdata[47:40];
                        if (pending_byte_enable[6])  memory[pending_word_addr + 1][23:16] <= pending_wdata[55:48];
                        if (pending_byte_enable[7])  memory[pending_word_addr + 1][31:24] <= pending_wdata[63:56];
                        if (pending_byte_enable[8])  memory[pending_word_addr + 2][7:0] <= pending_wdata[71:64];
                        if (pending_byte_enable[9])  memory[pending_word_addr + 2][15:8] <= pending_wdata[79:72];
                        if (pending_byte_enable[10]) memory[pending_word_addr + 2][23:16] <= pending_wdata[87:80];
                        if (pending_byte_enable[11]) memory[pending_word_addr + 2][31:24] <= pending_wdata[95:88];
                        if (pending_byte_enable[12]) memory[pending_word_addr + 3][7:0] <= pending_wdata[103:96];
                        if (pending_byte_enable[13]) memory[pending_word_addr + 3][15:8] <= pending_wdata[111:104];
                        if (pending_byte_enable[14]) memory[pending_word_addr + 3][23:16] <= pending_wdata[119:112];
                        if (pending_byte_enable[15]) memory[pending_word_addr + 3][31:24] <= pending_wdata[127:120];
`endif
                    end else begin
                        line_read_data <= line_memory[pending_line_addr];
                    end

                    state <= STATE_RESPOND;
                end

                STATE_REJECT: begin
                    state <= STATE_RESPOND;
                end

                STATE_RESPOND: begin
                    // Do not accept a still-asserted request in the response
                    // cycle; the requester observes ready and drops it here.
                    state <= STATE_IDLE;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
