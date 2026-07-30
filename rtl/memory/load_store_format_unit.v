`timescale 1ns / 1ps

// Module: load_store_format_unit
// Role: RV32 load/store subword formatter shared by D-cache and MMIO paths.
// Interface: 32-bit memory word, store data, byte offset, funct3, formatted load value, and merged store word.
// Key behavior: Applies byte/half/word sign or zero extension on loads and byte-lane merging on stores.

module load_store_format_unit (
    input [31:0] word_data,
    input [31:0] store_data,
    input [1:0] byte_offset,
    input [2:0] funct3,
    output reg [31:0] load_value,
    output reg [31:0] store_merged_value
);

    always @(*) begin
        case (funct3)
            3'b000: begin
                case (byte_offset)
                    2'b00: load_value = {{24{word_data[7]}}, word_data[7:0]};
                    2'b01: load_value = {{24{word_data[15]}}, word_data[15:8]};
                    2'b10: load_value = {{24{word_data[23]}}, word_data[23:16]};
                    default: load_value = {{24{word_data[31]}}, word_data[31:24]};
                endcase
            end
            3'b001: begin
                if (byte_offset[1] == 1'b0) begin
                    load_value = {{16{word_data[15]}}, word_data[15:0]};
                end else begin
                    load_value = {{16{word_data[31]}}, word_data[31:16]};
                end
            end
            3'b010: begin
                load_value = word_data;
            end
            3'b100: begin
                case (byte_offset)
                    2'b00: load_value = {24'h0, word_data[7:0]};
                    2'b01: load_value = {24'h0, word_data[15:8]};
                    2'b10: load_value = {24'h0, word_data[23:16]};
                    default: load_value = {24'h0, word_data[31:24]};
                endcase
            end
            3'b101: begin
                if (byte_offset[1] == 1'b0) begin
                    load_value = {16'h0, word_data[15:0]};
                end else begin
                    load_value = {16'h0, word_data[31:16]};
                end
            end
            default: begin
                load_value = word_data;
            end
        endcase

        store_merged_value = word_data;
        case (funct3)
            3'b000: begin
                case (byte_offset)
                    2'b00: store_merged_value[7:0] = store_data[7:0];
                    2'b01: store_merged_value[15:8] = store_data[7:0];
                    2'b10: store_merged_value[23:16] = store_data[7:0];
                    default: store_merged_value[31:24] = store_data[7:0];
                endcase
            end
            3'b001: begin
                if (byte_offset[1] == 1'b0) begin
                    store_merged_value[15:0] = store_data[15:0];
                end else begin
                    store_merged_value[31:16] = store_data[15:0];
                end
            end
            3'b010: begin
                store_merged_value = store_data;
            end
            default: begin
                store_merged_value = store_data;
            end
        endcase
    end

endmodule
