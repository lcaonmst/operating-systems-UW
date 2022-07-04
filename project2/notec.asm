; Function Notec.
; Author: Kamil Zwierzchowski.
; Index: kz418510.

global notec
extern debug
default rel


section .bss


; Protection of randez-vous structure. 
protection: resb 1


; Data for each of N avaible randez-vous table:

; First thread on table.
host: resq N

; Expected thread on table.
guest: resq N 

; Data which host offer in exchange with guest.
goods: resq N

; Flag indicating whether host is waitng for guest.
done: resb N



section .text



; Macro that tries to convert given byte to hex digit.
; %1 - reference to byte. 
; %2 - macro index.
; If succeeded, ZF unset and number stored in r8b.
; Otherwise ZF set.
; Edited registers: r15b, r8b. 
%macro digit_convert 2                ; Cheching if %1 in [0..9].
        mov     r15b, 1
        mov     r8b, %1
        cmp     r8b, '0'
        jb      second_check_%2
        cmp     r8b, '9'
        ja      second_check_%2
        sub     r8b, '0'
        jmp     number_cond_ok_%2  

second_check_%2:                      ; Checking if %1 in [a..f].
        cmp     r8b, 'a'
        jb      third_check_%2
        cmp     r8b, 'f'
        ja      third_check_%2
        sub     r8b, 'a'
        add     r8b, 10
        jmp     number_cond_ok_%2

third_check_%2:                       ; Checking if %1 in [A..F].
        cmp     r8b, 'A'
        jb      number_cond_error_%2
        cmp     r8b, 'F'
        ja      number_cond_error_%2
        sub     r8b, 'A'
        add     r8b, 10
        jmp     number_cond_ok_%2

number_cond_ok_%2:
        xor     r15b, r15b

number_cond_error_%2:
        test    r15b, r15b        
%endmacro


; Bunch of macros that unsets ZF if x is expected byte.
; Unsets otherwise.

%define digit_cond(x)   digit_convert x, 1

%define equal_cond(x)   cmp x, '='    

%define plus_cond(x)    cmp x, '+'

%define mul_cond(x)     cmp x, '*'

%define minus_cond(x)     cmp x, '-'

%define and_cond(x)     cmp x, '&'

%define or_cond(x)      cmp x, '|'

%define xor_cond(x)     cmp x, '^'

%define neg_cond(x)     cmp x, '~'

%define Z_cond(x)       cmp x, 'Z'

%define Y_cond(x)       cmp x, 'Y'

%define X_cond(x)       cmp x, 'X'

%define N_cond(x)       cmp x, 'N'

%define n_cond(x)       cmp x, 'n'

%define g_cond(x)       cmp x, 'g'

%define W_cond(x)       cmp x, 'W'


; Macro that handles operations which removes first number from stack.
; If ZF is set, all operations are skipped.
; %1 - mnemonic or macro that defines operation to execute on second number from stack.
; As arguments it takes first and second number from top of stack.
; %2 - index of macro.
; Decreases amount to add to rsp later by 8 bytes (r14).
; Increases pointer on ONP by one (r13).
%macro two_arg_func 2
        jnz     two_arg_func_end_%2
        mov     rax, QWORD [rsp]
        %1      rax, QWORD [rsp + 0x8]
        mov     QWORD [rsp + 0x8], rax
        add     rsp, 0x8
        sub     r14, 0x8
        inc     r13
two_arg_func_end_%2:
%endmacro

; Macro that handles operations which do not change size of stack.
; If ZF is set, all operations are skipped.
; %1 - mnemonic or macro that defines operation to execute on the first number from stack.
; As argument it takes first number from top of stack. 
; %2 - index of macro
; Increases pointer on ONP by one (r13). 
%macro one_arg_func 2
        jnz     one_arg_func_end_%2
        %1      QWORD [rsp]
        inc     r13
one_arg_func_end_%2:
%endmacro

