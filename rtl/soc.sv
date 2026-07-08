// Sample design: a tiny SoC used to exercise diagram generation.

module cpu (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] ibus_addr,
    input  logic [31:0] ibus_rdata,
    output logic [31:0] dbus_addr,
    output logic [31:0] dbus_wdata,
    input  logic [31:0] dbus_rdata,
    output logic        dbus_we,
    input  logic        irq
);
endmodule

module memory #(
    parameter int WORDS = 1024
) (
    input  logic        clk,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    input  logic        we
);
endmodule

module uart (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    input  logic        we,
    input  logic        rx,
    output logic        tx,
    output logic        irq
);
    typedef enum logic [1:0] {IDLE, START, DATA, STOP} tx_state_t;
    (* fsm_encoding = "auto" *) tx_state_t tx_state;
    logic [2:0] bit_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tx_state <= IDLE;
            bit_cnt  <= '0;
        end else begin
            case (tx_state)
                IDLE:  if (we) tx_state <= START;
                START: tx_state <= DATA;
                DATA:  begin
                    bit_cnt <= bit_cnt + 1'b1;
                    if (&bit_cnt) tx_state <= STOP;
                end
                STOP:  tx_state <= IDLE;
            endcase
        end
    end
    assign tx = (tx_state == IDLE);
endmodule

module gpio (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    input  logic        we,
    output logic [7:0]  port_out
);
endmodule

module bus_mux (
    input  logic [31:0] m_addr,
    input  logic [31:0] m_wdata,
    output logic [31:0] m_rdata,
    input  logic        m_we,
    output logic [31:0] s0_addr,
    output logic [31:0] s0_wdata,
    input  logic [31:0] s0_rdata,
    output logic        s0_we,
    output logic [31:0] s1_addr,
    output logic [31:0] s1_wdata,
    input  logic [31:0] s1_rdata,
    output logic        s1_we,
    output logic [31:0] s2_addr,
    output logic [31:0] s2_wdata,
    input  logic [31:0] s2_rdata,
    output logic        s2_we
);
endmodule

module top (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [7:0] gpio_out
);
    logic [31:0] ibus_addr, ibus_rdata;
    logic [31:0] dbus_addr, dbus_wdata, dbus_rdata;
    logic        dbus_we;
    logic        uart_irq;

    logic [31:0] ram_addr, ram_wdata, ram_rdata;
    logic        ram_we;
    logic [31:0] uart_addr, uart_wdata, uart_rdata;
    logic        uart_we;
    logic [31:0] gpio_addr, gpio_wdata, gpio_rdata;
    logic        gpio_we;

    cpu u_cpu (
        .clk        (clk),
        .rst_n      (rst_n),
        .ibus_addr  (ibus_addr),
        .ibus_rdata (ibus_rdata),
        .dbus_addr  (dbus_addr),
        .dbus_wdata (dbus_wdata),
        .dbus_rdata (dbus_rdata),
        .dbus_we    (dbus_we),
        .irq        (uart_irq)
    );

    memory #(.WORDS(4096)) u_rom (
        .clk   (clk),
        .addr  (ibus_addr),
        .wdata (32'h0),
        .rdata (ibus_rdata),
        .we    (1'b0)
    );

    bus_mux u_bus (
        .m_addr   (dbus_addr),
        .m_wdata  (dbus_wdata),
        .m_rdata  (dbus_rdata),
        .m_we     (dbus_we),
        .s0_addr  (ram_addr),
        .s0_wdata (ram_wdata),
        .s0_rdata (ram_rdata),
        .s0_we    (ram_we),
        .s1_addr  (uart_addr),
        .s1_wdata (uart_wdata),
        .s1_rdata (uart_rdata),
        .s1_we    (uart_we),
        .s2_addr  (gpio_addr),
        .s2_wdata (gpio_wdata),
        .s2_rdata (gpio_rdata),
        .s2_we    (gpio_we)
    );

    memory #(.WORDS(1024)) u_ram (
        .clk   (clk),
        .addr  (ram_addr),
        .wdata (ram_wdata),
        .rdata (ram_rdata),
        .we    (ram_we)
    );

    uart u_uart (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (uart_addr),
        .wdata (uart_wdata),
        .rdata (uart_rdata),
        .we    (uart_we),
        .rx    (uart_rx),
        .tx    (uart_tx),
        .irq   (uart_irq)
    );

    gpio u_gpio (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (gpio_addr),
        .wdata    (gpio_wdata),
        .rdata    (gpio_rdata),
        .we       (gpio_we),
        .port_out (gpio_out)
    );
endmodule
