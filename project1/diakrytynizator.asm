; Project nr 1
; Author: Kamil Zwierzchowski
; Index: kz418510


global _start

MOD equ 0x10ff80         ; Polynomial modulo.
BOUND_NUM equ 0x10ffff   ; Max possible utf-8.
LOWER_NUM equ 0x30       ; Minimum number ASCII of digit.
UPPER_NUM equ 0x3a       ; Maximum number ASCII of digit.
PARITY_NUM equ 0x8       ; Parity bit of number 3 times shited left.
OLDEST_BIT equ 0x80      ; Oldest bit in byte.
OLDEST_POSSIBLE equ 22   ; Max number of bits used to code utf-8 number (not whole utf).
INPUT equ 0              
OUTPUT equ 1
SYS_READ equ 0           ; Read mode.
SYS_WRITE equ 1          ; Write mode.
SYS_EXIT equ 60          ; Sys exit.
BUFFER_SIZE equ 2048     ; Size of read and write buffer.
                         ; Can be changed in order to improve time by cost of memory.


section .data



AND_TESTER:              ; Numbers helpful to check if utf can be writen simpler.
  dd 0x00000000
  dd 0x00000000
  dd 0x0000001e
  dd 0x0000200f
  dd 0x00003007

XOR_DATA:                ; Oldest i bits set.
  db 0x00
  db 0x80
  db 0xc0
  db 0xe0
  db 0xf0

OLDEST_REMOVER:          ; Yongest i bits set.
  db 0xff
  db 0x7f
  db 0x3f
  db 0x1f
  db 0x0f
  db 0x07



section .bss



 
read_size: resd 1                   ; Number of bytes loaded in buffer.
read_pointer: resd 1                ; Pointer on first unused byte.
read_buffer: resb BUFFER_SIZE       ; Buffer.


write_pointer: resd 1               ; Pointer on first unused byte.
write_buffer: resb BUFFER_SIZE      ; Buffer.



section .text



; Computes number of leading ones in byte.
; One, and only one arguemnt is rdi register.
; Function returns result in rax register.
; Edits reigisters: rsi, rcx, rax.

first_zero:
         xor     eax, eax           ; Place for result.

first_loop:
         cmp     eax, 9             
         je      first_exit         ; Break, if result is 8.
         mov     esi, 1            
         mov     cl, 7
         sub     cl, al
         shl     esi, cl            ; Setting test for i-th bit.
         inc     eax             
         and     esi, edi           
         jnz     first_loop         ; Quit loop if not set.

first_exit:
         dec     eax             ; We kept result a little to big.
         ret                        


; Tries to get next byte of the input from buffer.
; If buffer empty, then tries to read into it.
; The only arugment is pointer, where byte should be saved. 
; If success, then returns in rax 1.
; Otherwise, if there is no more data in buffer and in input, then 0.
; Edits registers: rax, rdi, rdx.

get_byte:
         cmp     DWORD [read_pointer], 0 
         jnz     prepare_byte                 ; If buffer not empty, skip reading part.
         sub     rsp, 0x10                    
         mov     QWORD [rsp], rsi             ; Saving rsi for future recover.
         mov     eax, SYS_READ                
         mov     edi, INPUT                   
         mov     edx, BUFFER_SIZE             
         mov     rsi, read_buffer                                  
         syscall                              ; Trying to read BUFFER_SIZE bytes.
         mov     DWORD [read_size], eax       ; Setting size of buffer.
         mov     rsi, QWORD [rsp]             
         add     rsp, 0x10                    

prepare_byte:
         mov     eax, DWORD [read_pointer]               ; Pointer to current unchecked byte in bufer.
         cmp     eax, DWORD [read_size]                 
         jz      give_error                              ; If buffer exceeded, then error.
         mov     dl, BYTE [read_buffer + rax]       
         mov     BYTE [rsi], dl                          ; Saving byte into user pointer.
         inc     DWORD [read_pointer]             
         cmp     DWORD [read_pointer], BUFFER_SIZE   
         jnz     give_success                             
         mov     DWORD [read_pointer], 0   

