using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using WingMultitrackRenamer.Windows.Models;

namespace WingMultitrackRenamer.Windows.Services
{
    public static class RenamerCore
    {
        private static readonly Regex InvalidNamePattern = new Regex("[\\\\/:*?\"<>|]", RegexOptions.Compiled);
        private static readonly Regex WavPattern = new Regex(@"^Channel-(\d+)\.wav$", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private const string DefaultUnnamed = "UNNAMED";

        public static string EnsureFolderPath(string folderPath)
        {
            if (string.IsNullOrWhiteSpace(folderPath))
            {
                throw new RenamerException("Please choose a multitrack folder.");
            }

            if (!Directory.Exists(folderPath))
            {
                throw new RenamerException($"WAV folder does not exist: {folderPath}");
            }

            return folderPath;
        }

        public static string EnsureSnapPath(string snapPath)
        {
            if (string.IsNullOrWhiteSpace(snapPath))
            {
                throw new RenamerException("Please choose a snap file.");
            }

            if (!File.Exists(snapPath))
            {
                throw new RenamerException($"Snap file not found: {snapPath}");
            }

            return snapPath;
        }

        public static List<WavEntry> ScanWavs(string folderPath)
        {
            EnsureFolderPath(folderPath);

            var wavs = Directory.EnumerateFiles(folderPath)
                .Select(path =>
                {
                    var name = Path.GetFileName(path);
                    var match = WavPattern.Match(name);
                    if (!match.Success)
                    {
                        return null;
                    }

                    return new WavEntry
                    {
                        SourcePath = path,
                        OriginalName = name,
                        LocalIndex = int.Parse(match.Groups[1].Value)
                    };
                })
                .Where(entry => entry != null)
                .OrderBy(entry => entry.LocalIndex)
                .ToList();

            if (wavs.Count == 0)
            {
                throw new RenamerException($"No matching files found in {folderPath}. Expected Channel-N.WAV files.");
            }

            return wavs;
        }

        public static Dictionary<string, object> LoadSnap(string snapPath)
        {
            EnsureSnapPath(snapPath);

            object payload;
            try
            {
                payload = NormalizeJsonToken(JToken.Parse(File.ReadAllText(snapPath)));
            }
            catch (Exception error)
            {
                throw new RenamerException($"Snap is not valid JSON: {error.Message}");
            }

            if (!(payload is Dictionary<string, object> root))
            {
                throw new RenamerException("Snap root is not a JSON object.");
            }

            if (TryGetDictionary(root, "ae_data", out var wrapped) && IsProbableDataRoot(wrapped))
            {
                return wrapped;
            }

            if (IsProbableDataRoot(root))
            {
                return root;
            }

            foreach (var value in root.Values)
            {
                if (value is Dictionary<string, object> dictionary && IsProbableDataRoot(dictionary))
                {
                    return dictionary;
                }
            }

            var keys = string.Join(", ", root.Keys.OrderBy(key => key));
            throw new RenamerException($"Could not find snap data root (expected ae_data or direct data object). Top-level keys: {keys}");
        }

        public static List<PlanRow> BuildPlan(List<WavEntry> wavEntries, Dictionary<string, object> snapRoot, string card, string destinationPath)
        {
            var usedTargets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var rows = new List<PlanRow>();

            foreach (var entry in wavEntries)
            {
                var absoluteSlot = ToAbsoluteSlot(entry.LocalIndex, card);
                var resolved = ResolveSourceName(absoluteSlot, snapRoot);
                var preferredName = BuildFinalFileName(absoluteSlot, resolved.Name);
                var finalName = ResolveCollisionName(preferredName, destinationPath, entry.SourcePath, usedTargets);

                rows.Add(new PlanRow
                {
                    SourcePath = entry.SourcePath,
                    OriginalName = entry.OriginalName,
                    LocalIndex = entry.LocalIndex,
                    Card = card,
                    AbsoluteSlot = absoluteSlot,
                    ResolvedName = string.IsNullOrWhiteSpace(resolved.Name) ? DefaultUnnamed : resolved.Name,
                    FinalName = finalName,
                    Status = resolved.Status,
                    Note = resolved.Note,
                    TargetPath = Path.Combine(destinationPath, finalName)
                });
            }

            return rows;
        }

        public static void CopyPlan(List<PlanRow> rows, Action<int, int, string> progress)
        {
            for (var index = 0; index < rows.Count; index += 1)
            {
                var row = rows[index];
                File.Copy(row.SourcePath, row.TargetPath);
                progress?.Invoke(index + 1, rows.Count, row.FinalName);
            }
        }

        public static void RenamePlan(List<PlanRow> rows, Action<int, int, string> progress)
        {
            var staged = new List<StagedRename>();

            try
            {
                foreach (var row in rows)
                {
                    if (PathsEqual(row.SourcePath, row.TargetPath))
                    {
                        continue;
                    }

                    var tempPath = Path.Combine(Path.GetDirectoryName(row.SourcePath) ?? string.Empty, $".__wing_tmp__{Guid.NewGuid():N}.tmp");
                    File.Move(row.SourcePath, tempPath);
                    staged.Add(new StagedRename
                    {
                        TempPath = tempPath,
                        OriginalPath = row.SourcePath,
                        TargetPath = row.TargetPath,
                        FinalName = row.FinalName
                    });
                }

                for (var index = 0; index < staged.Count; index += 1)
                {
                    var item = staged[index];
                    File.Move(item.TempPath, item.TargetPath);
                    progress?.Invoke(index + 1, staged.Count, item.FinalName);
                }
            }
            catch
            {
                foreach (var item in staged)
                {
                    if (File.Exists(item.TempPath) && !File.Exists(item.OriginalPath))
                    {
                        try
                        {
                            File.Move(item.TempPath, item.OriginalPath);
                        }
                        catch
                        {
                        }
                    }
                }

                throw;
            }
        }

        public static string MakeTimestampedOutputFolder(string baseFolder, string card)
        {
            var stamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss");
            var destinationPath = Path.Combine(baseFolder, $"copy_card_{card.ToLowerInvariant()}_{stamp}");
            if (Directory.Exists(destinationPath))
            {
                throw new RenamerException($"Output folder already exists: {destinationPath}");
            }

            Directory.CreateDirectory(destinationPath);
            return destinationPath;
        }

        public static int ToAbsoluteSlot(int localIndex, string card)
        {
            var slot = string.Equals(card, "A", StringComparison.OrdinalIgnoreCase) ? localIndex : localIndex + 32;
            if (slot < 1 || slot > 64)
            {
                throw new RenamerException($"Absolute slot out of range: {slot}");
            }

            return slot;
        }

        private static Resolution ResolveSourceName(int absoluteSlot, Dictionary<string, object> snapRoot)
        {
            var route = NestedDictionary(snapRoot, "io", "out", "CRD", absoluteSlot.ToString());
            if (route == null)
            {
                return new Resolution { Name = string.Empty, Status = "UNRESOLVED", Note = "missing CRD route" };
            }

            var group = ValueToString(GetValue(route, "grp")).Trim().ToUpperInvariant();
            var sourceIndex = ValueToInt(GetValue(route, "in"));
            if (!sourceIndex.HasValue)
            {
                return new Resolution { Name = string.Empty, Status = "UNRESOLVED", Note = $"slot {absoluteSlot} has invalid route index" };
            }

            if (string.IsNullOrWhiteSpace(group) || group == "OFF")
            {
                return new Resolution { Name = string.Empty, Status = "UNRESOLVED", Note = $"slot {absoluteSlot} route is OFF" };
            }

            var resolution = ResolveRouteGroupName(group, sourceIndex.Value, snapRoot);
            if (!string.IsNullOrWhiteSpace(resolution.Name))
            {
                var finalName = resolution.AppendDescriptorSuffix
                    ? SanitizeName($"{resolution.Name} - {resolution.Descriptor}")
                    : resolution.Name;
                return new Resolution { Name = finalName, Status = "OK", Note = $"from {resolution.SourceRef}" };
            }

            if (!string.IsNullOrWhiteSpace(resolution.Descriptor))
            {
                return new Resolution
                {
                    Name = SanitizeName(resolution.Descriptor),
                    Status = "OK",
                    Note = $"{resolution.SourceRef} name missing; used route descriptor"
                };
            }

            return new Resolution { Name = string.Empty, Status = "UNRESOLVED", Note = $"{resolution.SourceRef} label missing or unsupported" };
        }

        private static GroupResolution ResolveRouteGroupName(string group, int sourceIndex, Dictionary<string, object> snapRoot)
        {
            var ioIn = NestedDictionary(snapRoot, "io", "in");
            if (ioIn != null && TryGetDictionary(ioIn, group, out var inputGroup))
            {
                return new GroupResolution
                {
                    Name = NameFromGroupContainer(inputGroup, sourceIndex),
                    SourceRef = $"{group}.{sourceIndex}",
                    Descriptor = $"{group} {sourceIndex}",
                    AppendDescriptorSuffix = false
                };
            }

            var rootKeyMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["MAIN"] = "main",
                ["MTX"] = "mtx",
                ["BUS"] = "bus",
                ["DCA"] = "dca",
                ["FX"] = "fx",
                ["CH"] = "ch",
                ["AUX"] = "aux",
                ["PLAY"] = "play"
            };

            if (!rootKeyMap.TryGetValue(group, out var rootKey) || !TryGetDictionary(snapRoot, rootKey, out var container))
            {
                return new GroupResolution
                {
                    Name = string.Empty,
                    SourceRef = $"{group}.{sourceIndex}",
                    Descriptor = $"{group} {sourceIndex}",
                    AppendDescriptorSuffix = false
                };
            }

            var lane = LaneToLogicalIndex(container, sourceIndex);
            if (!lane.LogicalIndex.HasValue)
            {
                return new GroupResolution
                {
                    Name = string.Empty,
                    SourceRef = $"{group}.{sourceIndex}",
                    Descriptor = $"{group} {sourceIndex}",
                    AppendDescriptorSuffix = true
                };
            }

            var descriptor = lane.Side == null
                ? $"{group} {lane.LogicalIndex.Value}"
                : $"{group} {lane.LogicalIndex.Value} {lane.Side}";

            return new GroupResolution
            {
                Name = NameFromGroupContainer(container, lane.LogicalIndex.Value),
                SourceRef = lane.LogicalIndex.Value == sourceIndex
                    ? $"{group}.{sourceIndex}"
                    : $"{group}.{sourceIndex}->{rootKey}.{lane.LogicalIndex.Value}",
                Descriptor = SanitizeName(descriptor),
                AppendDescriptorSuffix = true
            };
        }

