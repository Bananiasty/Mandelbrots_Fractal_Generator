# Projekt: Generator Zbioru Mandelbrota z Antyaliasingiem SSAA 2x2 (x64)

Kompletne rozwiązanie w Visual Studio składające się z aplikacji graficznej **WPF (.NET 8 / .NET 10 x64)** oraz dwóch bibliotek DLL realizujących generowanie Zbioru Mandelbrota z 4-krotnym antyaliasingiem **SSAA 2x2**:
1. **MandelbrotHighLevel.dll**: Biblioteka wysokopoziomowa (C++) eksportująca identyczne API w konwencji C.
2. **MandelbrotAsm.dll**: Niskopoziomowa biblioteka w asemblerze x64 (MASM / `ml64.exe`) wykorzystująca instrukcje wektorowe **AVX2 / SSE4.1**.
3. **MandelbrotApp (Fraktal_Mandelbrota)**: Aplikacja WPF w C# z wielowątkowością (chunking wierszy), bezpośrednim zapisem do bufora `WriteableBitmap` (`Scan0`), pomiarem czasu `Stopwatch` (ms / µs) oraz modułem automatycznego benchmarku (1, 2, 4, 8, 16, 32, 64 wątki).

---

## 1. Struktura Rozwiązania

```text
Fraktal_Mandelbrota/
├── Fraktal_Mandelbrota.sln               <- Główny plik rozwiązania Visual Studio (x64)
├── Fraktal_Mandelbrota.slnx              <- Nowy format rozwiązania Visual Studio 2026
├── INSTRUKCJA_I_DOKUMENTACJA.md          <- Niniejsza dokumentacja
│
├── Fraktal_Mandelbrota/                  <- Projekt aplikacji GUI (C# WPF x64)
│   ├── App.xaml / App.xaml.cs
│   ├── MainWindow.xaml                   <- Definicja interfejsu (kontrolki, suwaki, DataGrid)
│   ├── MainWindow.xaml.cs                <- P/Invoke, chunking wierszy, WriteableBitmap, Benchmark
│   ├── BenchmarkResult.cs                <- Model danych tabeli benchmarku
│   └── Fraktal_Mandelbrota.csproj        <- Konfiguracja projektu .NET
│
├── MandelbrotHighLevel/                  <- Projekt biblioteki wysokopoziomowej C++ (x64 DLL)
│   ├── MandelbrotHighLevel.cpp           <- Referencyjny algorytm Mandelbrota i SSAA 2x2
│   ├── MandelbrotHighLevel.def           <- Plik eksportu symboli DLL
│   └── MandelbrotHighLevel.vcxproj       <- Konfiguracja projektu C++ MSBuild
│
└── MandelbrotAsm/                        <- Projekt biblioteki asemblera MASM x64 (x64 DLL)
    ├── MandelbrotAsm.asm                 <- Kod źródłowy MASM x64 (AVX2, RenderFractalFragment, MandelbrotVectorKernel)
    ├── MandelbrotAsm.def                 <- Plik eksportu symboli DLL
    └── MandelbrotAsm.vcxproj             <- Konfiguracja projektu C++ z włączonym MASM Customization
```

---

## 2. Instrukcja Konfiguracji Projektu w Visual Studio

### Krok 1: Otwarcie rozwiązania
1. Uruchom **Visual Studio** (2022 lub 2026).
2. Wybierz *File -> Open -> Project/Solution...* (lub dwuklik na pliku `Fraktal_Mandelbrota.sln` / `Fraktal_Mandelbrota.slnx`).
3. W górnym pasku narzędzi upewnij się, że wybrano:
   - Konfigurację: **Release**
   - Architekturę: **x64**

---

### Krok 2: Włączenie MASM Build Customizations dla projektu Asemblera
*(Projekt `MandelbrotAsm.vcxproj` posiada tę opcję już w pełni skonfigurowaną w pliku projektu, jednak poniżej znajduje się procedura ręczna wymagana w zadaniu):*
1. W oknie **Solution Explorer** kliknij prawym przyciskiem myszy na projekt **`MandelbrotAsm`**.
2. Wybierz **Build Dependencies** -> **Build Customizations...**.
3. Na liście zaznacz pole wyboru **`masm`** (Microsoft Macro Assembler) i kliknij **OK**.
4. Kliknij prawym przyciskiem myszy na plik **`MandelbrotAsm.asm`** -> **Properties**:
   - W sekcji **General**, upewnij się, że **Item Type** ma wartość **Microsoft Macro Assembler**.
5. Właściwości projektu **`MandelbrotAsm`** -> **Linker** -> **Input**:
   - W polu **Module Definition File** wpisano: `MandelbrotAsm.def`.
   - W sekcji **Advanced** -> **No Entry Point**: wybrano **Yes (/NOENTRY)**.

---

### Krok 3: Kompilacja i Uruchomienie
1. Kliknij prawym przyciskiem myszy na rozwiązanie w Solution Explorerze i wybierz **Rebuild Solution** (lub `Ctrl + Shift + B`).
2. Wszystkie 3 projekty skompilują się do architektury `x64`:
   - `x64\Release\MandelbrotHighLevel.dll`
   - `x64\Release\MandelbrotAsm.dll`
   - `Fraktal_Mandelbrota\bin\x64\Release\net...\Fraktal_Mandelbrota.exe`
3. Pliki `.dll` są automatycznie kopiowane do folderu wynikowego aplikacji WPF.
4. Ustaw **`Fraktal_Mandelbrota`** jako projekt startowy (*Set as Startup Project*) i naciśnij **F5** (lub `Ctrl + F5`), aby uruchomić aplikację.

---

## 3. Sygnatura API i Zgodność z Windows x64 ABI

Obie biblioteki DLL eksportują identyczną sygnaturę funkcji:

