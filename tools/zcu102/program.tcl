# Program the ZCU102 PL over JTAG.
#
#   vivado_lab -mode batch -nojournal -nolog \
#       -source tools/zcu102/program.tcl -tclargs <bitstream.bit> [hw_server_url]
#
# Success: the log contains "End of startup status: HIGH" and "PROGRAM_DONE".

if {[llength $argv] < 1} {
    puts "usage: -tclargs <bitstream.bit> \[hw_server_url\]"
    exit 1
}
set bit [lindex $argv 0]
set url [expr {[llength $argv] > 1 ? [lindex $argv 1] : "localhost:3121"}]

open_hw_manager
connect_hw_server -url $url
set t [lindex [get_hw_targets] 0]
open_hw_target $t
set_property PARAM.FREQUENCY 15000000 $t
set d [get_hw_devices xczu9_0]
current_hw_device $d
set_property PROGRAM.FILE $bit $d
program_hw_devices $d
puts "PROGRAM_DONE"
close_hw_target
disconnect_hw_server
exit
