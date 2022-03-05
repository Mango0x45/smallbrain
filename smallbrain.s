.equ EOF, -1
.equ O_RDONLY, 0
.equ EXIT_FAILURE, 1

// Opcodes
ENUM(OP_ADD)
ENUM(OP_SUB)
ENUM(OP_RIGHT)
ENUM(OP_LEFT)
ENUM(OP_LOOP_START)
ENUM(OP_LOOP_END)
ENUM(OP_READ)
ENUM(OP_WRITE)
ENUM(OP_ZERO)
ENUM(OP_COPY)

.global main

.data
zero_pattern:	.asciz "[-]"
read_mode:	.asciz "r"
die_fmt:	.asciz "%s: %s\n"
usage_fmt:	.asciz "Usage: %s script\n"
func_open:	.asciz "open"
func_fstat:	.asciz "fstat"
func_read:	.asciz "read"
func_malloc:	.asciz "malloc"
memory:		.zero 30000

.bss
bytecode:	.quad 0
program:	.quad 0

.text
// ==================
// Description:
//	The entry point of the program.
//
// Args:
//	%rdi: The number of command line arguments
//	%rsi: An array of command line arguments ((%rsi) is the program name)
//
// Return:
//	%rax: The programs exit code
// ==================
main:
	// Make sure that the right number of arguments were passed
	cmpl	$2, %edi
	jne	usage

	movq	8(%rsi), %rdi // Move the specified script filename into %rdi
	call	read_file     // Read the file
	call	compile       // Compile into bytecode
	call	execute       // Execute the program

	// Return successfully
	xorl	%eax, %eax
	ret

// ==================
// Description:
//	Read the specified file into a program buffer which the user must later free themselves.
//
// Args:
//	%rdi: The scripts filename
// ==================
read_file:
	pushq	%rbp
	movq	%rsp, %rbp

	// Allocate space for local variables
	// 	4 bytes for the file descriptor
	//	144 bytes for the struct stat (check `extras/sizeof_struct_stat.c` for numbers)
	//	12 bytes of padding to align %rsp on a 16 byte boundary
	subq	$160, %rsp

	// Open the file in read-only mode with the open(2) syscall
	movl	$O_RDONLY, %esi
	call	open

	cmpl	$-1, %eax      // Check if open(1) returned -1 (it failed)
	je	open_die       // If so, exit the program
	movl	%eax, -4(%rbp) // If not store the file descriptor

	movl	%eax, %edi       // Set the first argument to the file descriptor
	leaq	-160(%rbp), %rsi // Set the second argument to the address of the struct stat
	call	fstat            // Call fstat(2) to populate the struct stat

	// Error check fstat(2) just like open(2)
	cmpl	$-1, %eax
	je	fstat_die

	// Allocate a buffer for the programs contents
	movq	-112(%rbp), %rdi // Put st_size (the filesize) in %rdi
	incq	%rdi             // Make space for the NUL byte
	pushq	%rdi             // Store the value of %rdi for the next 2 malloc calls
	call	malloc           // Allocate the memory
	testq	%rax, %rax       // Check if %rax is NULL
	je	malloc_die       // If it is then malloc failed and we exit
	movq	%rax, (program)  // Store the address of the allocated memory in (program)
	addq	-112(%rbp), %rax // Point to the last element of the program array
	movb	$0, (%rax)       // NULL terminate the program

	// Allocate a buffer for the bytecode
	popq	%rdi             // Retrieve %rdi from the stack
	shlq	$4, %rdi         // Multiply the size of the buffer by 16 to make space for opcodes
	call	malloc           // Allocate the memory
	movq	%rax, (bytecode) // Store the address of the allocated memory in (bytecode)
	testq	%rax, %rax       // Check if %rax is NULL
	je	malloc_die       // If it is then malloc failed and we exit

	// Get a FILE* from the file descriptor with fdopen(3)
	movl	-4(%rbp), %edi
	movq	$read_mode, %rsi
	call	fdopen

	pushq	%rax            // Push the FILE* to the stack for the later call to fclose(3)
	movq	(program), %r15 // Move the program buffer into %r15

