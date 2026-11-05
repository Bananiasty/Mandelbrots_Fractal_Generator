using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Fraktal_Mandelbrota
{
    public partial class MainWindow : Window
    {
        // ====================================================================
        // IMPORT BIBLIOTEKI ASEMBLERA (P/INVOKE)
        // Sygnatura x64: fastcall / cdecl
        // ====================================================================

        [DllImport("MandelbrotAsm.dll", EntryPoint = "RenderFractalFragment", CallingConvention = CallingConvention.Cdecl)]
        private static extern void RenderFractalFragmentAsm(
            IntPtr pPixelBuffer,
            int width,
            int height,
            int startRow,
            int endRow,
            double xMin,
            double xMax,
            double yMin,
            double yMax,
            int maxIterations
        );

        // Typ delegata dla jednolitego wywoływania obu silników (C# i ASM)
        private delegate void RenderFragmentDelegate(
            IntPtr pPixelBuffer,
            int width,
            int height,
            int startRow,
            int endRow,
            double xMin,
            double xMax,
            double yMin,
            double yMax,
            int maxIterations
        );

        // ====================================================================
        // SILNIK WYSOKOPOZIOMOWY: C# (.NET)
        // Matematycznie i binarnie tożsamy z modułem w Asemblerze AVX2
        // ====================================================================
        private static unsafe void RenderFractalFragmentCSharp(
            IntPtr pPixelBuffer,
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
            if (pPixelBuffer == IntPtr.Zero || width <= 0 || height <= 0 || startRow >= endRow || maxIterations <= 0)
                return;

            byte* pBase = (byte*)pPixelBuffer.ToPointer();
            double dx = (xMax - xMin) / (double)width;
            double dy = (yMax - yMin) / (double)height;
            long stride = (long)width * 4;

            for (int y = startRow; y < endRow; ++y)
            {
                byte* pRow = pBase + (long)y * stride;
                double yBase = yMin + (double)y * dy;

                // 2 pozycje osi urojonej dla SSAA 2x2:
                double ci0 = yBase + 0.25 * dy;
                double ci1 = yBase + 0.75 * dy;

                for (int x = 0; x < width; ++x)
                {
                    double xBase = xMin + (double)x * dx;

                    // 2 pozycje osi rzeczywistej dla SSAA 2x2:
                    double cr0 = xBase + 0.25 * dx;
                    double cr1 = xBase + 0.75 * dx;

                    int bSum = 0;
                    int gSum = 0;
                    int rSum = 0;

                    // 4 próbki subpikseli SSAA 2x2:
                    // Próbka 0: (cr0, ci0)
                    // Próbka 1: (cr1, ci0)
                    // Próbka 2: (cr0, ci1)
                    // Próbka 3: (cr1, ci1)
                    for (int s = 0; s < 4; ++s)
                    {
                        double cre = (s & 1) == 0 ? cr0 : cr1;
                        double cim = (s < 2) ? ci0 : ci1;

                        double zr = 0.0;
                        double zi = 0.0;
                        int iter = 0;

                        while (iter < maxIterations)
                        {
                            double zr2 = zr * zr;
                            double zi2 = zi * zi;
                            if (zr2 + zi2 > 4.0)
                                break;

                            zi = 2.0 * zr * zi + cim;
                            zr = zr2 - zi2 + cre;
                            ++iter;
                        }

                        // Deterministyczna paleta całkowitoliczbowa:
                        if (iter < maxIterations)
                        {
                            bSum += (iter * 14) & 0xFF;
                            gSum += (iter *  6) & 0xFF;
                            rSum += (iter *  3) & 0xFF;
                        }
                    }

                    // Uśrednienie 4 próbek SSAA:
                    byte bAvg = (byte)(bSum >> 2);
                    byte gAvg = (byte)(gSum >> 2);
                    byte rAvg = (byte)(rSum >> 2);
                    byte aVal = 255;

                    uint* pPixel = (uint*)(pRow + (long)x * 4);
                    *pPixel = ((uint)aVal << 24) | ((uint)rAvg << 16) | ((uint)gAvg << 8) | (uint)bAvg;
                }
            }
        }

        // ====================================================================
        // STAN APLIKACJI
        // ====================================================================

        private enum EngineType
        {
            AsmDll,
            CSharp
        }

        private EngineType _currentEngine = EngineType.AsmDll;
        private WriteableBitmap? _bitmap;

        // Stała rozdzielczość obrazu
        private const int ImageWidth = 1280;
        private const int ImageHeight = 720;

        private int _threadCount = 8;
        private int _maxIterations = 100;

        // Domyślne współrzędne kadru
        private const double DefaultXMin = -2.0;
        private const double DefaultXMax = 1.0;
        private const double DefaultYMin = -1.2;
        private const double DefaultYMax = 1.2;

        private double _xMin = DefaultXMin;
        private double _xMax = DefaultXMax;
        private double _yMin = DefaultYMin;
        private double _yMax = DefaultYMax;

        private bool _isRendering = false;
        private readonly ObservableCollection<BenchmarkResult> _benchmarkResults = new();
        private static bool _resolverConfigured = false;

        // ====================================================================
        // INICJALIZACJA
        // ====================================================================

        public MainWindow()
        {
            ConfigureDllResolver();
            InitializeComponent();
        }

        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
            // Domyślne wykrywanie liczby wątków logicznych procesora (Environment.ProcessorCount)
            int logicalCores = Environment.ProcessorCount;
            if (txtCpuLogicalCores != null)
                txtCpuLogicalCores.Text = $"Wykryte wątki CPU: {logicalCores} logicznych rdzeni";

            _threadCount = Math.Clamp(logicalCores, 1, 64);
            if (slThreads != null)
                slThreads.Value = _threadCount;
            if (txtThreadCount != null)
                txtThreadCount.Text = _threadCount.ToString();

            if (dgBenchmark != null)
                dgBenchmark.ItemsSource = _benchmarkResults;

            UpdateCoordinatesDisplay();
            InitBitmap();

            // Pierwsze renderowanie przy starcie
            _ = RenderFractalAsync();
        }

        private static void ConfigureDllResolver()
        {
            if (_resolverConfigured)
                return;

            try
            {
                NativeLibrary.SetDllImportResolver(typeof(MainWindow).Assembly, (libraryName, assembly, searchPath) =>
                {
                    string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                    string fileName = libraryName.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? libraryName : libraryName + ".dll";

                    string[] candidateDirs = new[]
                    {
                        baseDir,
                        Path.Combine(baseDir, "..", "..", "..", "..", "x64", "Release"),
                        Path.Combine(baseDir, "..", "..", "..", "..", "x64", "Debug"),
                        Path.Combine(baseDir, "..", "..", "..", "..", "MandelbrotAsm", "x64", "Release"),
                        Path.Combine(baseDir, "..", "..", "x64", "Release"),
                        Path.Combine(baseDir, "..", "..", "x64", "Debug")
                    };

                    foreach (var dir in candidateDirs)
                    {
                        try
                        {
                            string fullPath = Path.GetFullPath(Path.Combine(dir, fileName));
                            if (File.Exists(fullPath))
                            {
                                if (NativeLibrary.TryLoad(fullPath, out IntPtr handle))
                                    return handle;
                            }
                        }
                        catch { }
                    }

                    return IntPtr.Zero;
                });
                _resolverConfigured = true;
            }
            catch { }
        }

        private void InitBitmap()
        {
            if (imgFractal == null)
                return;

            _bitmap = new WriteableBitmap(ImageWidth, ImageHeight, 96, 96, PixelFormats.Bgr32, null);
            imgFractal.Source = _bitmap;
        }

        private void UpdateCoordinatesDisplay()
        {
            if (txtCoordsInfo != null)
                txtCoordsInfo.Text = $"Re: [{_xMin:F4}, {_xMax:F4}]\nIm: [{_yMin:F4}, {_yMax:F4}]";
        }

        // ====================================================================
        // WIELOWĄTKOWE GENEROWANIE FRAKTALA
        // ====================================================================

        private RenderFragmentDelegate GetSelectedRenderDelegate()
        {
            return _currentEngine == EngineType.AsmDll ? RenderFractalFragmentAsm : RenderFractalFragmentCSharp;
        }

        private async Task<(double ms, double us)> RenderFractalAsync(int? customThreads = null, RenderFragmentDelegate? customDelegate = null)
        {
            if (_bitmap == null)
                InitBitmap();

            if (_bitmap == null)
                return (0, 0);

            int threads = customThreads ?? _threadCount;
            RenderFragmentDelegate renderFunc = customDelegate ?? GetSelectedRenderDelegate();

            _isRendering = true;
            if (btnRender != null)
                btnRender.IsEnabled = false;
            if (txtStatus != null)
                txtStatus.Text = $"Renderowanie: {threads} wątków, silnik: {_currentEngine}...";

            int width = ImageWidth;
            int height = ImageHeight;
            double xMin = _xMin;
            double xMax = _xMax;
            double yMin = _yMin;
            double yMax = _yMax;
            int maxIter = _maxIterations;

            _bitmap.Lock();
            IntPtr pBuffer = _bitmap.BackBuffer;

            Stopwatch sw = Stopwatch.StartNew();

            await Task.Run(() =>
            {
                int rowsPerThread = height / threads;
                int remainder = height % threads;

                Task[] tasks = new Task[threads];
                int currentRow = 0;

                for (int t = 0; t < threads; t++)
                {
                    int startRow = currentRow;
                    int count = rowsPerThread + (t < remainder ? 1 : 0);
                    int endRow = startRow + count;
                    currentRow = endRow;

                    if (startRow >= endRow)
                    {
                        tasks[t] = Task.CompletedTask;
                        continue;
                    }

                    tasks[t] = Task.Run(() =>
                    {
                        renderFunc(
                            pBuffer,
                            width,
                            height,
                            startRow,
                            endRow,
                            xMin,
                            xMax,
                            yMin,
                            yMax,
                            maxIter
                        );
                    });
                }

                Task.WaitAll(tasks);
            });

            sw.Stop();

            _bitmap.AddDirtyRect(new Int32Rect(0, 0, width, height));
            _bitmap.Unlock();

            double microseconds = (sw.ElapsedTicks * 1_000_000.0) / Stopwatch.Frequency;
            double milliseconds = microseconds / 1000.0;

            if (txtLastTime != null)
                txtLastTime.Text = $"{milliseconds:F2} ms";
            if (txtLastTimeUs != null)
                txtLastTimeUs.Text = $"{microseconds:F0} µs";
            if (txtStatus != null)
                txtStatus.Text = $"Gotowe. Czas: {milliseconds:F2} ms ({microseconds:F0} µs)";

            _isRendering = false;
            if (btnRender != null)
                btnRender.IsEnabled = true;

            return (milliseconds, microseconds);
        }

        // ====================================================================
        // MODUŁ BENCHMARKU WYDAJNOŚCI (C# vs ASM)
        // ====================================================================

        private async void BtnBenchmark_Click(object sender, RoutedEventArgs e)
        {
            if (_isRendering)
                return;

            if (btnBenchmark != null)
                btnBenchmark.IsEnabled = false;
            if (btnRender != null)
                btnRender.IsEnabled = false;
            if (pbProgress != null)
            {
                pbProgress.Visibility = Visibility.Visible;
                pbProgress.Value = 0;
            }

            _benchmarkResults.Clear();

            int[] threadCounts = new[] { 1, 2, 4, 8, 16, 32, 64 };
            int totalSteps = threadCounts.Length;
            int currentStep = 0;
            const int repetitions = 5;

            try
            {
                foreach (int tc in threadCounts)
                {
                    if (txtStatus != null)
                        txtStatus.Text = $"Benchmark {tc} wątków: test C#...";

                    // 1. Pomiar dla C# (warm-up + 5 prób)
                    await RenderFractalAsync(tc, RenderFractalFragmentCSharp);
                    double sumCs = 0;
                    for (int rep = 0; rep < repetitions; rep++)
                    {
                        var (ms, _) = await RenderFractalAsync(tc, RenderFractalFragmentCSharp);
                        sumCs += ms;
                    }
                    double avgCs = sumCs / repetitions;

                    if (txtStatus != null)
                        txtStatus.Text = $"Benchmark {tc} wątków: test ASM AVX2...";

                    // 2. Pomiar dla Asemblera AVX2 (warm-up + 5 prób)
                    await RenderFractalAsync(tc, RenderFractalFragmentAsm);
                    double sumAsm = 0;
                    for (int rep = 0; rep < repetitions; rep++)
                    {
                        var (ms, _) = await RenderFractalAsync(tc, RenderFractalFragmentAsm);
                        sumAsm += ms;
                    }
                    double avgAsm = sumAsm / repetitions;

                    // 3. Obliczenie przyśpieszenia ASM względem C#
                    double speedup = (avgAsm > 0) ? (avgCs / avgAsm) : 1.0;

                    _benchmarkResults.Add(new BenchmarkResult
                    {
                        Threads = tc,
                        TimeCsMs = avgCs,
                        TimeAsmMs = avgAsm,
                        SpeedupAsmVsCs = speedup
                    });

                    currentStep++;
                    if (pbProgress != null)
                        pbProgress.Value = (currentStep * 100.0) / totalSteps;
                }

                if (txtStatus != null)
                    txtStatus.Text = "Benchmark zakończony pomyślnie!";
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Błąd podczas wykonywania benchmarku: {ex.Message}", "Błąd", MessageBoxButton.OK, MessageBoxImage.Error);
                if (txtStatus != null)
                    txtStatus.Text = "Wystąpił błąd w trakcie benchmarku.";
            }
            finally
            {
                if (pbProgress != null)
                    pbProgress.Visibility = Visibility.Collapsed;
                if (btnBenchmark != null)
                    btnBenchmark.IsEnabled = true;
                if (btnRender != null)
                    btnRender.IsEnabled = true;
            }
        }

        private void BtnCopyCsv_Click(object sender, RoutedEventArgs e)
        {
            if (_benchmarkResults.Count == 0)
            {
                MessageBox.Show("Brak danych benchmarku do skopiowania.", "Informacja", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            var sb = new StringBuilder();
            sb.AppendLine("Watki;Czas_CSharp_ms;Czas_ASM_ms;Przyspieszenie_ASM_vs_CS");
            foreach (var r in _benchmarkResults)
            {
                sb.AppendLine($"{r.Threads};{r.TimeCsMs:F2};{r.TimeAsmMs:F2};{r.SpeedupAsmVsCs:F2}");
            }

            Clipboard.SetText(sb.ToString());
            MessageBox.Show("Wyniki benchmarku zostały skopiowane do schowka w formacie CSV!", "Sukces", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        // ====================================================================
        // OBSŁUGA KONTROLEK GUI
        // ====================================================================

        private async void BtnRender_Click(object sender, RoutedEventArgs e)
        {
            await RenderFractalAsync();
        }

        private void EngineChanged(object sender, RoutedEventArgs e)
        {
            if (!IsLoaded || txtEngineInfo == null)
                return;

            if (rbAsm?.IsChecked == true)
            {
                _currentEngine = EngineType.AsmDll;
                txtEngineInfo.Text = "Aktywny silnik: Asembler x64 (AVX2)";
            }
            else if (rbCs?.IsChecked == true)
            {
                _currentEngine = EngineType.CSharp;
                txtEngineInfo.Text = "Aktywny silnik: C# (.NET)";
            }
        }

        private void ThreadsSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            _threadCount = (int)e.NewValue;
            if (txtThreadCount != null)
                txtThreadCount.Text = _threadCount.ToString();
        }

        private void IterationsSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            _maxIterations = (int)e.NewValue;
            if (txtIterations != null)
                txtIterations.Text = _maxIterations.ToString();
        }

        private void BtnResetCoords_Click(object sender, RoutedEventArgs e)
        {
            _xMin = DefaultXMin;
            _xMax = DefaultXMax;
            _yMin = DefaultYMin;
            _yMax = DefaultYMax;
            UpdateCoordinatesDisplay();
            _ = RenderFractalAsync();
        }

        // ====================================================================
        // NAWIGACJA: ZOOM I PANNING
        // ====================================================================

        private void ImgFractal_MouseWheel(object sender, MouseWheelEventArgs e)
        {
            if (imgFractal == null || imgFractal.ActualWidth <= 0 || imgFractal.ActualHeight <= 0)
                return;

            Point mousePos = e.GetPosition(imgFractal);
            double relX = Math.Clamp(mousePos.X / imgFractal.ActualWidth, 0.0, 1.0);
            double relY = Math.Clamp(mousePos.Y / imgFractal.ActualHeight, 0.0, 1.0);

            double curWidth = _xMax - _xMin;
            double curHeight = _yMax - _yMin;

            double mouseRe = _xMin + relX * curWidth;
            double mouseIm = _yMin + relY * curHeight;

            double zoomFactor = e.Delta > 0 ? 0.75 : 1.3333;

            double newWidth = curWidth * zoomFactor;
            double newHeight = curHeight * zoomFactor;

            _xMin = mouseRe - relX * newWidth;
            _xMax = _xMin + newWidth;
            _yMin = mouseIm - relY * newHeight;
            _yMax = _yMin + newHeight;

            UpdateCoordinatesDisplay();
            _ = RenderFractalAsync();
        }

        private void ImgFractal_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (imgFractal == null || imgFractal.ActualWidth <= 0 || imgFractal.ActualHeight <= 0)
                return;

            Point mousePos = e.GetPosition(imgFractal);
            double relX = Math.Clamp(mousePos.X / imgFractal.ActualWidth, 0.0, 1.0);
            double relY = Math.Clamp(mousePos.Y / imgFractal.ActualHeight, 0.0, 1.0);

            double curWidth = _xMax - _xMin;
            double curHeight = _yMax - _yMin;

            double centerRe = _xMin + relX * curWidth;
            double centerIm = _yMin + relY * curHeight;

            double zoomFactor = 0.5; // Przybliżenie 2x na kliknięcie
            double newWidth = curWidth * zoomFactor;
            double newHeight = curHeight * zoomFactor;

            _xMin = centerRe - newWidth / 2.0;
            _xMax = _xMin + newWidth;
            _yMin = centerIm - newHeight / 2.0;
            _yMax = _yMin + newHeight;

            UpdateCoordinatesDisplay();
            _ = RenderFractalAsync();
        }
    }
}
