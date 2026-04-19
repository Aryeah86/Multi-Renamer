using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Forms;
using Microsoft.Win32;
using WingMultitrackRenamer.Windows.Models;
using WingMultitrackRenamer.Windows.Services;

namespace WingMultitrackRenamer.Windows.ViewModels
{
    public sealed class MainViewModel : BindableBase
    {
        private string _folderPath = string.Empty;
        private string _snapPath = string.Empty;
        private string _selectedCard = "A";
        private string _selectedMode = "rename";
        private string _statusText = "Ready";
        private string _statusFlag = "IDLE";
        private string _outputPath = string.Empty;
        private int _progressValue;
        private int _progressMaximum = 1;
        private bool _isRunning;

        public MainViewModel()
        {
            Rows = new ObservableCollection<PlanRow>();
            ChooseFolderCommand = new RelayCommand(ChooseFolder, () => !IsRunning);
            ChooseSnapCommand = new RelayCommand(ChooseSnap, () => !IsRunning);
            SelectCardACommand = new RelayCommand(() => SelectedCard = "A", () => !IsRunning);
            SelectCardBCommand = new RelayCommand(() => SelectedCard = "B", () => !IsRunning);
            SelectRenameCommand = new RelayCommand(() => SelectedMode = "rename", () => !IsRunning);
            SelectCopyCommand = new RelayCommand(() => SelectedMode = "copy", () => !IsRunning);
            ExecuteCommand = new RelayCommand(async () => await ExecuteAsync(), () => !IsRunning);
        }

        public ObservableCollection<PlanRow> Rows { get; }

        public RelayCommand ChooseFolderCommand { get; }
        public RelayCommand ChooseSnapCommand { get; }
        public RelayCommand SelectCardACommand { get; }
        public RelayCommand SelectCardBCommand { get; }
        public RelayCommand SelectRenameCommand { get; }
        public RelayCommand SelectCopyCommand { get; }
        public RelayCommand ExecuteCommand { get; }

        public string FolderPath
        {
            get => _folderPath;
            set
            {
                if (SetProperty(ref _folderPath, value))
                {
                    RaisePropertyChanged(nameof(FolderPrimaryText));
                    RaisePropertyChanged(nameof(FolderSecondaryText));
                }
            }
        }

        public string SnapPath
        {
            get => _snapPath;
            set
            {
                if (SetProperty(ref _snapPath, value))
                {
                    RaisePropertyChanged(nameof(SnapPrimaryText));
                    RaisePropertyChanged(nameof(SnapSecondaryText));
                }
            }
        }

        public string SelectedCard
        {
            get => _selectedCard;
            set
            {
                if (SetProperty(ref _selectedCard, value))
                {
                    RaisePropertyChanged(nameof(IsCardA));
                    RaisePropertyChanged(nameof(IsCardB));
                    RaisePropertyChanged(nameof(CardMetric));
                }
            }
        }

        public string SelectedMode
        {
            get => _selectedMode;
            set
            {
                if (SetProperty(ref _selectedMode, value))
                {
                    RaisePropertyChanged(nameof(IsRenameMode));
                    RaisePropertyChanged(nameof(IsCopyMode));
                    RaisePropertyChanged(nameof(ModeMetric));
                    RaisePropertyChanged(nameof(ExecuteButtonText));
                }
            }
        }

        public string StatusText
        {
            get => _statusText;
            private set => SetProperty(ref _statusText, value);
        }

        public string StatusFlag
        {
            get => _statusFlag;
            private set => SetProperty(ref _statusFlag, value);
        }

        public string OutputPath
        {
            get => _outputPath;
            private set => SetProperty(ref _outputPath, value);
        }

        public int ProgressValue
        {
            get => _progressValue;
            private set => SetProperty(ref _progressValue, value);
        }

        public int ProgressMaximum
        {
            get => _progressMaximum;
            private set => SetProperty(ref _progressMaximum, value);
        }

        public bool IsRunning
        {
            get => _isRunning;
            private set
            {
                if (SetProperty(ref _isRunning, value))
                {
                    StatusFlag = value ? "ACTIVE" : "IDLE";
                    RaiseAllCanExecuteChanged();
                }
            }
        }

