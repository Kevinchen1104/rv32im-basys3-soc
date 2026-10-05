module width_cast_equivalence;
    (* anyseq *) reg [31:0] word_address;
    (* anyseq *) reg [31:0] byte_address;
    genvar width;
    generate
        for (width = 1; width <= 32; width = width + 1) begin : widths
            localparam ROW_WIDTH = (width > 2) ? width - 2 : 1;
            wire [width-1:0] write_word_addr = word_address[width-1:0];
            wire [1:0] old_bank = write_word_addr;
            wire [1:0] new_bank = 2'(write_word_addr);
            wire [ROW_WIDTH-1:0] old_write_row = write_word_addr >> 2;
            wire [ROW_WIDTH-1:0] new_write_row = ROW_WIDTH'(write_word_addr >> 2);
            wire [ROW_WIDTH-1:0] old_read_row = byte_address >> 4;
            wire [ROW_WIDTH-1:0] new_read_row = ROW_WIDTH'(byte_address >> 4);
            always @(*) begin
                assert(old_bank == new_bank);
                assert(old_write_row == new_write_row);
                assert(old_read_row == new_read_row);
            end
        end
    endgenerate
endmodule
