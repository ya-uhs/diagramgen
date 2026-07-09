// Sample design: a small SoC exercising "real world" SystemVerilog —
// package, interface + modports, implemented submodules, an FSM,
// for-generate instances — to show the diagram generator handles them.

package soc_pkg;
    typedef logic [31:0] word_t;
    localparam int NUM_GPIO = 8;

    typedef enum logic [2:0] {
        ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR, ALU_SLT
    } alu_op_e;
endpackage

// Shared bus: one interface instance is one wire in the block diagram.
interface simple_bus;
    import soc_pkg::*;
    word_t addr;
    word_t wdata;
    word_t rdata;
    logic  we;
    logic  req;
    logic  ack;

    modport master (output addr, wdata, we, req, input rdata, ack);
    modport slave  (input addr, wdata, we, req, output rdata, ack);
endinterface

// --- CPU: register file + ALU submodules, fetch/execute FSM ------------

module regfile
    import soc_pkg::*;
(
    input  logic       clk,
    input  logic [4:0] raddr_a,
    input  logic [4:0] raddr_b,
    input  logic [4:0] waddr,
    input  word_t      wdata,
    input  logic       wen,
    output word_t      rdata_a,
    output word_t      rdata_b
);
    word_t regs [32];

    assign rdata_a = (raddr_a == '0) ? '0 : regs[raddr_a];
    assign rdata_b = (raddr_b == '0) ? '0 : regs[raddr_b];

    always_ff @(posedge clk) begin
        if (wen && waddr != '0)
            regs[waddr] <= wdata;
    end
endmodule

module alu
    import soc_pkg::*;
(
    input  alu_op_e op,
    input  word_t   a,
    input  word_t   b,
    output word_t   y,
    output logic    zero
);
    always_comb begin
        unique case (op)
            ALU_ADD: y = a + b;
            ALU_SUB: y = a - b;
            ALU_AND: y = a & b;
            ALU_OR:  y = a | b;
            ALU_XOR: y = a ^ b;
            ALU_SLT: y = word_t'($signed(a) < $signed(b));
            default: y = '0;
        endcase
    end
    assign zero = (y == '0);
endmodule

module cpu
    import soc_pkg::*;
(
    input  logic clk,
    input  logic rst_n,
    input  logic irq,
    simple_bus.master bus
);
    typedef enum logic [1:0] {FETCH, EXECUTE, MEMORY, WRITEBACK} phase_e;
    (* fsm_encoding = "auto" *) phase_e phase;

    word_t   pc, insn;
    word_t   rs1, rs2, alu_y;
    logic    alu_zero;
    alu_op_e alu_op;

    regfile u_regfile (
        .clk     (clk),
        .raddr_a (insn[19:15]),
        .raddr_b (insn[24:20]),
        .waddr   (insn[11:7]),
        .wdata   (alu_y),
        .wen     (phase == WRITEBACK),
        .rdata_a (rs1),
        .rdata_b (rs2)
    );

    alu u_alu (
        .op   (alu_op),
        .a    (rs1),
        .b    (rs2),
        .y    (alu_y),
        .zero (alu_zero)
    );

    assign alu_op = alu_op_e'(insn[14:12]);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phase <= FETCH;
            pc    <= '0;
        end
        else begin
            unique case (phase)
                FETCH:     if (bus.ack) phase <= EXECUTE;
                EXECUTE:   phase <= MEMORY;
                MEMORY:    if (bus.ack || !bus.req) phase <= WRITEBACK;
                WRITEBACK: begin
                    phase <= FETCH;
                    pc    <= alu_zero && irq ? '0 : pc + 4;
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (phase == FETCH && bus.ack)
            insn <= bus.rdata;
    end

    assign bus.addr  = (phase == FETCH) ? pc : alu_y;
    assign bus.wdata = rs2;
    assign bus.we    = (phase == MEMORY) && insn[5];
    assign bus.req   = (phase == FETCH) || (phase == MEMORY);
endmodule

// --- Interconnect: address-decoded 1-master / 3-slave mux --------------

module bus_mux
    import soc_pkg::*;
(
    simple_bus.slave  m,
    simple_bus.master ram,
    simple_bus.master uart,
    simple_bus.master gpio
);
    logic [1:0] sel;
    assign sel = m.addr[31:30];

    always_comb begin
        {ram.req, uart.req, gpio.req} = '0;
        unique case (sel)
            2'd1:    uart.req = m.req;
            2'd2:    gpio.req = m.req;
            default: ram.req  = m.req;
        endcase
    end

    assign ram.addr   = m.addr;
    assign ram.wdata  = m.wdata;
    assign ram.we     = m.we;
    assign uart.addr  = m.addr;
    assign uart.wdata = m.wdata;
    assign uart.we    = m.we;
    assign gpio.addr  = m.addr;
    assign gpio.wdata = m.wdata;
    assign gpio.we    = m.we;

    assign m.rdata = (sel == 2'd1) ? uart.rdata :
                     (sel == 2'd2) ? gpio.rdata : ram.rdata;
    assign m.ack   = (sel == 2'd1) ? uart.ack :
                     (sel == 2'd2) ? gpio.ack : ram.ack;
endmodule

// --- Peripherals ---------------------------------------------------------

module memory
    import soc_pkg::*;
#(
    parameter int WORDS = 1024
) (
    input  logic clk,
    simple_bus.slave bus
);
    word_t mem [WORDS];

    always_ff @(posedge clk) begin
        bus.rdata <= mem[bus.addr[$clog2(WORDS)+1:2]];
        bus.ack   <= bus.req;
        if (bus.req && bus.we)
            mem[bus.addr[$clog2(WORDS)+1:2]] <= bus.wdata;
    end
endmodule

module uart
    import soc_pkg::*;
(
    input  logic clk,
    input  logic rst_n,
    simple_bus.slave bus,
    input  logic rx,
    output logic tx,
    output logic irq
);
    typedef enum logic [1:0] {IDLE, START, DATA, STOP} tx_state_e;
    (* fsm_encoding = "auto" *) tx_state_e tx_state;
    logic [2:0] bit_cnt;
    logic [7:0] shifter;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tx_state <= IDLE;
            bit_cnt  <= '0;
        end
        else begin
            unique case (tx_state)
                IDLE: if (bus.req && bus.we) begin
                    tx_state <= START;
                    shifter  <= bus.wdata[7:0];
                end
                START: tx_state <= DATA;
                DATA: begin
                    bit_cnt <= bit_cnt + 1'b1;
                    shifter <= {1'b0, shifter[7:1]};
                    if (&bit_cnt) tx_state <= STOP;
                end
                STOP: tx_state <= IDLE;
            endcase
        end
    end

    assign tx        = (tx_state == IDLE)  ? 1'b1 :
                       (tx_state == START) ? 1'b0 : shifter[0];
    assign irq       = (tx_state == STOP);
    assign bus.rdata = {29'b0, rx, tx_state == IDLE, 1'b0};
    assign bus.ack   = bus.req;
endmodule

// 2FF synchronizer, instantiated per GPIO pin via for-generate.
module sync_ff (
    input  logic clk,
    input  logic d,
    output logic q
);
    logic meta;
    always_ff @(posedge clk) begin
        meta <= d;
        q    <= meta;
    end
endmodule

module gpio
    import soc_pkg::*;
(
    input  logic clk,
    input  logic rst_n,
    simple_bus.slave bus,
    input  logic [NUM_GPIO-1:0] pins_in,
    output logic [NUM_GPIO-1:0] pins_out
);
    logic [NUM_GPIO-1:0] sync_in;

    for (genvar i = 0; i < NUM_GPIO; i++) begin : g_sync
        sync_ff u_sync (
            .clk (clk),
            .d   (pins_in[i]),
            .q   (sync_in[i])
        );
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            pins_out <= '0;
        else if (bus.req && bus.we)
            pins_out <= bus.wdata[NUM_GPIO-1:0];
    end

    assign bus.rdata = {'0, sync_in};
    assign bus.ack   = bus.req;
endmodule

// --- Top -----------------------------------------------------------------

module top
    import soc_pkg::*;
(
    input  logic clk,
    input  logic rst_n,
    input  logic uart_rx,
    output logic uart_tx,
    input  logic [NUM_GPIO-1:0] gpio_in,
    output logic [NUM_GPIO-1:0] gpio_out
);
    simple_bus cpu_bus ();
    simple_bus ram_bus ();
    simple_bus uart_bus ();
    simple_bus gpio_bus ();

    logic uart_irq;

    cpu u_cpu (
        .clk   (clk),
        .rst_n (rst_n),
        .irq   (uart_irq),
        .bus   (cpu_bus.master)
    );

    bus_mux u_bus (
        .m    (cpu_bus.slave),
        .ram  (ram_bus.master),
        .uart (uart_bus.master),
        .gpio (gpio_bus.master)
    );

    memory #(.WORDS(4096)) u_ram (
        .clk (clk),
        .bus (ram_bus.slave)
    );

    uart u_uart (
        .clk   (clk),
        .rst_n (rst_n),
        .bus   (uart_bus.slave),
        .rx    (uart_rx),
        .tx    (uart_tx),
        .irq   (uart_irq)
    );

    gpio u_gpio (
        .clk      (clk),
        .rst_n    (rst_n),
        .bus      (gpio_bus.slave),
        .pins_in  (gpio_in),
        .pins_out (gpio_out)
    );
endmodule