// cmpjeq - Compare Jump Equal Quadword
// ====================================
// Compare the value of 'val' to %rax and if they match jump to 'jump'.
.macro cmpjeq val, jump
	cmpq	\val, %rax
	je	\jump
.endm

// cmpjeb - Compare Jump Equal Byte
// ================================
// Compare the value of 'val' to %al and if they match jump to 'jump'.
.macro cmpjeb val, jump
	cmpb	\val, %al
	je	\jump
.endm

read_file_loop:
	movq	-168(%rbp), %rdi // Move the FILE* into %rdi
	call	fgetc            // Read a character from the file
	cmpl	$EOF, %eax       // Check if we reached EOF
	je	read_file_eof    // If we did then end the loop

	// If we match any non-comment character jump to read_file_not_comment
	cmpjeb	$'+', read_file_not_comment
	cmpjeb	$'-', read_file_not_comment
	cmpjeb	$'>', read_file_not_comment
	cmpjeb	$'<', read_file_not_comment
	cmpjeb	$'[', read_file_not_comment
	cmpjeb	$']', read_file_not_comment
	cmpjeb	$',', read_file_not_comment
	cmpjeb	$'.', read_file_not_comment
	// DEFAULT CASE (its a comment we can ignore)
	jmp	read_file_loop

read_file_not_comment:
	movb	%al, (%r15)    // Read the character into the program buffer
	incq	%r15           // Point to the next empty slot in the buffer
	jmp	read_file_loop // Loop again

read_file_eof:
	// NUL terminate the buffer
	movb	$0, (%r15)

	// Close the file, don't error check this
	movq	-168(%rbp), %rdi
	call	fclose

	leave
	ret

// ==================
// Description:
//	Compile the program into a bytecode which is an optimized version of the raw program. Each
//	opcode is a "struct" where the higher 8 bytes are an opcode and the lower 8 are data for
//	the instruction.
// ==================
compile:
	movq	(program), %r15  // Store the address of the program pointer into %r15
	movq	(bytecode), %r14 // Store the address of the bytecode pointer into %r14
compile_loop:
	// Load the current command into %rax
	movq	(%r15), %rax

	// Jump to a different label depending on which instruction we hit
	cmpjeb	$'+', compile_add
	cmpjeb	$'-', compile_sub
	cmpjeb	$'>', compile_right
	cmpjeb	$'<', compile_left
	cmpjeb	$'[', compile_loop_start
	cmpjeb	$']', compile_loop_end
	cmpjeb	$',', compile_read
	cmpjeb	$'.', compile_write

compile_add:
	movq	$OP_ADD, (%r14) // Specify the ADD opcode
	movq	$1, 8(%r14)     // Write the count of '+'s to the data portion
compile_add_loop:
	incq	%r15             // Move to the next instruction
	cmpb	$'+', (%r15)     // Check if there is another +
	jne	compile_out      // If not, exit this loop
	incq	8(%r14)          // Increment the accumulator
	jmp	compile_add_loop // Loop again

compile_sub:
	movq	$OP_SUB, (%r14) // Specify the SUB opcode
	movq	$1, 8(%r14)     // Write the count of '-'s to the data portion
compile_sub_loop:
	incq	%r15             // Move to the next instruction
	cmpb	$'-', (%r15)     // Check if there is another -
	jne	compile_out      // If not, exit this loop
	incq	8(%r14)          // Increment the accumulator
	jmp	compile_sub_loop // Loop again

compile_right:
	movq	$OP_RIGHT, (%r14) // Specify the RIGHT opcode
	movq	$1, 8(%r14)       // Write the count of '>'s to the data portion
