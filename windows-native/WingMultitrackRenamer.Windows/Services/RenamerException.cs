using System;

namespace WingMultitrackRenamer.Windows.Services
{
    public sealed class RenamerException : Exception
    {
        public RenamerException(string message) : base(message)
        {
        }
    }
}