; Macro that handles operations which adds element on the top of stack.
; If ZF is set, all operations are skipped.
; %1 - number that should be placed on the top of stack.
; %2 - index of macro.
; Increases amount to add to rsp later by 8 bytes (r14).
; Increases pointer on ONP by one (r13).
%macro one_arg_func_add 2
        jnz     one_arg_func_add_end_%2
        sub     rsp, 0x8
        mov     rax, QWORD [rsp + 0x8]
        mov     QWORD [rsp], %1
        add     r14, 0x8
        inc     r13
one_arg_func_add_end_%2:
%endmacro


%macro do_nothing 2
%endmacro

%macro do_nothing 1
%endmacro


; Macro that simulates P operation on mutex.
; %1 - protection.
; %2 - macro index.
%macro lock_prot 2
        mov     sil, 1

lock_loop_%2: 
        xchg    %1, sil
        test    sil, sil
        jnz     lock_loop_%2
%endmacro

; Macro that simulates V operation on mutex.
; %1 - protection.
%macro free_prot 1
        mov     %1, 0
%endmacro

; Macro that search for certain table.
; %1 - expected host.
; %2 - expected guest.
; %3 - expected status of goods exchange.
; Puts in rax index of satisfing table.
; If not found, puts N in rax.
%macro find_table 3
        mov     rax, N
        
find_table_loop_%3:
        dec     rax
        cmp     BYTE [done + rax], %3
        jnz     find_table_cond_%3
        cmp     QWORD [host + 8*rax], %1
        jnz     find_table_cond_%3
        cmp     QWORD [guest + 8*rax], %2
        jz      find_table_end_%3
find_table_cond_%3:
        test    rax, rax
        jnz     find_table_loop_%3

        mov     rax, N

find_table_end_%3:
%endmacro


; Bunch of macros that handles each possible function from ONP.
; If ZF is set, the operations from each function are skipped.
; Do not expect any paramters. 
; Each of them holds property: rsp + r14 + 0x20 = initial rsp from notec start.
; They may edit each scratch register in unpredicted manner except of:
; r12 - always const.
; r13 - function may increment register to make it point on unreaded byte.
; r14 - function may change register, but only in way that above property is hold.

; Reads number while digits on ONP.
%macro digit_func 0
        jnz     digit_func_end
        xor     eax, eax
        xor     r8d, r8d
        mov     r8b, BYTE [r13]
        digit_convert r8b, 2

digit_loop:
        shl     rax, 4
        add     rax, r8
        inc     r13
        mov     r8b, BYTE [r13]
        digit_convert r8b, 3
        jz      digit_loop

        sub     rsp, 0x8
        mov     QWORD [rsp], rax
        add     r14, 0x8

digit_func_end:        
%endmacro

%macro equal_func 0
       one_arg_func do_nothing, 2
%endmacro


%macro plus_func 0
        two_arg_func add, 3
%endmacro

%macro mul_func 0
        two_arg_func imul, 4
%endmacro


; Macro that simulates arithmetic negation of number.
%macro minus 1
        not     %1
        inc     %1
%endmacro

%macro minus_func 0
        one_arg_func minus, 5
%endmacro

%macro and_func 0
        two_arg_func and, 6
%endmacro

%macro or_func 0
        two_arg_func or, 7
%endmacro

%macro xor_func 0
        two_arg_func xor, 8
%endmacro 

%macro neg_func 0
        one_arg_func not, 9
%endmacro

%macro Z_func 0
        two_arg_func mov, 10
%endmacro

%macro Y_func 0
        one_arg_func_add rax, 11
%endmacro

%macro X_func 0
        jnz     X_func_end
        mov     rax, QWORD [rsp]
        mov     r8, QWORD [rsp + 0x8]
        mov     QWORD [rsp], r8
        mov     QWORD [rsp + 0x8], rax
        inc     r13
X_func_end:
%endmacro

%macro N_func 0
        one_arg_func_add N, 13
%endmacro

%macro n_func 0
        one_arg_func_add r12, 14
%endmacro

%macro g_func 0
        jnz     g_func_end
        mov     rdi, r12
        mov     rsi, rsp
        mov     r15, 0x8
        and     r15, rsp
        sub     rsp, r15      ; Aligns rsp to multiplyer of 16.
        call    debug
        shl     rax, 3
        add     rsp, rax
        add     rsp, r15
        sub     r14, rax
        inc     r13

