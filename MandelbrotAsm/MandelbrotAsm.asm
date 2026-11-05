; ============================================================================
; Projekt: Generator Zbioru Mandelbrota z antyaliasingiem SSAA 2x2
; Plik:    MandelbrotAsm.asm
; Modu:   Niskopoziomowa biblioteka wektorowa x64 (MASM / ml64.exe)
;
; Architektura: x64 (AMD64 / Intel 64)
; Zestaw instrukcji: AVX2 / SSE4.1
; Zgodno z ABI: Microsoft x64 Calling Convention (Windows Fastcall)
; ============================================================================

.code

; ============================================================================
; Procedura wewntrzna: MandelbrotVectorKernel
;
; Opis:
;   Wykonuje jednoczesne obliczenia ucieczki dla 4 prbek SSAA 2x2 w obChannelie
;   jednego piksela przy uyciu rejestrw wektorowych AVX2 (YMM).
;   Wyznacza uredniony kolor BGRA (32-bitowy) z wykorzystaniem operacji
;   wektorowych i deterministycznej arytmetyki cakowitoliczbowej.
;
; Rejestry wejciowe:
;   YMM0 - wsprzdne rzeczywiste 4 subpikseli: [cr0, cr1, cr0, cr1]
;   YMM1 - wsprzdne urojone 4 subpikseli:     [ci0, ci0, ci1, ci1]
;   R8D  - maxIterations (maksymalna liczba iteracji)
;
; Rejestr wyjciowy:
;   EAX  - 32-bitowy kolor w formacie BGRA (B: bity 0-7, G: 8-15, R: 16-23, A: 24-31)
;
; Wytyczne implementacyjne:
;   - Brak uycia zmiennych globalnych (dane tworzone wycznie w rejestrach).
;   - Brak powolnych instrukcji PINSRB / PEXTRB do skadania bajtw.
;   - Wykorzystanie operacji wektorowych: VMULPD, VADDPD, VSUBPD, VCMPPD,
;     VPMULLD, VPAND, VPHADDD, VPSRLD.
; ============================================================================
MandelbrotVectorKernel PROC
    ; ------------------------------------------------------------------------
    ; Inicjalizacja staych w rejestrach wektorowych (brak zmiennych globalnych)
    ; ------------------------------------------------------------------------
    mov     rax, 4010000000000000h      ; 4.0 (format IEEE 754 double precision)
    vmovq   xmm4, rax
    vbroadcastsd ymm4, xmm4             ; YMM4 = [4.0, 4.0, 4.0, 4.0]

    mov     rax, 4000000000000000h      ; 2.0 (format IEEE 754 double precision)
    vmovq   xmm5, rax
    vbroadcastsd ymm5, xmm5             ; YMM5 = [2.0, 2.0, 2.0, 2.0]

    mov     rax, 1                      ; Warto 1 jako cakowita 64-bitowa (qword)
    vmovq   xmm6, rax
    vpbroadcastq ymm6, xmm6             ; YMM6 = [1, 1, 1, 1] (qwords)

    ; ------------------------------------------------------------------------
    ; Inicjalizacja stanu pocztkowego zmiennych iteracyjnych
    ; Z_0 = 0 + 0i dla kadej z 4 prbek
    ; ------------------------------------------------------------------------
    vxorpd  ymm2, ymm2, ymm2            ; YMM2 (zr)    = [0.0, 0.0, 0.0, 0.0]
    vxorpd  ymm3, ymm3, ymm3            ; YMM3 (zi)    = [0.0, 0.0, 0.0, 0.0]
    vpxor   ymm7, ymm7, ymm7            ; YMM7 (iters) = [0, 0, 0, 0] (qwords)

    mov     ecx, r8d                    ; Licznik ptli = maxIterations
    test    ecx, ecx
    jle     @@done_loop

    ; ------------------------------------------------------------------------
    ; Gwna ptla obliczeniowa Mandelbrota dla 4 subpikseli jednoczenie
    ; z_{n+1} = z_n^2 + c
    ; zr_{n+1} = zr^2 - zi^2 + cr
    ; zi_{n+1} = 2 * zr * zi + ci
    ; Warunek stopu: |z|^2 = zr^2 + zi^2 > 4.0
    ; ------------------------------------------------------------------------
