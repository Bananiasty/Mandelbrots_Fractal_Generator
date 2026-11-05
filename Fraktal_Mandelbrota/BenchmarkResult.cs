namespace Fraktal_Mandelbrota
{
    /// <summary>
    /// Reprezentuje pojedynczy wiersz porównawczy w tabeli benchmarku (C# vs ASM dla danej liczby wątków).
    /// </summary>
    public class BenchmarkResult
    {
        public int Threads { get; set; }
        public double TimeCsMs { get; set; }
        public double TimeAsmMs { get; set; }
        public double SpeedupAsmVsCs { get; set; }

        public string ThreadsDisplay => $"{Threads} {(Threads == 1 ? "wątek" : (Threads < 5 ? "wątki" : "wątków"))}";
        public string TimeCsDisplay => TimeCsMs > 0 ? $"{TimeCsMs:F2} ms" : "---";
        public string TimeAsmDisplay => TimeAsmMs > 0 ? $"{TimeAsmMs:F2} ms" : "---";
        public string SpeedupDisplay => SpeedupAsmVsCs > 0 ? $"{SpeedupAsmVsCs:F2}x" : "---";
    }
}