give_success:
         mov     eax, 1
         ret

give_error:
         xor     eax, eax
         ret


; Writes on output bytes from buffer and removes them.
; Function does not take any arguments.
; Function does not return any values.
; Edited registers: rdi, rdx.

clear_buffer:
         sub     rsp, 0x10                 
         mov     QWORD [rsp], rsi          
         mov     QWORD [rsp + 0x8], rax     ; Saving rsi and rax.
         mov     eax, SYS_WRITE            
         mov     edi, OUTPUT                
         mov     edx, DWORD [write_pointer] 
         mov     rsi, write_buffer                  
         syscall                            ; Writing all bytes in buffer.
         mov     DWORD [write_pointer], 0   ; Buffer becomes empty.
         mov     rsi, QWORD [rsp]          
         mov     rax, QWORD [rsp + 0x8]
         add     rsp, 0x10                 
         ret  


; Put given byte on the write buffer.
; If full, then calls write_buffer.
; Function take as argument register rsi, which points to byte we want to add.
; Function does not return any values.
; Edited registers: rdi, rdx.

give_byte:
         sub     rsp, 0x10                            
         mov     QWORD [rsp], rax                     ; Saving rax.
         mov     eax, DWORD [write_pointer]            
         mov     dil, BYTE [rsi]                      
         mov     BYTE [write_buffer + rax], dil       ; Putting byte in buffer.
         inc     DWORD [write_pointer]              
         cmp     DWORD [write_pointer], BUFFER_SIZE    
         jnz     give_end                             
         call    clear_buffer                         ; If buffer full, write.

give_end:
         mov     rax, QWORD [rsp]
         add     rsp, 0x10
         ret


; Function a few bytes from read_buffer, that are needed to construct a valid utf-8.
; If succeeded, then puts on write_buffer recomputed by polynomial and recoded utf-8.
; In the end, function in rax returns 0.
; If it was not possible to construct a valid utf-8, then returns 1.
; If there was no more data on input, then returns 2.
; Function requires number of factors on top of stack.
; Futher on stack should be all factors of polynomial.
; Edited registers: rdi, rsi, rdx, rax, rcx, r8, r9, r10, r11.

get_utf:
         sub     rsp, 0x10
         mov     QWORD [rsp], 0
         mov     QWORD [rsp+0x8], 0   ; Creating some working space for later.
         mov     rsi, rsp; 
         call    get_byte;            ; First byte defines the length of utf-8.  
         cmp     rax, 1
         jnz     utf_end              ; If no byte left to read, return 2.
         mov     dil, BYTE [rsp]   
         call    first_zero           ; Computing first byte signature, from it depends utf size.
         mov     edx, 1
         mov     rsi, rsp 
         test    eax, eax            
         jz      utf_success          ; If it is only byte (ASCII code) just end here.
         cmp     eax, 1            
         jz      utf_unsuccess        ; First byte cannot have only one leading 1.
         cmp     eax, 5            
         jae     utf_unsuccess        ; First byte cannot have more than 4 leading 1.
         mov     r9, rax              ; r9 equals length of utf-8.
         mov     r8, 1             


get_rest:                                 ; Reading rest of utf-8.
         mov     rsi, rsp
         add     rsi, r8          
         call    get_byte                 
         cmp     eax, 1                   
         jnz     utf_unsuccess            ; If there is no more byte on input, then error.
         mov     dil, BYTE [rsp + r8]     
         call    first_zero               
         cmp     eax, 1                   
         jne     utf_unsuccess            ; Other bytes must have one leading 1.
         inc     r8                    
         cmp     r8, r9                   
         jne     get_rest                 
  
         mov     r8d, DWORD [AND_TESTER + 4*r9]  
         and     r8d, DWORD [rsp]                
         jz      utf_unsuccess                   ; Testing if utf-8 could be encoded simpler.
         xor     r8d, r8d                        ; Place for unicode.
         mov     r10, 1                          
         xor     r11d, r11d
         mov     r11b, BYTE [rsp]                
         xor     r11b, BYTE [XOR_DATA + r9]      ; Removing leading 1 from first byte.
         add     r8, r11                         