@@iter_loop:
    vmulpd  ymm8, ymm2, ymm2            ; YMM8  = zr^2
    vmulpd  ymm9, ymm3, ymm3            ; YMM9  = zi^2
    vaddpd  ymm10, ymm8, ymm9           ; YMM10 = mag2 = zr^2 + zi^2

    ; Porwnanie: mag2 <= 4.0 (_CMP_LE_OQ = 2)
    ; Aktywne linie otrzymuj mask 0xFFFFFFFFFFFFFFFF, nieaktywne 0
    vcmppd  ymm11, ymm10, ymm4, 2       ; YMM11 = maska aktywnoci subpikseli
    vmovmskpd eax, ymm11                ; EAX = 4-bitowa maska obecnoci
    test    eax, eax
    jz      @@done_loop                 ; Jeli wszystkie 4 subpiksele ucieky -> wczesne wyjcie

    ; Inkrementacja licznikw iteracji tylko dla subpikseli, ktre jeszcze nie ucieky
    vpand   ymm12, ymm11, ymm6          ; YMM12 = (maska & 1) w kadej 64-bitowej linii
    vpaddq  ymm7, ymm7, ymm12           ; iters += (maska & 1)

    ; zi_{n+1} = 2.0 * zr * zi + ci
    vmulpd  ymm3, ymm3, ymm2            ; zi * zr
    vmulpd  ymm3, ymm3, ymm5            ; 2.0 * (zi * zr)
    vaddpd  ymm3, ymm3, ymm1            ; 2.0 * zr * zi + ci

    ; zr_{n+1} = zr^2 - zi^2 + cr
    vsubpd  ymm2, ymm8, ymm9            ; zr^2 - zi^2
    vaddpd  ymm2, ymm2, ymm0            ; zr^2 - zi^2 + cr

    dec     ecx
    jnz     @@iter_loop

@@done_loop:
    ; ------------------------------------------------------------------------
    ; Spakowanie 4 licznikw qword (64-bit) z YMM7 do 4 dwordw (32-bit) w XMM0
    ; YMM7 dolne 128 bitw: [iter0 (64b), iter1 (64b)]
    ; YMM7 grne 128 bitw: [iter2 (64b), iter3 (64b)]
    ; ------------------------------------------------------------------------
    vmovdqa xmm0, xmm7
    vextracti128 xmm1, ymm7, 1
    vshufps xmm0, xmm0, xmm1, 88h       ; XMM0 = [iter0, iter1, iter2, iter3] (32-bit dwords)

    ; Wyzerowanie prbek, ktre osigny maxIterations (punkty wewntrz zbioru = czarne)
    vmovd   xmm1, r8d                   ; maxIterations
    vpbroadcastd xmm1, xmm1
    vpcmpgtd xmm2, xmm1, xmm0           ; XMM2 = (maxIterations > iter) ? 0xFFFFFFFF : 0
    vpand   xmm0, xmm0, xmm2            ; Subpiksele w zbiorze otrzymuj iter = 0

    ; ------------------------------------------------------------------------
    ; Wektorowe wyznaczanie skadowych barwnych (B, G, R) dla kadej z 4 prbek
    ; Wzory palety cakowitoliczbowej (identyczne z implementacj referencyjn):
    ;   B_k = (iter_k * 14) & 0xFF
    ;   G_k = (iter_k *  6) & 0xFF
    ;   R_k = (iter_k *  3) & 0xFF
    ; ------------------------------------------------------------------------
    mov     eax, 255
    vmovd   xmm2, eax
    vpbroadcastd xmm2, xmm2             ; XMM2 = maska 0x000000FF w kadej linii

    ; Obliczenie kanau niebieskiego (B):
    mov     eax, 14
    vmovd   xmm3, eax
    vpbroadcastd xmm3, xmm3
    vpmulld xmm4, xmm0, xmm3            ; iters * 14
    vpand   xmm4, xmm4, xmm2            ; XMM4 = [B0, B1, B2, B3]

    ; Obliczenie kanau zielonego (G):
    mov     eax, 6
    vmovd   xmm3, eax
    vpbroadcastd xmm3, xmm3
    vpmulld xmm5, xmm0, xmm3            ; iters * 6
    vpand   xmm5, xmm5, xmm2            ; XMM5 = [G0, G1, G2, G3]

    ; Obliczenie kanau czerwonego (R):
    mov     eax, 3
    vmovd   xmm3, eax
    vpbroadcastd xmm3, xmm3
    vpmulld xmm6, xmm0, xmm3            ; iters * 3
    vpand   xmm6, xmm6, xmm2            ; XMM6 = [R0, R1, R2, R3]

    ; ------------------------------------------------------------------------
    ; Urednianie 4 prbek antyaliasingu (SSAA 2x2):
    ; Sumowanie horyzontalne z uyciem VPHADDD (Avoid PINSRB / PEXTRB)
    ; ------------------------------------------------------------------------
    vphaddd xmm4, xmm4, xmm5            ; XMM4 = [B0+B1, B2+B3, G0+G1, G2+G3]
    vpxor   xmm1, xmm1, xmm1
    vphaddd xmm6, xmm6, xmm1            ; XMM6 = [R0+R1, R2+R3, 0, 0]
    vphaddd xmm4, xmm4, xmm6            ; XMM4 = [bSum, gSum, rSum, 0]

    ; Podzia sum przez 4 (przesunicie bitowe w prawo o 2 pozycje):
    vpsrld  xmm4, xmm4, 2               ; XMM4 = [bAvg, gAvg, rAvg, 0]

    ; Zoenie docelowego piksela BGRA (32-bit):
    ; Bajt 0: Blue, Bajt 1: Green, Bajt 2: Red, Bajt 3: Alpha (0xFF)
    vmovd   eax, xmm4                   ; EAX = bAvg
    vpextrd ecx, xmm4, 1                ; ECX = gAvg
    vpextrd edx, xmm4, 2                ; EDX = rAvg
    shl     edx, 16                     ; R -> bity 16..23
    shl     ecx, 8                      ; G -> bity 8..15
    or      eax, edx
    or      eax, ecx
    or      eax, 0FF000000h             ; A = 255 -> bity 24..31
    ret