compile_right_loop:
	incq	%r15               // Move to the next instruction
	cmpb	$'>', (%r15)       // Check if there is another >
	jne	compile_out        // If not, exit this loop
	incq	8(%r14)            // Increment the accumulator
	jmp	compile_right_loop // Loop again

compile_left:
	movq	$OP_LEFT, (%r14) // Specify the LEFT opcode
	movq	$1, 8(%r14)      // Write the count of '<'s to the data portion
compile_left_loop:
	incq	%r15              // Move to the next instruction
	cmpb	$'<', (%r15)      // Check if there is another <
	jne	compile_out       // If not, exit this loop
	incq	8(%r14)           // Increment the accumulator
	jmp	compile_left_loop // Loop again

compile_loop_start:
	// When we reach a '[' the first thing we want to do is check to see if it matches the
	// pattern '[-]'. This pattern is one that sets a memory cell to 0, so we can optimize that.
	movq	%r15, %rdi          // Compare the current position in the program string
	movq	$zero_pattern, %rsi // Compare it against the zero pattern '[-]'
	movl	$4, %ecx            // We want to compare 3 bytes (the instruction requires +1)
	repe	cmpsb               // Keep looping CMPSB while bytes match
	jrcxz	compile_zero        // Jump to compile_zero if the strings matched

	movq	%r15, %rdi                // Move the current instruction pointer into %rdi
	call	copy_loop_checker         // Call the copy loop checker
	testq	%rax, %rax                // Check to see if we hit a copy loop
	jz	compile_loop_start_normal // If we didn't, this is a regular loop
	movq	%rax, %r15                // Otherwise, set %r15 to the new location
	incq	%r15                      // Then point to the next instruction
	jmp	compile_out

compile_loop_start_normal:
	// Push the address of the loop start to the stack for the next ']'
	pushq	%r14

	movq	$OP_LOOP_START, (%r14) // Specify the LOOP_START opcode
	movq	$0, 8(%r14)            // Zero the data section
	incq	%r15                   // Increment the instruction pointer
	jmp	compile_out

compile_loop_end:
	popq	8(%r14)              // Pop the address of the previous loop start to the data section
	movq	$OP_LOOP_END, (%r14) // Push the address of the loop end to the stack
	incq	%r15                 // Increment the instruction pointer
	jmp	compile_out

compile_read:
	movq	$OP_READ, (%r14) // Specify the READ opcode
	movq	$0, 8(%r14)      // Zero the data section
	incq	%r15             // Increment the instruction pointer
	jmp	compile_out

compile_write:
	movq	$OP_WRITE, (%r14) // Specify the WRITE opcode
	movq	$0, 8(%r14)       // Zero the data section
	incq	%r15              // Increment the instruction pointer
	jmp	compile_out

compile_zero:
	movq	$OP_ZERO, (%r14) // Specify the ZERO opcode
	movq	$0, 8(%r14)      // Zero the data section
	addq	$3, %r15         // '[-]' is a 3 byte instruction
	// FALLTHROUGH

compile_out:
	addq	$16, %r14    // Move to the next opcode
	movb	(%r15), %al  // Move the current instruction into %al
	testb	%al, %al     // Check if we have reached the NUL byte
	jne	compile_loop // If we haven't, loop
	movq	$0, (%r14)   // Otherwise, NUL terminate the bytecode

	// Now that we have traversed the entire program, we do a 2nd pass backwards so that we can
	// set the jump addresses for the '[' commands now that the ']' commands have the addresses
	// set.
compile_backwards:
	// We are at the NUL terminator, so move backwards
	subq	$16, %r14

	cmpq	$OP_LOOP_END, (%r14)   // Check if we hit a ']'
	jne	compile_backwards_next // If we didn't move to the next check
	pushq	%r14                   // Otherwise push the address of the opcode to the stack
	jmp	compile_backwards_out

compile_backwards_next:
	cmpq	$OP_LOOP_START, (%r14) // Check if we hit a '['
	jne	compile_backwards_out  // If we didn't just keep looping
	popq	8(%r14)                // If we did then pop the corresponding ']' address

