// ============================================================================
// Projekt: Generator Zbioru Mandelbrota z antyaliasingiem SSAA 2x2
// Plik:    MandelbrotHighLevel.cpp
// Modu:   Wysokopoziomowa biblioteka referencyjna C++ (x64)
//
// Architektura: x64
// Zgodno z ABI: CDECL / STDCALL (Windows x64 Calling Convention)
// ============================================================================

#include <cstdint>
#include <cstddef>

extern "C" {

/**
 * Eksportowana funkcja renderujca przydzielony fragment fraktala.
 * 
 * @param pPixelBuffer    Wskanik do bezporedniego bufora pikseli w formacie BGRA32 (4 bajty na piksel).
 * @param width           Cakowita szeroko obrazu w pikselach.
 * @param height          Cakowita wysoko obrazu w pikselach.
 * @param startRow        Pocztkowy wiersz przydzielony biecemu wtkowi (wcznie).
 * @param endRow          Kocowy wiersz przydzielony biecemu wtkowi (wycznie).
 * @param xMin            Dolna granica osi rzeczywistej paszczyzny zespolonej.
 * @param xMax            Grna granica osi rzeczywistej paszczyzny zespolonej.
 * @param yMin            Dolna granica osi urojonej paszczyzny zespolonej.
 * @param yMax            Grna granica osi urojonej paszczyzny zespolonej.
 * @param maxIterations   Maksymalna liczba iteracji algorytmu ucieczki.
 */
__declspec(dllexport) void RenderFractalFragment(
    uint8_t* pPixelBuffer,
    int width,
    int height,
    int startRow,
    int endRow,
    double xMin,
    double xMax,
    double yMin,
    double yMax,
    int maxIterations
)
{
    // Walidacja poprawnoci danych wejciowych
    if (!pPixelBuffer || width <= 0 || height <= 0 || startRow >= endRow || maxIterations <= 0)
    {
        return;
    }

    // Wyznaczenie krokw dyskretyzacji paszczyzny zespolonej
    const double dx = (xMax - xMin) / static_cast<double>(width);
    const double dy = (yMax - yMin) / static_cast<double>(height);
    const size_t stride = static_cast<size_t>(width) * 4;

    // Przetwarzanie wierszy przydzielonych wtkowi
    for (int y = startRow; y < endRow; ++y)
    {
        uint8_t* pRow = pPixelBuffer + static_cast<size_t>(y) * stride;
        const double yBase = yMin + static_cast<double>(y) * dy;

        // Subpiksele osi urojonej dla SSAA 2x2 (przesunicia +0.25 oraz +0.75):
        const double ci[2] = {
            yBase + 0.25 * dy,
            yBase + 0.75 * dy
        };

        for (int x = 0; x < width; ++x)
        {
            const double xBase = xMin + static_cast<double>(x) * dx;

            // Subpiksele osi rzeczywistej dla SSAA 2x2:
            const double cr[2] = {
                xBase + 0.25 * dx,
                xBase + 0.75 * dx
            };

            // 4 prbki SSAA 2x2 rozmieszczone wewntrz piksela:
            // Subpiksel 0: (cr[0], ci[0])
            // Subpiksel 1: (cr[1], ci[0])
            // Subpiksel 2: (cr[0], ci[1])
            // Subpiksel 3: (cr[1], ci[1])
            const double sampleCr[4] = { cr[0], cr[1], cr[0], cr[1] };
            const double sampleCi[4] = { ci[0], ci[0], ci[1], ci[1] };

            int bSum = 0;
            int gSum = 0;
            int rSum = 0;

            // Obliczenie iteracji ucieczki dla kadej z 4 prbek
            for (int s = 0; s < 4; ++s)
            {
                const double c_re = sampleCr[s];
                const double c_im = sampleCi[s];

                double zr = 0.0;
                double zi = 0.0;
                int iter = 0;

                // Ptla algorytmu Mandelbrota: Z_{n+1} = Z_n^2 + C
                while (iter < maxIterations)
                {
                    const double zr2 = zr * zr;
                    const double zi2 = zi * zi;

                    // Warunek stopu: |Z|^2 > 4.0
                    if (zr2 + zi2 > 4.0)
                    {
                        break;
                    }

                    zi = 2.0 * zr * zi + c_im;
                    zr = zr2 - zi2 + c_re;
                    ++iter;
                }

                // Deterministyczna paleta cakowitoliczbowa (identyczna jak w module ASM):
                // Jeli punkt nie uciek (iter == maxIterations), kolor wynosi (0, 0, 0)
                if (iter < maxIterations)
                {
                    bSum += (iter * 14) & 0xFF;
                    gSum += (iter *  6) & 0xFF;
                    rSum += (iter *  3) & 0xFF;
                }
            }

            // Urednienie 4 prbek SSAA (podzia sumy przez 4 za pomoc bitshiftu >> 2)
            const uint8_t bAvg = static_cast<uint8_t>(bSum >> 2);
            const uint8_t gAvg = static_cast<uint8_t>(gSum >> 2);
            const uint8_t rAvg = static_cast<uint8_t>(rSum >> 2);
            const uint8_t aVal = 255; // Pene krycie Alpha (0xFF)

            // Bezporedni zapis piksela 32-bit BGRA do bufora
            uint32_t* pPixel = reinterpret_cast<uint32_t*>(pRow + static_cast<size_t>(x) * 4);
            *pPixel = (static_cast<uint32_t>(aVal) << 24) |
                      (static_cast<uint32_t>(rAvg) << 16) |
                      (static_cast<uint32_t>(gAvg) <<  8) |
                      static_cast<uint32_t>(bAvg);
        }
    }
}

} // extern "C"
