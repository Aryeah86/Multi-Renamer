using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using WingMultitrackRenamer.Windows.ViewModels;

namespace WingMultitrackRenamer.Windows
{
    public partial class MainWindow : Window
    {
        private readonly Brush _normalBorderBrush = (Brush)new BrushConverter().ConvertFromString("#CFC7B9");
        private readonly Brush _activeBorderBrush = (Brush)new BrushConverter().ConvertFromString("#5CE5FF");
        private readonly Brush _normalPanelBrush = (Brush)new BrushConverter().ConvertFromString("#0E0E0E");
        private readonly Brush _activePanelBrush = (Brush)new BrushConverter().ConvertFromString("#0F1B1F");

        public MainWindow()
        {
            InitializeComponent();
            DataContext = new MainViewModel();
        }

        private MainViewModel ViewModel => (MainViewModel)DataContext;

        private void FolderPanel_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (ViewModel.ChooseFolderCommand.CanExecute(null))
            {
                ViewModel.ChooseFolderCommand.Execute(null);
            }
        }

        private void SnapPanel_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (ViewModel.ChooseSnapCommand.CanExecute(null))
            {
                ViewModel.ChooseSnapCommand.Execute(null);
            }
        }

        private void Panel_DragOver(object sender, DragEventArgs e)
        {
            e.Effects = DragDropEffects.Copy;
            e.Handled = true;
            if (sender is FrameworkElement panel)
            {
                SetDropTargetState(panel, true);
            }
        }

        private void FolderPanel_Drop(object sender, DragEventArgs e)
        {
            HandleDrop(e, true, path => ViewModel.AcceptDroppedFolder(path));
            SetDropTargetState(FolderPanel, false);
        }

        private void SnapPanel_Drop(object sender, DragEventArgs e)
        {
            HandleDrop(e, false, path => ViewModel.AcceptDroppedSnap(path));
            SetDropTargetState(SnapPanel, false);
        }

        private void HandleDrop(DragEventArgs e, bool expectingDirectory, System.Action<string> apply)
        {
            if (!e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                return;
            }

            var paths = (string[])e.Data.GetData(DataFormats.FileDrop);
            if (paths == null)
            {
                return;
            }

            foreach (var path in paths)
            {
                if (expectingDirectory && Directory.Exists(path))
                {
                    apply(path);
                    return;
                }

                if (!expectingDirectory && File.Exists(path) && Path.GetExtension(path).ToLowerInvariant() == ".snap")
                {
                    apply(path);
                    return;
                }
            }
        }

        protected override void OnDragLeave(DragEventArgs e)
        {
            base.OnDragLeave(e);
            SetDropTargetState(FolderPanel, false);
            SetDropTargetState(SnapPanel, false);
        }

        private void SetDropTargetState(FrameworkElement panel, bool active)
        {
            if (!(panel is System.Windows.Controls.Border border))
            {
                return;
            }

            border.BorderBrush = active ? _activeBorderBrush : _normalBorderBrush;
            border.Background = active ? _activePanelBrush : _normalPanelBrush;
        }
    }
}