compile_backwards_out:
	cmpq	%r14, (bytecode)  // Check if we've seen every opcode
	jne	compile_backwards // If not keep looping
	movq	(program), %rdi   // Otherwise, move the program buffer to %rdi
	call	free              // Free it
	ret                       // And return

// ==================
// Description:
//	Try to figure out if we are at a copy loop and optimize it. A copy loop follows the pattern
//	of a loop ([]) beginning with a '-' followed by N occurances of '>' followed by a '+' and N
//	occurances of '<'. This sequence copies the current cell to the cell at offset N and clears
//	the current cell afterwards.
//
// Args:
//	%rdi: A pointer to the first '[' of the potential copy loop
//
// Return:
//	0 if not a copy loop, otherwise the new position of the instruction pointer.
// ==================
copy_loop_checker:
	// Skip '['
	incq	%rdi

	// All copy loops must begin with a '-'
	cmpb	$'-', (%rdi)
	jne	copy_loop_fail
	incq	%rdi

	// Zero %rax so we can use it to count the copy offset
	xorl	%eax, %eax
copy_loop_count_offset:
	cmpb	$'>', (%rdi)           // Check for '>'
	jne	copy_loop_next         // If we don't match anymore then move to the next step
	incq	%rax                   // Increment the offset counter
	incq	%rdi                   // Increment the instruction pointer
	jmp	copy_loop_count_offset // Loop again

copy_loop_next:
	cmpb	$'+', (%rdi)   // Check if we see the mandatory '+'
	jne	copy_loop_fail // If we don't then fail
	incq	%rdi           // Otherwise move to the next instruction

	// The following code is the exact same as what we just did to count the offset but we are
	// now using %rcx and decrementing for each '<'. This is so we can make sure that the copy
	// loop is a working one.
	cmpb	$'<', (%rdi)
	jne	copy_loop_fail
	movq	%rax, %rcx
copy_loop_verify_offset:
	cmpb	$'<', (%rdi)
	jne	copy_loop_next_2
	decq	%rcx
	incq	%rdi

copy_loop_next_2:
	cmpb	$']', (%rdi)   // Ensure this is the end of the loop
	jne	copy_loop_fail // If its not then fail
	testq	%rcx, %rcx     // Otherwise make sure that our offsets line up
	jnz	copy_loop_fail // If they don't then fail

	movq	$OP_COPY, (%r14)   // Create an OP_COPY opcode
	movq	%rax, 8(%r14)      // Set the offset to copy to
	movq	$OP_ZERO, 16(%r14) // Create an OP_ZERO opcode
	movq	$0, 24(%r14)       // Set an empty data section
	addq	$16, %r14          // Increment the opcode pointer

	// Return the address of the instruction pointer
	movq	%rdi, %rax
	ret
copy_loop_fail:
	xorl	%eax, %eax
	ret

// ==================
// Description:
//	Execute the brainfuck bytecode.
// ==================
execute:
	movq	(bytecode), %r15 // Store the address of the program pointer into %r15
	movq	$memory, %r14    // Store the address of the first memory cell into %r14 # TODO make sure this handles overflows normally
execute_loop:
	// Load the current command into %rax
	movq	(%r15), %rax

	// Jump to a different label depending on which instruction we hit
	cmpjeq	$OP_ADD, execute_add
	cmpjeq	$OP_SUB, execute_sub
	cmpjeq	$OP_RIGHT, execute_right
	cmpjeq	$OP_LEFT, execute_left
	cmpjeq	$OP_LOOP_START, execute_loop_start
	cmpjeq	$OP_LOOP_END, execute_loop_end
	cmpjeq	$OP_READ, execute_read
	cmpjeq	$OP_WRITE, execute_write
	cmpjeq	$OP_ZERO, execute_zero
	// OP_COPY
	jmp	execute_copy