```c
void RenderFractalFragment(
    uint8_t* pPixelBuffer,        // Format BGRA 32-bit (stride = width * 4 bajty)
    int width,                    // Całkowita szerokość obrazu
    int height,                   // Całkowita wysokość obrazu
    int startRow,                 // Początkowy wiersz przydzielony wątkowi (włącznie)
    int endRow,                   // Końcowy wiersz przydzielony wątkowi (wyłącznie)
    double xMin, double xMax,     // Zakres współrzędnych osi rzeczywistej
    double yMin, double yMax,     // Zakres współrzędnych osi urojonej
    int maxIterations             // Maksymalna liczba iteracji algorytmu
);
```

### Konwencja wywołania (Microsoft x64 Calling Convention):
- **RCX**: `pPixelBuffer` (wskaźnik 64-bitowy)
- **RDX**: `width` (liczba całkowita 32-bit)
- **R8**: `height` (liczba całkowita 32-bit)
- **R9**: `startRow` (liczba całkowita 32-bit)
- **[RBP + 48]**: `endRow` (przekazany na stosie)
- **[RBP + 56]**: `xMin` (double, 64-bit)
- **[RBP + 64]**: `xMax` (double, 64-bit)
- **[RBP + 72]**: `yMin` (double, 64-bit)
- **[RBP + 80]**: `yMax` (double, 64-bit)
- **[RBP + 88]**: `maxIterations` (int, 32-bit)

### Ścisłe zachowanie rejestrów i stosu w `MandelbrotAsm.asm`:
- **Zapis rejestrów nieulotnych GPR**: `RBX`, `RBP`, `RDI`, `RSI`, `R12`, `R13`, `R14`, `R15`.
- **Zapis rejestrów nieulotnych XMM**: `XMM6` do `XMM15` zgodnie ze specyfikacją ABI platformy Windows x64.
- **Wyrównanie stosu**: Stos `RSP` jest ściśle wyrównany do granicy 16 bajtów przed każdym wywołaniem wewnętrznej procedury `call MandelbrotVectorKernel`.
- **Cień stosu (Shadow Space)**: 32 bajty zarezerwowane na stosie wywołania.
- **Brak zmiennych globalnych**: Wszelkie stałe matematyczne (`4.0`, `2.0`, `1`, `0.25`, `0.75`) są generowane w rejestrach w locie lub pobierane z ramki stosu.
- **Instrukcja `vzeroupper`**: Wywoływana przed powrotem z procedury w celu wyeliminowania kar wydajnościowych przy przejściach pomiędzy kodem AVX i SSE.

---

## 4. Algorytm i Antyaliasing SSAA 2x2

Dla każdego piksela $(x, y)$ o wymiarach $1 \times 1$:
1. Pobierane są 4 próbki subpikselowe rozmieszczone symetrycznie w pozycjach:
   - Subpiksel 0: $(x + 0.25, y + 0.25)$
   - Subpiksel 1: $(x + 0.75, y + 0.25)$
   - Subpiksel 2: $(x + 0.25, y + 0.75)$
   - Subpiksel 3: $(x + 0.75, y + 0.75)$
2. Dla każdej próbki obliczana jest ucieczka ze zbioru Mandelbrota:
   $$z_0 = 0, \quad z_{n+1} = z_n^2 + c$$
   warunek stopu: $|z_n|^2 > 4.0$ lub $n = \text{maxIterations}$.
3. W bibliotece `MandelbrotAsm.asm` rejestry 256-bitowe **AVX2 (YMM)** mieszczą jednocześnie **dokładnie 4 liczby `double`** (4 subpiksele):
   - `YMM0 = [cr0, cr1, cr0, cr1]`
   - `YMM1 = [ci0, ci0, ci1, ci1]`
   Dzięki temu wszystkie 4 próbki SSAA danego piksela są liczone równolegle w jednym cyklu wektorowym!
4. Po zakończeniu obliczeń składowe barwne $(B, G, R)$ 4 próbek są sumowane wektorowo (`vphaddd`) i dzielone przez 4 (`vpsrld xmm, 2`):
   $$B = \frac{B_0 + B_1 + B_2 + B_3}{4}, \quad G = \frac{G_0 + G_1 + G_2 + G_3}{4}, \quad R = \frac{R_0 + R_1 + R_2 + R_3}{4}, \quad A = 255$$
5. Mapowanie iteracji na kolory jest w 100% deterministyczne, całkowitoliczbowe i daje **identyczny wynik binarny** (co do jednego bitu) w obu bibliotekach!

---

## 5. Wielowątkowość i Moduł Benchmarku

- **Chunking wierszy**: Wysokość obrazu jest dzielona równomiernie na zadaną liczbę wątków ($1 \le N \le 64$). Każdy wątek otrzymuje rozłączny przedział wierszy $[startRow, endRow)$ i zapisuje piksele bezpośrednio do wydzielonego fragmentu pamięci `WriteableBitmap` (`Scan0`).
- **Brak wyścigów (Lock-free)**: Wątki nie dzielą wspólnych zmiennych modyfikowalnych.
- **Pomiary `Stopwatch`**:
  - Pomiar w mikrosekundach ($\mu\text{s}$) i milisekundach ($\text{ms}$).
  - Moduł benchmarku automatycznie bada konfiguracje wątków: **1, 2, 4, 8, 16, 32, 64** dla biblioteki ASM x64 oraz biblioteki C++.
  - Każda konfiguracja poprzedzona jest fazą rozgrzania (warm-up), po czym wykonywane jest 5 niezależnych prób, z których wyciągana jest średnia arytmetyczna oraz wyznaczany współczynnik przyśpieszenia (*Speedup*).
  - Wyniki można jednym kliknięciem skopiować do schowka w formacie CSV.
