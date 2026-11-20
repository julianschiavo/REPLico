/* Keep the verified runtime and its notices in a read-only section of the app. */
#ifdef __APPLE__
#define SYMBOL(name) _##name
.section __TEXT,__const
#else
#define SYMBOL(name) name
.section .rodata
#endif

.globl SYMBOL(replico_node_gzip)
.globl SYMBOL(replico_node_license)
SYMBOL(replico_node_gzip):
.incbin "node.gz"
SYMBOL(replico_node_license):
.incbin "LICENSE"

#ifdef __ELF__
.section .note.GNU-stack,"",@progbits
#endif