execute_add:
	// Increment the current memory cell
	movq	8(%r15), %rax
	addb	%al, (%r14)
	jmp	execute_out

execute_sub:
	// Decrement the current memory cell
	movq	8(%r15), %rax
	subb	%al, (%r14)
	jmp	execute_out

execute_right:
	// Move the memory pointer right
	addq	8(%r15), %r14
	jmp	execute_out

execute_left:
	// Move the memory pointer left
	subq	8(%r15), %r14
	jmp	execute_out

execute_loop_start:
	// If the current memory cell is 0 move to the next ']'
	cmpb	$0, (%r14)
	cmovzq	8(%r15), %r15
	jmp	execute_out

execute_loop_end:
	// If the current memory cell is not 0 move to the last '['
	cmpb	$0, (%r14)
	cmovnzq	8(%r15), %r15
	jmp	execute_out

execute_read:
	// Set the current cell to the character read from stdin
	call	getchar          // Read a character with getchar(3)
	cmpb	$EOF, %al        // Check if the EOF was read
	je	execute_read_eof // If EOF was read, jump to a special handler for that
	movb	%al, (%r14)      // Otherwise move the read character into the current memory cell
	jmp	execute_out

execute_read_eof:
	// If EOF was read, set the current cell to 0
	movb	$0, (%r14)
	jmp	execute_out

execute_write:
	// Print the character at the current memory cell
	movl	(%r14), %edi // Move the current memory cell into %edi
	call	putchar      // Print it with putchar(3)
	jmp	execute_out

execute_zero:
	// Zero the current cell
	movb	$0, (%r14)
	jmp	execute_out

execute_copy:
	// Copy the current memory cells contents elsewhere
	movq	8(%r15), %rax
	movb	(%r14), %cl
	movb	%cl, (%rax, %r14, 1)
	// FALLTHROUGH

execute_out:
	addq	$16 , %r15   // Increment the instruction pointer
	movq	(%r15), %rax // Move the current instruction into %rax
	testq	%rax, %rax   // Check if we have reached the NUL byte
	jne	execute_loop // If we haven't, loop
	ret                  // Otherwise, return

// ==================
// Description:
//	The following die functions all work the same. They simply take the name of the
//	corresponding function and store it in %rdi. Then the die function is called to print a
//	message to stderr and terminate the program.
// ==================

.macro fdie s
	movq	\s, %rdi
	jmp	die
.endm

open_die:	fdie	$func_open
fstat_die:	fdie	$func_fstat
read_die:	fdie	$func_read
malloc_die:	fdie	$func_malloc


// ==================
// Description:
//	Print out an error message in the format "<func name>: <err msg>" then exit via `_exit`
//
// Args:
//	%rdi: The function name
// ==================
die:
	// Store the function name temporarily in %r15
	movq	%rdi, %r15

	call	__errno_location // Call __errno_location to get a pointer to errno
	movq	(%rax), %rdi     // Move errno into %rdi
	call	strerror         // Get the error string with strerror(3)

	movq	%rax, %rcx     // Set the error string
	xorl	%eax, %eax     // Zero %rax
	movq	%r15, %rdx     // Set the function name
	movq	$die_fmt, %rsi // Set the format string
	movq	stderr, %rdi   // Get stderr 
	call	fprintf        // Print the message to stderr

	jmp	_exit

// ==================
// Description:
//	Print a usage message to standard error and exit the program via `_exit`
// ==================
usage:
	xorl	%eax, %eax       // Set rax to 0
	movq	(%rsi), %rdx     // Get argv[0]
	movq	$usage_fmt, %rsi // Set the format string
	movq	stderr, %rdi     // Get stderr 
	call	fprintf          // Print the error
	// FALLTHROUGH

// ==================
// Description:
//	Exit the program with the return code EXIT_FAILURE
// ==================
_exit:
	movl	$EXIT_FAILURE, %eax
	call	exit