        private static string NameFromGroupContainer(Dictionary<string, object> container, int index)
        {
            if (!TryGetDictionary(container, index.ToString(), out var node))
            {
                return string.Empty;
            }

            return SanitizeName(ValueToString(GetValue(node, "name")));
        }

        private static string SanitizeName(string raw)
        {
            return Regex.Replace(InvalidNamePattern.Replace(raw ?? string.Empty, " "), "\\s+", " ").Trim();
        }

        private static string BuildFinalFileName(int slot, string resolvedName)
        {
            var baseName = string.IsNullOrWhiteSpace(SanitizeName(resolvedName)) ? DefaultUnnamed : SanitizeName(resolvedName);
            return string.Format("{0:00} {1}.WAV", slot, baseName);
        }

        private static string ResolveCollisionName(string preferredName, string destinationPath, string sourcePath, HashSet<string> usedTargets)
        {
            var extension = Path.GetExtension(preferredName);
            var stem = preferredName.Substring(0, preferredName.Length - extension.Length);
            var candidate = preferredName;
            var counter = 1;

            while (true)
            {
                var candidatePath = Path.Combine(destinationPath, candidate);
                var sameAsSource = PathsEqual(candidatePath, sourcePath);
                var conflictInBatch = usedTargets.Contains(candidatePath);
                var conflictOnDisk = File.Exists(candidatePath) && !sameAsSource;

                if (!conflictInBatch && !conflictOnDisk)
                {
                    usedTargets.Add(candidatePath);
                    return candidate;
                }

                counter += 1;
                candidate = $"{stem} ({counter}){extension}";
            }
        }

