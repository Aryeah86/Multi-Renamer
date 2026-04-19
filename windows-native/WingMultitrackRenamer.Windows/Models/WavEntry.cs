namespace WingMultitrackRenamer.Windows.Models
{
    public sealed class WavEntry
    {
        public string SourcePath { get; set; }
        public string OriginalName { get; set; }
        public int LocalIndex { get; set; }
    }
}
