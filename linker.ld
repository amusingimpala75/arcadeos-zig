/* limine zig barebones linker script */

/* Tell the linker that we want an x86_64 ELF64 output file */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

/* We want the symbol _start to be our entry point */
ENTRY(_start)

/* Define the program headers we want so the bootloader gives us the right */
/* MMU permissions */
PHDRS
{
    text    PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* Execute + Read */
    rodata  PT_LOAD    FLAGS((1 << 2)) ;            /* Read only */
    data    PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* Write + Read */
    dynamic PT_DYNAMIC FLAGS((1 << 1) | (1 << 2)) ; /* Dynamic PHDR for relocations */
}

KERNEL_OFFSET = 0xffffffff80000000;
PAGE_SIZE = 0x1000;

SECTIONS
{
    /* We wanna be placed in the topmost 2GiB of the address space, for optimisations */
    /* and because that is what the Limine spec mandates. */
    /* Any address in this region will do, but often 0xffffffff80000000 is chosen as */
    /* that is the beginning of the region. */
    . = KERNEL_OFFSET;

    .text : AT(ADDR(.text) - KERNEL_OFFSET) {
        *(.text .text.*)
    } :text

    . = ALIGN(PAGE_SIZE);

    .rodata : AT(ADDR(.rodata) - KERNEL_OFFSET) {
        *(.rodata .rodata.*)

	/* Waiting on issue ziglang/zig#7962 */

    	/*__debug_info_start = .;
	KEEP(*(.debug_info))
    	__debug_info_end = .;
        __debug_abbrev_start = .;
        KEEP(*(.debug_abbrev))
        __debug_abbrev_end = .;
        __debug_str_start = .;
        KEEP(*(.debug_str))
        __debug_str_end = .;
        __debug_line_start = .;
        KEEP(*(.debug_line))
        __debug_line_end = .;
        __debug_ranges_start = .;
        KEEP(*(.debug_ranges))
        __debug_ranges_end = .;*/
    } :rodata

    . = ALIGN(PAGE_SIZE);

    .data : AT(ADDR(.data) - KERNEL_OFFSET) {
        *(.data .data.*)
    } :data

    . = ALIGN(PAGE_SIZE);

    /* Dynamic section for relocations, both in its own PHDR and inside data PHDR */
    .dynamic : AT(ADDR(.dynamic) - KERNEL_OFFSET) {
        *(.dynamic)
    } :data :dynamic

    . = ALIGN(PAGE_SIZE);

    /* NOTE: .bss needs to be the last thing mapped to :data, otherwise lots of */
    /* unnecessary zeros will be written to the binary. */
    /* If you need, for example, .init_array and .fini_array, those should be placed */
    /* above this. */
    .bss : AT(ADDR(.bss) - KERNEL_OFFSET) {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /* Discard .note.* and .eh_frame since they may cause issues on some hosts. */
    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
    }
}