MandelbrotVectorKernel ENDP


; ============================================================================
; Eksportowana funkcja gwna: RenderFractalFragment
;
; Sygnatura C/C++:
; void RenderFractalFragment(
;     uint8_t* pPixelBuffer,        // RCX
;     int width,                    // RDX
;     int height,                   // R8
;     int startRow,                 // R9
;     int endRow,                   // [RBP + 48]  (na stosie)
;     double xMin,                  // [RBP + 56]  (na stosie)
;     double xMax,                  // [RBP + 64]  (na stosie)
;     double yMin,                  // [RBP + 72]  (na stosie)
;     double yMax,                  // [RBP + 80]  (na stosie)
;     int maxIterations             // [RBP + 88]  (na stosie)
; );
;
; Konwencja wywoania: Microsoft x64 Calling Convention
; - Rejestry nieulotne (RBX, RBP, RDI, RSI, R12-R15, XMM6-XMM15) s w peni
;   zachowywane i przywracane zgodnie ze specyfikacj Windows ABI.
; - Wyrwnanie stosu RSP do 16 bajtw zachowane w kadym momencie.
; - Zaawansowane adresowanie pamici bufora: [base + index*scale].
; ============================================================================
PUBLIC RenderFractalFragment
PUBLIC MandelbrotVectorKernel

