section .text
global dump

dump:
    sub     rsp, 40
    mov     byte [rsp + 31], `\n`
    test    rdi, rdi
    je      .iszero
    mov     rcx, -1
    mov     r8, 0xCCCCCCCCCCCCCCCD
.loop:
    mov     rax, rdi
    mul     r8
    shr     rdx, 3
    lea     eax, [rdx + rdx]
    lea     eax, [rax + 4*rax]
    mov     esi, edi
    sub     esi, eax
    or      sil, '0'
    mov     [rsp + rcx + 31], sil
    dec     rcx
    cmp     rdi, 9
    mov     rdi, rdx
    ja      .loop
    neg     rcx
    jmp     .done
.iszero:
    mov     ecx, 1
.done:
    mov     rsi, rsp
    sub     rsi, rcx
    add     rsi, 32
    mov     edi, 1
    mov     rdx, rcx
    mov     rax, 1
    syscall
    add     rsp, 40
    ret