make_num:                              ; Computing unicode.
         shl     r8, 6                 ; Making place for less significant byte.
         mov     r11b, BYTE [rsp+r10]  
         xor     r11b, OLDEST_BIT      ; Removing leading 1.
         add     r8, r11               
         inc     r10                
         cmp     r10, r9               
         jnz     make_num              

         cmp     r8, BOUND_NUM         
         ja      utf_unsuccess         ; If unicode bigger than BOUND_NUM, error.
         sub     r8, OLDEST_BIT        ; Polynomial requires substraction.
         xor     eax, eax              ; Place for result.
         mov     r10, 1                ; Place for monomial x^i.
         mov     r11, 1                

polynomial_loop:                                   ; Mutliplying unicode by polynomial.
         mov     rdi, r10                          
         imul    rdi, QWORD [rsp + 8*r11 + 0x18]   ; Here i-th factor is written.
         add     rax, rdi                          
         mov     rdi, MOD                          
         xor     edx, edx                            
         div     rdi                               
         mov     rax, rdx                          ; Taking modulo of multiplication.
         mov     rbx, rax                          
         mov     rax, r10                          
         imul    rax, r8                           
         xor     edx, edx                            
         div     rdi                               
         mov     r10, rdx                          ; Taking modulo of multiplication.
         mov     rax, rbx                          
         inc     r11                            
         cmp     r11, QWORD [rsp + 0x18]           ; Here the number of factor is written.
         jnz     polynomial_loop                   

         add     rax, OLDEST_BIT   ; Recovering removed bit.
         mov     rdi, 1            
         mov     r8, 1             ; Here will be placed the most significant set bit.
         mov     r10, 1            
  
oldest_loop:                            ; Computing most significant bit of unicode.
         shl     rdi, 1                 
         inc     r10                 
         test    rax, rdi               
         jz      skip_update            
         mov     r8, r10                ; If bit i-th set, improving result.
skip_update:
         cmp     r10, OLDEST_POSSIBLE   
         jnz     oldest_loop            ; Result cannot be bigger than OLDEST_POSSIBLE.

         mov     QWORD [rsp], 0       
         mov     QWORD [rsp+0x8], 0   
         mov     r10d, 6                ; Coding bits in most significant byte.
         xor     r11d, r11d             ; Number of bytes needed to encode unicode.

coding_loop:                                      ; Computing utf-8 representation.
         mov     r9b, al                          
         and     r9b, BYTE [OLDEST_REMOVER + 2]   ; Taking first 6 least significant bit of unicode.
         xor     r9b, BYTE [XOR_DATA + 1]         ; Setting coding bits.
         mov     BYTE [rsp+r11], r9b              ; Saving byte.
         sub     r8, 6                            ; 6 bits less to encode.
         inc     r11                            
         dec     r10                              ; First byte has one less bit possible to code unicode.
         shr     rax, 6                           
         cmp     r8, r10                          
         jg      coding_loop                      ; If still not possible to encode rest on first byte, repeat.

         mov     r9b, al                               ; Last byte to encode.
         and     r9b, BYTE [OLDEST_REMOVER + r11 + 2]  
         xor     r9b, BYTE [XOR_DATA + r11 + 1]        ; Setting signature bits.
         mov     BYTE [rsp+r11], r9b                   
         mov     rsi, rsp                              
         add     rsi, r11                              

reverse_loop:                   ; Reversing utf-8 order.
         call    give_byte      ; Putting i-th byte on buffer.
         dec     rsi         
         cmp     rsi, rsp       
         jnz     reverse_loop   