RenderFractalFragment PROC
    ; ------------------------------------------------------------------------
    ; Prolog: Ustanowienie ramki stosu
    ; ------------------------------------------------------------------------
    push    rbp
    mov     rbp, rsp

    ; Zapis rejestrw nieulotnych oglnego przeznaczenia (GPR)
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15

    ; Alokacja pamici na zmienne lokalne, shadow space (32B) oraz rejestry XMM.
    ; Pchnito 8 rejestrw 64-bitowych (64 bajty).
    ; Na wejciu RSP % 16 == 8, wic po 8 pushach RSP % 16 == 8.
    ; Odejmujemy 216 bajtw: (8 - 216) = -208 = -13 * 16 (idealnie podzielne przez 16).
    sub     rsp, 216

    ; Zapis rejestrw nieulotnych XMM (XMM6-XMM15)
    vmovdqu xmmword ptr [rsp + 48],  xmm6
    vmovdqu xmmword ptr [rsp + 64],  xmm7
    vmovdqu xmmword ptr [rsp + 80],  xmm8
    vmovdqu xmmword ptr [rsp + 96],  xmm9
    vmovdqu xmmword ptr [rsp + 112], xmm10
    vmovdqu xmmword ptr [rsp + 128], xmm11
    vmovdqu xmmword ptr [rsp + 144], xmm12
    vmovdqu xmmword ptr [rsp + 160], xmm13
    vmovdqu xmmword ptr [rsp + 176], xmm14
    vmovdqu xmmword ptr [rsp + 192], xmm15

    ; Kopiowanie argumentw z rejestrw do bezpiecznych rejestrw nieulotnych:
    mov     r12, rcx                    ; R12  = pPixelBuffer
    mov     r13d, edx                   ; R13D = width
    mov     r14d, r8d                   ; R14D = height
    mov     r15d, r9d                   ; R15D = startRow

    ; Pobranie argumentw ze stosu wywoujcego:
    mov     esi, dword ptr [rbp + 48]   ; ESI  = endRow
    mov     edi, dword ptr [rbp + 88]   ; EDI  = maxIterations

    ; Walidacja poprawnoci parametrw wejciowych
    cmp     r15d, esi
    jge     @@cleanup_exit
    test    r13d, r13d
    jle     @@cleanup_exit
    test    r14d, r14d
    jle     @@cleanup_exit

    ; ------------------------------------------------------------------------
    ; Wyznaczenie kroku osi rzeczywistej: dx = (xMax - xMin) / width
    ; ------------------------------------------------------------------------
    vmovsd  xmm0, real8 ptr [rbp + 64]   ; xMax
    vsubsd  xmm0, xmm0, real8 ptr [rbp + 56] ; xMax - xMin
    vcvtsi2sd xmm1, xmm1, r13d           ; (double)width
    vdivsd  xmm0, xmm0, xmm1             ; dx
    vmovsd  real8 ptr [rsp + 32], xmm0   ; [rsp + 32] = dx

    ; ------------------------------------------------------------------------
    ; Wyznaczenie kroku osi urojonej: dy = (yMax - yMin) / height
    ; ------------------------------------------------------------------------
    vmovsd  xmm2, real8 ptr [rbp + 80]   ; yMax
    vsubsd  xmm2, xmm2, real8 ptr [rbp + 72] ; yMax - yMin
    vcvtsi2sd xmm3, xmm3, r14d           ; (double)height
    vdivsd  xmm2, xmm2, xmm3             ; dy
    vmovsd  real8 ptr [rsp + 40], xmm2   ; [rsp + 40] = dy

    ; Stae uamkowe przesuni subpikselowych SSAA 2x2:
    ; 0.25 (3FD0000000000000h) oraz 0.75 (3FE8000000000000h)
    mov     rax, 3FD0000000000000h
    vmovq   xmm14, rax                   ; XMM14 = 0.25
    mov     rax, 3FE8000000000000h
    vmovq   xmm15, rax                   ; XMM15 = 0.75

    ; ------------------------------------------------------------------------
    ; Ptla po wierszach przydzielonych biecemu wtkowi: y = startRow .. endRow - 1
    ; ------------------------------------------------------------------------
    mov     ebx, r15d                    ; EBX = y

