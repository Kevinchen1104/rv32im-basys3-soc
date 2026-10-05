`timescale 1ns / 1ps

// A set/way reference model checks the public lookup and refill interface.
module icache_geometry_case #(
    parameter BYTES = 64,
    parameter PARALLEL = 0,
    parameter EXTERNAL = 1
) (output reg done = 0);
    localparam SETS = BYTES / 32;
    reg clock = 0, reset = 1, ready = 0, cancel = 0;
    reg [31:0] pc = 0;
    wire [31:0] instruction, refill;
    wire hint, miss, busy, read_request;
    wire [127:0] line_data;
    reg model_valid [0:SETS-1][0:1];
    reg [31:0] model_line [0:SETS-1][0:1];
    reg model_lru [0:SETS-1];
    reg [31:0] random_state = 32'h72b9_041d;
    integer s, w, n, count = 0;

    function [31:0] word_at(input [31:0] address);
        // Return metadata must follow the selected word, not just the line.
        word_at = (address[3:2] == 1) ? 32'h0000_8067 : (address ^ 32'h9375_a013);
    endfunction
    assign line_data = {word_at(refill + 12), word_at(refill + 8),
                        word_at(refill + 4), word_at(refill)};
    icache_unit #(.USE_EXTERNAL_IMEM(EXTERNAL), .CACHE_BYTES(BYTES),
                  .PARALLEL_LOOKUP(PARALLEL)) dut (
        .clock(clock), .reset(reset), .pc(pc), .internal_line_data(line_data),
        .external_line_data(line_data), .external_ready(ready), .cancel_refill(cancel),
        .instruction(instruction), .return_hint(hint), .miss(miss), .busy(busy),
        .external_read(read_request), .refill_addr(refill), .state_debug(),
        .stall_debug(), .lru_set0_debug(), .lru_set1_debug()
    );
    always #5 clock = ~clock;

    task step;
        begin @(posedge clock); #1; end
    endtask
    task clear_cache;
        begin
            @(negedge clock); reset = 1; ready = 0; cancel = 0;
            step();
            for (s = 0; s < SETS; s = s + 1) begin
                model_lru[s] = 0;
                for (w = 0; w < 2; w = w + 1) model_valid[s][w] = 0;
            end
            @(negedge clock); reset = 0;
        end
    endtask
    task access_word(input [31:0] address, input integer delay_cycles);
        integer index, way, victim;
        reg [31:0] aligned;
        begin
            // Set PC immediately after the preceding task (no unmodeled
            // rising edge may start a request between accesses).
            pc = address; ready = 0; cancel = 0;
            #1;
            index = (address >> 4) % SETS;
            aligned = {address[31:4], 4'b0};
            way = -1;
            if (model_valid[index][0] && model_line[index][0] == aligned) way = 0;
            if (model_valid[index][1] && model_line[index][1] == aligned) way = 1;
            if (busy !== 0 || miss !== (way == -1))
                $fatal(1, "lookup mismatch bytes=%0d parallel=%0d external=%0d pc=%h", BYTES, PARALLEL, EXTERNAL, address);
            if (way == -1) begin
                if (instruction !== 32'h13 || hint !== 0) $fatal(1, "invalid payload escaped");
                victim = !model_valid[index][0] ? 0 :
                         (!model_valid[index][1] ? 1 : model_lru[index]);
                step();
                if (refill !== aligned || busy !== 1) $fatal(1, "captured refill address");
                if (EXTERNAL) begin
                    repeat (delay_cycles) begin
                        step();
                        if (read_request !== 1 || busy !== 1 || refill !== aligned)
                            $fatal(1, "external refill lost while waiting");
                    end
                    @(negedge clock); ready = 1;
                    step();
                end else begin
                    repeat (3) step();
                end
                model_valid[index][victim] = 1;
                model_line[index][victim] = aligned;
                way = victim;
            end
            if (busy !== 0 || miss !== 0 || instruction !== word_at(address) ||
                hint !== ((word_at(address) & 32'hffff_8fff) == 32'h0000_8067))
                $fatal(1, "word/metadata mismatch bytes=%0d pc=%h actual=%h", BYTES, address, instruction);
            step();
            model_lru[index] = !way;
            count = count + 1;
            @(negedge clock); ready = 0;
        end
    endtask

    task cancel_request(input integer same_cycle);
        begin
            clear_cache();
            pc = 32'hf123_0040;
            step();
            @(negedge clock); cancel = 1;
            // A changed PC must not become the refill destination.
            pc = 32'h8123_0080;
            if (EXTERNAL) begin
                ready = same_cycle;
                step();
                if (!same_cycle) begin
                    @(negedge clock); cancel = 0; ready = 1;
                    step();
                end
            end else begin
                step();
                @(negedge clock); cancel = 0;
                repeat (2) step();
            end
            @(negedge clock); ready = 0; cancel = 0;
            access_word(32'hf123_0040, 1);
            access_word(32'h8123_0080, 2);
        end
    endtask

    initial begin
        clear_cache();
        // Fill both ways in every set, touch each word, then force conflicts.
        for (n = 0; n < SETS; n = n + 1) begin
            access_word(n * 16, 1);
            access_word(n * 16 + SETS * 16, 2);
            access_word(n * 16 + 4, 0);
            access_word(n * 16 + SETS * 32 + 8, 3);
            access_word(n * 16 + 12, 1);
            access_word(n * 16 + SETS * 16, 1);
        end
        for (n = 0; n < 300; n = n + 1) begin
            random_state = random_state ^ (random_state << 13);
            random_state = random_state ^ (random_state >> 17);
            random_state = random_state ^ (random_state << 5);
            access_word((n % 3 == 0) ? (random_state & (BYTES - 4)) :
                        (random_state & 32'hffff_fffc), n % 4);
        end
        cancel_request(0);
        cancel_request(1);
        // Reset during a pending response must discard it and clear tags.
        pc = 32'hdead_bee0; step();
        clear_cache();
        access_word(32'hdead_bee0, 2);
        $display("geometry bytes=%0d parallel=%0d external=%0d accesses=%0d passed", BYTES, PARALLEL, EXTERNAL, count);
        done = 1;
    end
endmodule

module tb_icache_geometry;
    wire [11:0] done;
    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : profiles
        localparam BYTES = (i < 2) ? 64 : ((i == 2) ? 256 : 1024);
        icache_geometry_case #(.BYTES(BYTES), .PARALLEL(i == 0), .EXTERNAL(0)) a(done[i*2]);
        icache_geometry_case #(.BYTES(BYTES), .PARALLEL(i == 0), .EXTERNAL(1)) b(done[i*2+1]);
    end endgenerate
    icache_geometry_case #(.BYTES(128)) c(done[8]);
    icache_geometry_case #(.BYTES(512)) d(done[9]);
    icache_geometry_case #(.BYTES(2048)) e(done[10]);
    icache_geometry_case #(.BYTES(4096)) f(done[11]);
    initial begin
        wait (&done);
        $display("PASS: tb_icache_geometry passed");
        $finish;
    end
    initial begin #2000000; $fatal(1, "geometry timeout"); end
endmodule