utf_success:                    ; Function behavior if no error reported.
         call    give_byte      ; If it was ASCII or not, it should left one byte to write.
         xor     eax, eax
         add     rsp, 0x10
         ret 

utf_unsuccess:                  ; Function behavior if error occured.
         mov     rax, 1
         add     rsp, 0x10
         ret

utf_end:                        ; Function behavior if end of input.
         mov     rax, 2
         add     rsp, 0x10
         ret


; Function takes a set of bytes, treats them like ASCII.
; Function try to construct an integer from them modulo MOD.
; If succeeded, returns in rax the result.
; Otherwise, in rax returns MOD.
; Function as argument takes a pointer to the set in register rdi.
; Edited registers: rax, r8, rdi, rdx, r9.

to_int:
         xor     eax, eax   ; Place for result.

int_loop:                          ; Adding digits from most significant to less.
         xor     r8d, r8d             
         mov     r8b, BYTE [rdi]   ; Pointer to i-th digit.
         test    r8b, r8b            
         jz      int_success       ; End of digits.
         cmp     r8b, UPPER_NUM    
         jae     int_unsuccess     
         cmp     r8b, LOWER_NUM    
         jnae    int_unsuccess     ; If it is not digit, error.
         sub     r8b, LOWER_NUM    
         imul    rax, 10           ; Making place for new digit.
         add     rax, r8           
         xor     edx, edx            
         mov     r9, MOD           
         div     r9                
         mov     rax, rdx          ; Taking modulo.
         inc     rdi            
         jmp     int_loop          
  
int_success:
         ret
int_unsuccess:
         mov     rax, MOD
         ret


; Program takes from input data, and treats it as utf-8.
; Then takes every unicode, moves it through polynomial.
; The result is back encoded into utf-8 and it is printed on output.
; Program requires as arguments polynomial factors.
; If no arguments provided or arguments not a numbers, 1 is returned.
; Program writes only maximum prefix of valid utf-8.
; If not a valid utf-8 on input, 1 returned.
; Otherwise, 0 returned.

_start:
         cmp     QWORD [rsp], 1      
         jbe     exit_error          ; If less arguments than 2, error.
         mov     r10, 1              
         mov     r11, rsp            
         mov     rax, QWORD [rsp]    
         shl     rax, 3              
         sub     rsp, rax            ; Bytes needed on stack for factors.
         and     rax, PARITY_NUM     
         sub     rsp, rax            ; If odd, align to 16.
         mov     rdi, QWORD [r11]    
         mov     QWORD [rsp], rdi    ; On top of stack number of arguments put.
         add     r11, 0x10           
 
arg_loop:                                   ; Getting factors from program arguments.
         mov     rdi, QWORD [r11]           ; Getting pointer on i-th argument.
         call    to_int                     
         cmp     rax, MOD                   
         jz      exit_error                 ; If error in converting, error in program.
         mov     QWORD [rsp + 8*r10], rax   ; Putting result deeper on stack.
         add     r11, 8                     ; Moving pointer further.
         inc     r10                     
         cmp     r10, QWORD [rsp]           
         jnz     arg_loop                   

read_loop:                  ; Reading input while not empty nor error occured.
         call    get_utf    ; Reading utf-8.
         test    rax, rax     
         jz      read_loop  
  
         call    clear_buffer       ; Writing rest of bytes on buffer.
         mov     rdi, QWORD [rsp]   
         shl     rdi, 3             
         add     rsp, rdi           
         and     rdi, PARITY_NUM    ; Recovering stack.
         add     rsp, rdi           
         cmp     rax, 1             
         jz      exit_error         ; If error breaked because of error, then error.
  
exit_noerror:
         xor     edi, edi
         mov     eax, SYS_EXIT
         syscall

exit_error:
         mov     eax, SYS_EXIT
         mov     edi, 1
         syscall

