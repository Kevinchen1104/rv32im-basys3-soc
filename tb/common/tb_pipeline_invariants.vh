    integer pipeline_invariant_i;
    integer pipeline_poison_i;
    integer pipeline_poison_slot;
    reg [31:0] pipeline_poison_pc [0:7];
    reg [3:0] pipeline_poison_age [0:7];

    initial begin
        for (pipeline_invariant_i = 0; pipeline_invariant_i < 8; pipeline_invariant_i = pipeline_invariant_i + 1) begin
            pipeline_poison_pc[pipeline_invariant_i] = 32'h0;
            pipeline_poison_age[pipeline_invariant_i] = 4'd0;
        end
    end

    task pipeline_invariant_fail;
        input [1023:0] message;
        begin
            $display("FAIL: pipeline invariant violated: %0s", message);
            $display("      PC=%h IFID(valid=%b pc=%h) IDEX(valid=%b pc=%h) EXMEM(valid=%b pc=%h) MEMWB(valid=%b pc=%h)",
                     dut.PC,
                     dut.IFIDValid, dut.IFIDPC,
                     dut.IDEXValid, dut.IDEXPC,
                     dut.EXMEMValid, dut.EXMEMPC,
                     dut.MEMWBValid, dut.MEMWBPC);
            $fatal;
        end
    endtask

    task pipeline_add_poison_pc;
        input [31:0] pc;
        begin
            if (pc[1:0] != 2'b00) begin
                pipeline_invariant_fail("attempted to poison an unaligned PC");
            end

            pipeline_poison_slot = -1;
            for (pipeline_poison_i = 0; pipeline_poison_i < 8; pipeline_poison_i = pipeline_poison_i + 1) begin
                if (pipeline_poison_age[pipeline_poison_i] == 4'd0 && pipeline_poison_slot == -1) begin
                    pipeline_poison_slot = pipeline_poison_i;
                end
            end

            if (pipeline_poison_slot == -1) begin
                pipeline_poison_slot = 0;
            end

            pipeline_poison_pc[pipeline_poison_slot] = pc;
            pipeline_poison_age[pipeline_poison_slot] = 4'd8;
        end
    endtask

    function pipeline_pc_is_poisoned;
        input [31:0] pc;
        integer index;
        begin
            pipeline_pc_is_poisoned = 1'b0;
            for (index = 0; index < 8; index = index + 1) begin
                if (pipeline_poison_age[index] != 4'd0 && pipeline_poison_pc[index] == pc) begin
                    pipeline_pc_is_poisoned = 1'b1;
                end
            end
        end
    endfunction

    always @(posedge clock) begin
        #1;

        if (reset) begin
            for (pipeline_invariant_i = 0; pipeline_invariant_i < 8; pipeline_invariant_i = pipeline_invariant_i + 1) begin
                pipeline_poison_age[pipeline_invariant_i] = 4'd0;
            end

            if (dut.PC !== 32'h0 ||
                dut.IFIDValid !== 1'b0 ||
                dut.IDEXValid !== 1'b0 ||
                dut.EXMEMValid !== 1'b0 ||
                dut.MEMWBValid !== 1'b0 ||
                dut.TraceValid !== 1'b0 ||
                dut.RASCount !== 4'd0) begin
                pipeline_invariant_fail("reset did not clear key pipeline control state");
            end
        end else begin
            if (dut.Regs[0] !== 32'h0) begin
                pipeline_invariant_fail("x0 changed from zero");
            end

            if (dut.PC[1:0] !== 2'b00) begin
                pipeline_invariant_fail("fetch PC is not word-aligned");
            end
            if (dut.IFIDValid && dut.IFIDPC[1:0] !== 2'b00) begin
                pipeline_invariant_fail("IF/ID valid PC is not word-aligned");
            end
            if (dut.IDEXValid && dut.IDEXPC[1:0] !== 2'b00) begin
                pipeline_invariant_fail("ID/EX valid PC is not word-aligned");
            end
            if (dut.EXMEMValid && dut.EXMEMPC[1:0] !== 2'b00) begin
                pipeline_invariant_fail("EX/MEM valid PC is not word-aligned");
            end
            if (dut.MEMWBValid && dut.MEMWBPC[1:0] !== 2'b00) begin
                pipeline_invariant_fail("MEM/WB valid PC is not word-aligned");
            end

            if (dut.MEMWBRegWrite && !dut.MEMWBValid) begin
                pipeline_invariant_fail("register writeback asserted while MEM/WB is invalid");
            end
            if (dut.MEMWBRegWrite && dut.MEMWBrd == 5'd0) begin
                pipeline_invariant_fail("register writeback attempted to x0");
            end
            if (dut.TraceValid && !dut.MEMWBValid) begin
                pipeline_invariant_fail("trace_valid asserted without a valid committed MEM/WB row");
            end
            if (dut.TraceValid && (trace_valid !== dut.TraceValid ||
                                   trace_pc !== dut.MEMWBPC ||
                                   trace_instruction !== dut.MEMWBIR ||
                                   trace_reg_write !== dut.MEMWBRegWrite)) begin
                pipeline_invariant_fail("trace output fields do not match the committed MEM/WB row");
            end

            if (!dut.EXMEMValid &&
                (dut.gen_dcache.dcache.request_valid ||
                 dut.EXMEMMmioAccess ||
                 dut.debug_status_store_commit)) begin
                pipeline_invariant_fail("invalid EX/MEM payload authorized a memory/MMIO side effect");
            end
            if ((dut.GPIOOutput !== gpio_outputs) && dut.EXMEMValid) begin
                pipeline_invariant_fail("GPIO output port diverged from CPU GPIOOutput register");
            end

            // Registered control recovery bubbles the held ID/EX dynamic
            // instruction. Poisoning IF/ID by address can misclassify a
            // separately fetched correct target at the same PC.
            if (dut.control_redirect_apply && dut.IDEXValid) begin
                pipeline_add_poison_pc(dut.IDEXPC);
            end else if ((dut.exception_taken ||
                         dut.interrupt_taken ||
                         dut.mret_taken) &&
                        dut.IFIDValid) begin
                pipeline_add_poison_pc(dut.IFIDPC);
            end

            if (dut.MEMWBValid && dut.MEMWBRegWrite && pipeline_pc_is_poisoned(dut.MEMWBPC)) begin
                pipeline_invariant_fail("poisoned wrong-path PC reached register writeback");
            end
            if (dut.EXMEMValid && dut.EXMEMMemWrite && pipeline_pc_is_poisoned(dut.EXMEMPC)) begin
                pipeline_invariant_fail("poisoned wrong-path PC reached memory/MMIO write");
            end
            if (dut.TraceValid && pipeline_pc_is_poisoned(dut.MEMWBPC)) begin
                pipeline_invariant_fail("poisoned wrong-path PC appeared in retired trace");
            end

            for (pipeline_invariant_i = 0; pipeline_invariant_i < 8; pipeline_invariant_i = pipeline_invariant_i + 1) begin
                if (pipeline_poison_age[pipeline_invariant_i] != 4'd0) begin
                    pipeline_poison_age[pipeline_invariant_i] = pipeline_poison_age[pipeline_invariant_i] - 4'd1;
                end
            end
        end
    end
