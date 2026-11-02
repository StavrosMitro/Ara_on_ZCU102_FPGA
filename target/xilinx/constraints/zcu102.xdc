# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

#############
# Sys Clock #
#############

# ZCU102 300 MHz ( 3.333 ) — HP-bank system clock on AL8/AL7
set SYS_TCK 3.333
create_clock -period $SYS_TCK -name sys_clk [get_ports sys_clk_p]

# Το εσωτερικό ρολόι του SoC (50 MHz) που βγαίνει από το clock wizard
set SOC_TCK 20.0
# Looked up by NET, not by the clkwiz pin: with the clock knob (soc_mhz=/hp0_mhz=)
# soc_clk comes from an MMCM in cheshire_top_xilinx.sv and i_clkwiz does not exist.
# Same clock either way (the net is the BUFG output feeding the whole SoC).
set soc_clk [get_clocks -of_objects [get_nets soc_clk]]
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets soc_clk]

###############
# Assign Pins #
###############

# --- System Clock (125 MHz Differential, G21/F21 = HD bank: CANNOT drive MMCM, PLHDIO-4) ---
#set_property PACKAGE_PIN G21 [get_ports sys_clk_p]
#set_property IOSTANDARD LVDS_25 [get_ports sys_clk_p]
#set_property PACKAGE_PIN F21 [get_ports sys_clk_n]
#set_property IOSTANDARD LVDS_25 [get_ports sys_clk_n]

# --- System Clock (300 MHz Differential, AL8/AL7 = HP bank, clock-capable) ---
set_property PACKAGE_PIN AL8 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_p]
set_property PACKAGE_PIN AL7 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_n]

# --- JTAG Debugging (PMOD0 - J55 Header) ---
# Στέλνουμε το JTAG του RISC-V στο PMOD0 για να συνδέσεις εύκολα το HS2 καλώδιο.
# Τα PMODs του ZCU102 δουλεύουν στα 3.3V (LVCMOS33)
set_property PACKAGE_PIN A20 [get_ports jtag_tck_i] 
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tck_i] ;# PMOD0_0 

set_property PACKAGE_PIN B20 [get_ports jtag_tdi_i] 
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdi_i] ;# PMOD0_1 

set_property PACKAGE_PIN A22 [get_ports jtag_tdo_o] 
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdo_o] ;# PMOD0_2 

set_property PACKAGE_PIN A21 [get_ports jtag_tms_i] 
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tms_i] ;# PMOD0_3 

# (Το VDD και το GND του JTAG καλωδίου τα καρφώνεις στα αντίστοιχα pins τροφοδοσίας του PMOD header)
