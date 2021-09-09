dnl	Macro for easily using enums in assembly. Simply call `ENUM(IDENTIFIER)` and a constant
dnl	with name IDENTIFIER will be defined with the value of 1. Every subsequent use of ENUM()
dnl	will increment the value assigned to the constant by 1.
define(`__COUNTER', 0)
define(`ENUM', `.equ $1, define(`__COUNTER', incr(__COUNTER))__COUNTER')