        public string FolderPrimaryText => string.IsNullOrWhiteSpace(FolderPath) ? "Select multitrack folder" : Path.GetFileName(FolderPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        public string FolderSecondaryText => string.IsNullOrWhiteSpace(FolderPath) ? "Browse or drop the WAV folder here" : FolderPath;
        public string SnapPrimaryText => string.IsNullOrWhiteSpace(SnapPath) ? "Select snap reference" : Path.GetFileName(SnapPath);
        public string SnapSecondaryText => string.IsNullOrWhiteSpace(SnapPath) ? "Browse or drop a .snap file here" : SnapPath;
        public bool IsCardA => SelectedCard == "A";
        public bool IsCardB => SelectedCard == "B";
        public bool IsRenameMode => SelectedMode == "rename";
        public bool IsCopyMode => SelectedMode == "copy";
        public string ExecuteButtonText => IsCopyMode ? "Execute Copy" : "Execute Rename";
        public int RowsMetric => Rows.Count;
        public string CardMetric => SelectedCard;
        public string ModeMetric => SelectedMode.ToUpperInvariant();

        public void AcceptDroppedFolder(string folderPath)
        {
            FolderPath = folderPath;
        }

        public void AcceptDroppedSnap(string snapPath)
        {
            SnapPath = snapPath;
        }

        private void ChooseFolder()
        {
            using (var dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Choose multitrack folder";
                dialog.SelectedPath = Directory.Exists(FolderPath) ? FolderPath : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
                if (dialog.ShowDialog() == DialogResult.OK)
                {
                    FolderPath = dialog.SelectedPath;
                }
            }
        }

        private void ChooseSnap()
        {
            var dialog = new OpenFileDialog
            {
                Filter = "Snap Files (*.snap)|*.snap|JSON Files (*.json)|*.json|All Files (*.*)|*.*",
                CheckFileExists = true,
                Title = "Choose snap file"
            };

            if (File.Exists(SnapPath))
            {
                dialog.InitialDirectory = Path.GetDirectoryName(SnapPath);
                dialog.FileName = Path.GetFileName(SnapPath);
            }
            else if (Directory.Exists(FolderPath))
            {
                dialog.InitialDirectory = FolderPath;
            }

            if (dialog.ShowDialog() == true)
            {
                SnapPath = dialog.FileName;
            }
        }

        private async Task ExecuteAsync()
        {
            string createdCopyFolderPath = null;
            var mode = SelectedMode;

            try
            {
                IsRunning = true;
                Rows.Clear();
                RaisePropertyChanged(nameof(RowsMetric));
                OutputPath = string.Empty;
                ProgressValue = 0;
                ProgressMaximum = 1;
                StatusText = "Building rename plan...";

                var folderPath = RenamerCore.EnsureFolderPath(FolderPath);
                var snapPath = RenamerCore.EnsureSnapPath(SnapPath);
                var card = SelectedCard;

                await Task.Run(() =>
                {
                    var wavEntries = RenamerCore.ScanWavs(folderPath);
                    var snapRoot = RenamerCore.LoadSnap(snapPath);
                    var destinationPath = mode == "copy"
                        ? RenamerCore.MakeTimestampedOutputFolder(folderPath, card)
                        : folderPath;
                    if (mode == "copy")
                    {
                        createdCopyFolderPath = destinationPath;
                    }
                    var rows = RenamerCore.BuildPlan(wavEntries, snapRoot, card, destinationPath);

                    Application.Current.Dispatcher.Invoke(() =>
                    {
                        foreach (var row in rows)
                        {
                            Rows.Add(row);
                        }

                        RaisePropertyChanged(nameof(RowsMetric));
                        OutputPath = destinationPath;
                        ProgressMaximum = Math.Max(1, rows.Count);
                        StatusText = mode == "copy" ? "Copying files..." : "Renaming files...";
                    });

                    Action<int, int, string> progress = (completed, total, finalName) =>
                    {
                        Application.Current.Dispatcher.Invoke(() =>
                        {
                            ProgressMaximum = Math.Max(1, total);
                            ProgressValue = completed;
                            StatusText = string.Format("{0} {1}/{2}: {3}", mode == "copy" ? "Copying" : "Renaming", completed, total, finalName);
                        });
                    };

                    if (mode == "copy")
                    {
                        RenamerCore.CopyPlan(rows, progress);
                    }
                    else
                    {
                        RenamerCore.RenamePlan(rows, progress);
                    }

                    Application.Current.Dispatcher.Invoke(() =>
                    {
                        StatusText = mode == "copy"
                            ? string.Format("Done. Copied {0} files.", rows.Count)
                            : string.Format("Done. Renamed {0} files in place.", rows.Count);
                    });
                });
            }
            catch (Exception error)
            {
                if (mode == "copy" && !string.IsNullOrWhiteSpace(createdCopyFolderPath) && Directory.Exists(createdCopyFolderPath))
                {
                    try
                    {
                        Directory.Delete(createdCopyFolderPath, true);
                    }
                    catch
                    {
                    }
                }

                StatusText = error.Message;
                System.Windows.MessageBox.Show(error.Message, "Wing Multitrack Renamer", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                IsRunning = false;
            }
        }

        private void RaiseAllCanExecuteChanged()
        {
            var commands = new[]
            {
                ChooseFolderCommand,
                ChooseSnapCommand,
                SelectCardACommand,
                SelectCardBCommand,
                SelectRenameCommand,
                SelectCopyCommand,
                ExecuteCommand
            };

            foreach (var command in commands)
            {
                command.RaiseCanExecuteChanged();
            }
        }
    }
}