        private static Dictionary<string, object> NestedDictionary(Dictionary<string, object> root, params string[] keys)
        {
            Dictionary<string, object> current = root;
            foreach (var key in keys)
            {
                if (current == null || !TryGetDictionary(current, key, out var next))
                {
                    return null;
                }

                current = next;
            }

            return current;
        }

        private static LaneResolution LaneToLogicalIndex(Dictionary<string, object> container, int laneIndex)
        {
            if (laneIndex <= 0)
            {
                return new LaneResolution();
            }

            var numericNodes = container
                .Select(pair => new
                {
                    HasKey = int.TryParse(pair.Key, out var key),
                    Key = int.TryParse(pair.Key, out var parsed) ? parsed : 0,
                    Value = pair.Value as Dictionary<string, object>
                })
                .Where(item => item.HasKey && item.Value != null)
                .OrderBy(item => item.Key)
                .ToList();

            if (numericNodes.Count == 0)
            {
                return new LaneResolution();
            }

            var allHaveBusMono = numericNodes.All(item => item.Value.ContainsKey("busmono"));
            if (!allHaveBusMono)
            {
                return new LaneResolution { LogicalIndex = laneIndex };
            }

            var laneCursor = 0;
            foreach (var node in numericNodes)
            {
                var width = ValueToBool(GetValue(node.Value, "busmono")) ? 1 : 2;
                var start = laneCursor + 1;
                var end = laneCursor + width;
                laneCursor = end;

                if (laneIndex >= start && laneIndex <= end)
                {
                    if (width == 2)
                    {
                        return new LaneResolution
                        {
                            LogicalIndex = node.Key,
                            Side = laneIndex == start ? "L" : "R"
                        };
                    }

                    return new LaneResolution { LogicalIndex = node.Key };
                }
            }

            return new LaneResolution();
        }