@@row_loop:
    cmp     ebx, esi
    jge     @@cleanup_exit

    ; yBase = yMin + y * dy
    vcvtsi2sd xmm0, xmm0, ebx
    vmulsd  xmm0, xmm0, real8 ptr [rsp + 40] ; y * dy
    vaddsd  xmm0, xmm0, real8 ptr [rbp + 72] ; yBase = yMin + y * dy

    ; Wsprzdne urojone subpikseli:
    ; ci0 = yBase + 0.25 * dy
    vmovsd  xmm1, real8 ptr [rsp + 40]
    vmulsd  xmm2, xmm1, xmm14            ; 0.25 * dy
    vaddsd  xmm2, xmm2, xmm0             ; ci0

    ; ci1 = yBase + 0.75 * dy
    vmulsd  xmm3, xmm1, xmm15            ; 0.75 * dy
    vaddsd  xmm3, xmm3, xmm0             ; ci1

    ; Spakowanie wektora YMM13 = [ci0, ci0, ci1, ci1] (stay dla caego wiersza)
    vunpcklpd xmm1, xmm2, xmm2           ; [ci0, ci0]
    vunpcklpd xmm2, xmm3, xmm3           ; [ci1, ci1]
    vinsertf128 ymm13, ymm1, xmm2, 1     ; YMM13 = [ci0, ci0, ci1, ci1]

    ; Wyznaczenie wskanika do pocztku biecego wiersza w buforze:
    ; offset = y * (width * 4)
    movsxd  rax, ebx
    imul    rax, r13                     ; y * width
    shl     rax, 2                       ; * 4 bajty na piksel
    lea     r10, [r12 + rax]             ; R10 = pocztek wiersza w pPixelBuffer

    ; ------------------------------------------------------------------------
    ; Ptla po kolumnach: x = 0 .. width - 1
    ; ------------------------------------------------------------------------
    xor     r11d, r11d                   ; R11D = x

@@col_loop:
    cmp     r11d, r13d
    jge     @@next_row

    ; xBase = xMin + x * dx
    vcvtsi2sd xmm0, xmm0, r11d
    vmulsd  xmm0, xmm0, real8 ptr [rsp + 32] ; x * dx
    vaddsd  xmm0, xmm0, real8 ptr [rbp + 56] ; xBase = xMin + x * dx

    ; Wsprzdne rzeczywiste subpikseli:
    ; cr0 = xBase + 0.25 * dx
    vmovsd  xmm1, real8 ptr [rsp + 32]
    vmulsd  xmm2, xmm1, xmm14            ; 0.25 * dx
    vaddsd  xmm2, xmm2, xmm0             ; cr0

    ; cr1 = xBase + 0.75 * dx
    vmulsd  xmm3, xmm1, xmm15            ; 0.75 * dx
    vaddsd  xmm3, xmm3, xmm0             ; cr1

    ; Spakowanie wektora YMM0 = [cr0, cr1, cr0, cr1]
    vunpcklpd xmm0, xmm2, xmm3           ; [cr0, cr1]
    vinsertf128 ymm0, ymm0, xmm0, 1      ; YMM0 = [cr0, cr1, cr0, cr1]

    ; Przygotowanie rejestrw wejciowych do wywoania jdra wektorowego
    vmovdqa ymm1, ymm13                  ; YMM1 = ci [ci0, ci0, ci1, ci1]
    mov     r8d, edi                     ; R8D  = maxIterations

    call    MandelbrotVectorKernel       ; Zwraca 32-bitowy piksel BGRA w EAX

    ; Zapis piksela do bufora przy uyciu zaawansowanego adresowania [base + index*scale]
    mov     dword ptr [r10 + r11*4], eax

    inc     r11d
    jmp     @@col_loop

@@next_row:
    inc     ebx
    jmp     @@row_loop

    ; ------------------------------------------------------------------------
    ; Epilog: Przywrcenie rejestrw i oczyszczenie ramki stosu
    ; ------------------------------------------------------------------------
@@cleanup_exit:
    ; Przywrcenie rejestrw nieulotnych XMM (XMM6-XMM15)
    vmovdqu xmm6,  xmmword ptr [rsp + 48]
    vmovdqu xmm7,  xmmword ptr [rsp + 64]
    vmovdqu xmm8,  xmmword ptr [rsp + 80]
    vmovdqu xmm9,  xmmword ptr [rsp + 96]
    vmovdqu xmm10, xmmword ptr [rsp + 112]
    vmovdqu xmm11, xmmword ptr [rsp + 128]
    vmovdqu xmm12, xmmword ptr [rsp + 144]
    vmovdqu xmm13, xmmword ptr [rsp + 160]
    vmovdqu xmm14, xmmword ptr [rsp + 176]
    vmovdqu xmm15, xmmword ptr [rsp + 192]

    add     rsp, 216

    ; Wyzerowanie grnych powek rejestrw YMM w celu uniknicia kar przejcia AVX-SSE
    vzeroupper

    ; Przywrcenie rejestrw nieulotnych GPR
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret
RenderFractalFragment ENDP

END
