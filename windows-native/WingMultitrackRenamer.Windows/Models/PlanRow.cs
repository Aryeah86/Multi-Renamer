namespace WingMultitrackRenamer.Windows.Models
{
    public sealed class PlanRow
    {
        public string SourcePath { get; set; }
        public string OriginalName { get; set; }
        public int LocalIndex { get; set; }
        public string Card { get; set; }
        public int AbsoluteSlot { get; set; }
        public string ResolvedName { get; set; }
        public string FinalName { get; set; }
        public string Status { get; set; }
        public string Note { get; set; }
        public string TargetPath { get; set; }
    }
}