g_func_end:
%endmacro

; Thread locks operations on table and search for table which satisfy conditions:
; 1. The table host expects the thread.
; 2. The thread expects the host.
; 3. Host did not have sucessful communication.
; If such table was found, thread exchange goods, unsets flag, return protection and exits.
; Otherwise, the thread creates own table with own expectations and offered goods.
; Then unlocks the protection and wait until other thread unsets his flag.
; If it happened, the thread takes given goods, clear the table and exits.
%macro W_func 0
        jnz     W_func_end
        mov     rdi, QWORD [rsp]
        add     rsp, 0x8
        sub     r14, 0x8
        inc     r13
        cmp     rdi, r12
        jz      W_func_end
        mov     r8, QWORD [rsp]
        lock_prot BYTE [protection], 1
        inc     rdi
        mov     rsi, r12
        inc     rsi
        find_table rdi, rsi, 1
        cmp     rax, N
        jz      W_func_create
        
        mov     r9, QWORD [goods + 8*rax]    ; A good partner has been found.
        mov     QWORD [goods + 8*rax], r8
        mov     QWORD [rsp], r9
        free_prot BYTE [done + rax]
        jmp     free_all


W_func_create:                               ; Partner has not been found.
        find_table 0, 0, 0
        mov     QWORD [host + 8*rax], rsi
        mov     QWORD [guest + 8*rax], rdi
        mov     QWORD [goods + 8*rax], r8        
        lock_prot BYTE [done + rax], 2
        free_prot BYTE [protection]
        
check_loop:                                  ; Waiting until communication ends.
        lock_prot BYTE [protection], 3
        mov     sil, 1
        xchg    sil, BYTE [done + rax]
        test    sil, sil
        jz     check_end
        free_prot BYTE [protection]
        jmp     check_loop        

check_end:                                   ; Communication completed.
        mov     r8, QWORD [goods + 8*rax]
        mov     QWORD [rsp], r8
        mov     QWORD [host + 8*rax], 0
        mov     QWORD [guest + 8*rax], 0
        mov     QWORD [goods + 8*rax], 0
        free_prot BYTE [done + rax]

free_all:
        free_prot BYTE [protection]

W_func_end:
%endmacro
                

; Macro that tries to match byte with some function.
%macro branch 1
        equal_cond(%1)
        equal_func
        plus_cond(%1)
        plus_func
        mul_cond(%1)
        mul_func
        minus_cond(%1)
        minus_func
        and_cond(%1)
        and_func
        or_cond(%1)
        or_func
        xor_cond(%1)
        xor_func
        neg_cond(%1)
        neg_func
        Z_cond(%1)
        Z_func
        Y_cond(%1)
        Y_func
        X_cond(%1)
        X_func
        N_cond(%1)
        N_func
        n_cond(%1)
        n_func
        g_cond(%1)
        g_func
        W_cond(%1)
        W_func
        digit_cond(%1)
        digit_func
%endmacro


; The main function. 
; As arguments takes:
; rdi - the number of thread.
; rsi - pointer on ONP.
; Additionaly function requires global variable N during compilation.
; In rax returns the value from the top of stack
; Uses registers in predicted way:
; r12 - the number of thread.
; r13 - pointer on ONP.
; r14 - length of ONP stack.
; Register from r1 to r11 may also be changed in some way.
notec:   
        sub     rsp, 0x20
        mov     QWORD [rsp], r12
        mov     QWORD [rsp + 0x8], r13
        mov     QWORD [rsp + 0x10], r14
        mov     QWORD [rsp + 0x18], r15
        mov     r12d, edi
        mov     r13, rsi
        xor     r14d, r14d

main_loop:
        branch  BYTE [r13]
        cmp     BYTE [r13], 0
        jnz     main_loop

        mov     rax, QWORD [rsp]
        add     rsp, r14
        mov     r12, QWORD [rsp]
        mov     r13, QWORD [rsp + 0x8]
        mov     r14, QWORD [rsp + 0x10]
        mov     r15, QWORD [rsp + 0x18]
        add     rsp, 0x20
        ret