        private static bool IsProbableDataRoot(Dictionary<string, object> value)
        {
            return value != null && value.ContainsKey("io") && value.ContainsKey("ch");
        }

        private static bool TryGetDictionary(Dictionary<string, object> dictionary, string key, out Dictionary<string, object> value)
        {
            value = null;
            if (dictionary == null || !dictionary.TryGetValue(key, out var raw))
            {
                return false;
            }

            value = raw as Dictionary<string, object>;
            return value != null;
        }

        private static object GetValue(Dictionary<string, object> dictionary, string key)
        {
            if (dictionary == null || !dictionary.TryGetValue(key, out var value))
            {
                return null;
            }

            return value;
        }

        private static string ValueToString(object value)
        {
            return value == null ? string.Empty : Convert.ToString(value);
        }

        private static int? ValueToInt(object value)
        {
            if (value == null)
            {
                return null;
            }

            switch (value)
            {
                case int intValue:
                    return intValue;
                case long longValue:
                    return checked((int)longValue);
                case double doubleValue:
                    return (int)doubleValue;
                case decimal decimalValue:
                    return (int)decimalValue;
                case string text when int.TryParse(text, out var parsed):
                    return parsed;
                default:
                    return null;
            }
        }

        private static bool ValueToBool(object value)
        {
            switch (value)
            {
                case bool boolValue:
                    return boolValue;
                case int intValue:
                    return intValue != 0;
                case long longValue:
                    return longValue != 0;
                case string text when bool.TryParse(text, out var parsed):
                    return parsed;
                case string text when int.TryParse(text, out var parsedInt):
                    return parsedInt != 0;
                default:
                    return false;
            }
        }

        private static bool PathsEqual(string left, string right)
        {
            return string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
        }

        private static object NormalizeJsonToken(JToken token)
        {
            switch (token.Type)
            {
                case JTokenType.Object:
                    return token.Children<JProperty>()
                        .ToDictionary(property => property.Name, property => NormalizeJsonToken(property.Value), StringComparer.Ordinal);

                case JTokenType.Array:
                    return token.Children().Select(NormalizeJsonToken).ToList();

                case JTokenType.Integer:
                    return token.Value<long>();

                case JTokenType.Float:
                    return token.Value<double>();

                case JTokenType.Boolean:
                    return token.Value<bool>();

                case JTokenType.Null:
                case JTokenType.Undefined:
                    return null;

                default:
                    return token.Value<string>();
            }
        }

        private sealed class Resolution
        {
            public string Name { get; set; }
            public string Status { get; set; }
            public string Note { get; set; }
        }

        private sealed class GroupResolution
        {
            public string Name { get; set; }
            public string SourceRef { get; set; }
            public string Descriptor { get; set; }
            public bool AppendDescriptorSuffix { get; set; }
        }

        private sealed class LaneResolution
        {
            public int? LogicalIndex { get; set; }
            public string Side { get; set; }
        }

        private sealed class StagedRename
        {
            public string TempPath { get; set; }
            public string OriginalPath { get; set; }
            public string TargetPath { get; set; }
            public string FinalName { get; set; }
        }
    }
}
