#!/bin/awk -f

function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s) { return rtrim(ltrim(s)); }

function clear_function_vars() {
	function_report = 0	# boolean to print function report
	function_text = ""	# disassembly text
	stack_allocated = 0	# function allocates a stack frame
	bp_copied = 0		# backpointer copied into register
	bp_pushed = 0		# backpointer pushed onto stack
}

function print_function_report()
{
	if (function_name && function_text && (verbose || function_report)) {
		printf("%s :: %s()\n", file_name, function_name)
		printf("%s\n", function_text)
		printf("\n")
	}
}


BEGIN {
	# Branch instruction list - an array of interesting branch
	# instructions in which its containing function should be saving
	# a backpointer if has allocated a frame pointer.
	#
	# BAL: branch and link
	# BALR: branch and link
	# Information from the current PSW, including the updated instruction
	# address, is loaded as link information at the first-operand location
	branch_ins[1] = "bal"
	branch_ins[2] = "balr"

	# BAS: branch and save
	# BASR: branch and save
	# Bits 32-63 of the current PSW, including the updated instruction
	# address, are saved as link information at the first-operand location
	branch_ins[3] = "bas"
	branch_ins[4] = "basr"

	# BASSM: branch and save and set mode
	# Bits 32-63 of the current PSW, including the updated instruction
	# address, are saved as link information at the first-operand location.
	branch_ins[5] = "bassm"

	# BRAS: branch relative and save
	# BRASL: branch relative and save long
	# Bits 32-63 of the current PSW, including the updated instruction
	# address, are saved as link information at the first-operand location
	# branch_ins[6] = "bras"	# note: skip these as they are all local branches
	branch_ins[7] = "brasl"

	file_name = ""
	clear_function_vars()
}

# File header looks like (always line #2):
# path/to/source:                file format <ELF fmt>
# ----------------------------------------------------
# kernel/livepatch/shadow.o:     file format elf64-s390
NR == 2 {
	file_name = $1
	sub(":", "", file_name)
	next
}

# Function header looks like:
# offset           <function_name>:
# ---------------------------------
# 0000000000000000 <__klp_shadow_get_or_alloc>:
/^[0-9a-f]* <.*>:/ {
	function_name = $2
	sub("<", "", function_name)
	sub(">", "", function_name)
	sub(":", "", function_name)
	next
}

#
# Disassembly looks like:
# off:	hex code values 	ins	[operarand(s)]
#-----------------------------------------------------
#   0:	c0 04 00 00 00 00 	brcl	0,0 <klp_shadow_get>
/^[ 0-9a-f]*:\t[0-9a-f ]*/ {

	function_text = function_text "\n" $0

	split($0, line, "\t")
	off=trim(line[1]); sub(":", "", off)
	ins=line[3]
	ops=line[4]

	# Instruction decode
	#
	# gcc backpointer looks like:
	#   lgr     %r14,%r15			# save SP into regX
	#   lay     %r15,-152(%r15)		# allocate stack
	#   stg     %r14,0(%r15)		# push regX on new stack[0]
	#
	# some assembly code sets up stack frame like:
	#
	# ENTRY(s390_base_mcck_handler)
	# 	basr	%r13,0
	# 0:	lg	%r15,__LC_PANIC_STACK	# load panic stack
	# 	aghi	%r15,-STACK_FRAME_OVERHEAD
	# 	larl	%r1,s390_base_mcck_handler_fn


	if (ins == "lay" && (index(ops, "%r15") != 0)) {
		function_text = function_text "\n\t\t\tobjtool: stack allocation (lay)"
		stack_allocated = 1
	} else if (ins == "aghi" && (index(ops, "%r15") != 0)) {
		# STACK_FRAME_OVERHEAD = 160 for s390x, but we will accept
		# any stack frame size for our check
		function_text = function_text "\n\t\t\tobjtool: stack allocation (aghi)"
		stack_allocated = 1
	} else if (ins == "lgr" && ops ~ /%r[0-9]*,%r15/) {
       		function_text = function_text "\n\t\t\tobjtool: register copy of backptr"
		bp_copied = 1
	} else if (ins == "stg" && ops ~ /%r[0-9]*,152\(%r15\)/) {
       		function_text = function_text "\n\t\t\tobjtool: backptr pushed"
		bp_pushed = 1
	} else {
		for (b in branch_ins) {
			if (ins == branch_ins[b]) {
				if (!stack_allocated || !bp_copied || !bp_pushed) {
       					function_text = function_text "\n\t\t\tobjtool: suspect branch, stack_allocated=" stack_allocated " bp_copy=" bp_copied " bp_pushed=" bp_pushed " !!!"
					function_report = 1
				}
			}
		}
	}

	next
}

# Relocations look like:
#			off: RELOC_TYPE		symbol[+off]
#			206: R_390_PLT32DBL	__copy_from_user+0x2
/[\t]*[0-9a-f]*R_390.*/ {
	function_text = function_text "\n" $0
	next
}

# Blank lines between functions, dump report and reset function vars
{
	print_function_report()
	clear_function_vars()
}

# Dump last function in every file, too
END {
	print_function_report()
}
