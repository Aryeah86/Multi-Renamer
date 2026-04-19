#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "json.hpp"

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shlwapi.lib")

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace {
constexpr int IDC_FOLDER_EDIT = 1001;
constexpr int IDC_FOLDER_BUTTON = 1002;
constexpr int IDC_SNAP_EDIT = 1003;
constexpr int IDC_SNAP_BUTTON = 1004;
constexpr int IDC_CARD_A = 1005;
constexpr int IDC_CARD_B = 1006;
constexpr int IDC_MODE_RENAME = 1007;
constexpr int IDC_MODE_COPY = 1008;
constexpr int IDC_EXECUTE = 1009;
constexpr int IDC_STATUS = 1010;
constexpr int IDC_PROGRESS = 1011;
constexpr int IDC_ROWS = 1012;
constexpr int IDC_OUTPUT = 1013;
constexpr int IDC_ROWS_METRIC = 1014;
constexpr int IDC_CARD_METRIC = 1015;
constexpr int IDC_MODE_METRIC = 1016;

constexpr UINT WM_APP_PROGRESS = WM_APP + 1;
constexpr UINT WM_APP_DONE = WM_APP + 2;
constexpr UINT WM_APP_ERROR = WM_APP + 3;

const wchar_t kWindowClass[] = L"WingMultitrackRenamerWin32";
const wchar_t kAppTitle[] = L"Wing Multitrack Renamer";

struct WavEntry {
    fs::path sourcePath;
    std::wstring originalName;
    int localIndex = 0;
};

struct PlanRow {
    fs::path sourcePath;
    std::wstring originalName;
    int localIndex = 0;
    wchar_t card = L'A';
    int absoluteSlot = 0;
    std::wstring resolvedName;
    std::wstring finalName;
    std::wstring status;
    std::wstring note;
    fs::path targetPath;
};

struct Resolution {
    std::wstring name;
    std::wstring status;
    std::wstring note;
};

struct GroupResolution {
    std::wstring name;
    std::wstring sourceRef;
    std::wstring descriptor;
    bool appendDescriptorSuffix = false;
};

struct LaneResolution {
    std::optional<int> logicalIndex;
    std::wstring side;
};

struct RunResult {
    std::vector<PlanRow> rows;
    fs::path outputPath;
    std::wstring mode;
};

struct ProgressPayload {
    int completed = 0;
    int total = 0;
    std::wstring finalName;
};

struct Controls {
    HWND folderEdit = nullptr;
    HWND snapEdit = nullptr;
    HWND cardA = nullptr;
    HWND cardB = nullptr;
    HWND modeRename = nullptr;
    HWND modeCopy = nullptr;
    HWND execute = nullptr;
    HWND status = nullptr;
    HWND progress = nullptr;
    HWND rows = nullptr;
    HWND output = nullptr;
    HWND rowsMetric = nullptr;
    HWND cardMetric = nullptr;
    HWND modeMetric = nullptr;
};

struct AppState {
    Controls controls;
    std::wstring folderPath;
    std::wstring snapPath;
    wchar_t card = L'A';
    std::wstring mode = L"rename";
    bool isRunning = false;
    std::vector<PlanRow> rows;
    std::mutex workerMutex;
    std::unique_ptr<RunResult> pendingResult;
    std::unique_ptr<ProgressPayload> pendingProgress;
    std::unique_ptr<std::wstring> pendingError;
};

AppState g_state;

std::wstring Utf8ToWide(const std::string& text) {
    if (text.empty()) return L"";
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size);
    return result;
}

std::string WideToUtf8(const std::wstring& text) {
    if (text.empty()) return "";
    const int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string result(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
    return result;
}

std::wstring ToWide(const json& value) {
    if (value.is_string()) return Utf8ToWide(value.get<std::string>());
    if (value.is_number_integer()) return std::to_wstring(value.get<long long>());
    if (value.is_number_unsigned()) return std::to_wstring(value.get<unsigned long long>());
    if (value.is_number_float()) return Utf8ToWide(std::to_string(value.get<double>()));
    if (value.is_boolean()) return value.get<bool>() ? L"true" : L"false";
    return L"";
}

std::optional<int> ToInt(const json& value) {
    if (value.is_number_integer()) return value.get<int>();
    if (value.is_number_unsigned()) return static_cast<int>(value.get<unsigned int>());
    if (value.is_string()) {
        try {
            return std::stoi(value.get<std::string>());
        } catch (...) {
            return std::nullopt;
        }
    }
    return std::nullopt;
}

bool ToBool(const json& value) {
    if (value.is_boolean()) return value.get<bool>();
    if (value.is_number_integer()) return value.get<int>() != 0;
    if (value.is_string()) {
        auto text = value.get<std::string>();
        return text == "1" || text == "true" || text == "TRUE";
    }
    return false;
}

std::wstring SanitizeName(const std::wstring& raw) {
    std::wstring cleaned;
    cleaned.reserve(raw.size());
    for (wchar_t ch : raw) {
        switch (ch) {
            case L'\\':
            case L'/':
            case L':':
            case L'*':
            case L'?':
            case L'"':
            case L'<':
            case L'>':
            case L'|':
                cleaned.push_back(L' ');
                break;
            default:
                cleaned.push_back(ch);
                break;
        }
    }

    std::wstringstream stream(cleaned);
    std::wstring token;
    std::wstring collapsed;
    while (stream >> token) {
        if (!collapsed.empty()) collapsed += L' ';
        collapsed += token;
    }
    return collapsed;
}

json LoadJsonFile(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("Failed to open snap file.");
    json payload;
    stream >> payload;
    return payload;
}

const json* Nested(const json& root, std::initializer_list<const char*> keys) {
    const json* current = &root;
    for (const char* key : keys) {
        if (!current->is_object()) return nullptr;
        auto it = current->find(key);
        if (it == current->end()) return nullptr;
        current = &(*it);
    }
    return current;
}

const json* NestedKey(const json& root, const std::vector<std::string>& keys) {
    const json* current = &root;
    for (const auto& key : keys) {
        if (!current->is_object()) return nullptr;
        auto it = current->find(key);
        if (it == current->end()) return nullptr;
        current = &(*it);
    }
    return current;
}

bool IsProbableDataRoot(const json& value) {
    return value.is_object() && value.contains("io") && value.contains("ch");
}

json LoadSnap(const fs::path& snapPath) {
    auto payload = LoadJsonFile(snapPath);
    if (!payload.is_object()) throw std::runtime_error("Snap root is not a JSON object.");
    if (payload.contains("ae_data") && IsProbableDataRoot(payload["ae_data"])) return payload["ae_data"];
    if (IsProbableDataRoot(payload)) return payload;
    for (auto it = payload.begin(); it != payload.end(); ++it) {
        if (IsProbableDataRoot(it.value())) return it.value();
    }
    throw std::runtime_error("Could not find snap data root.");
}

std::vector<WavEntry> ScanWavs(const fs::path& folderPath) {
    if (!fs::exists(folderPath) || !fs::is_directory(folderPath)) {
        throw std::runtime_error("Please choose a valid multitrack folder.");
    }

    std::wregex pattern(LR"(^Channel-(\d+)\.wav$)", std::regex::icase);
    std::vector<WavEntry> wavs;
    for (const auto& entry : fs::directory_iterator(folderPath)) {
        if (!entry.is_regular_file()) continue;
        std::wsmatch match;
        auto name = entry.path().filename().wstring();
        if (!std::regex_match(name, match, pattern)) continue;
        wavs.push_back({entry.path(), name, std::stoi(match[1].str())});
    }

    std::sort(wavs.begin(), wavs.end(), [](const auto& a, const auto& b) { return a.localIndex < b.localIndex; });
    if (wavs.empty()) throw std::runtime_error("No matching Channel-N.WAV files found.");
    return wavs;
}

int ToAbsoluteSlot(int localIndex, wchar_t card) {
    int slot = (card == L'A') ? localIndex : localIndex + 32;
    if (slot < 1 || slot > 64) throw std::runtime_error("Absolute slot out of range.");
    return slot;
}

std::wstring NameFromGroupContainer(const json& container, int index) {
    auto key = std::to_string(index);
    auto it = container.find(key);
    if (it == container.end() || !it->is_object()) return L"";
    auto nameIt = it->find("name");
    if (nameIt == it->end()) return L"";
    return SanitizeName(ToWide(*nameIt));
}

LaneResolution LaneToLogicalIndex(const json& container, int laneIndex) {
    if (laneIndex <= 0) return {};

    struct Node { int key; const json* value; };
    std::vector<Node> nodes;
    for (auto it = container.begin(); it != container.end(); ++it) {
        if (!it.value().is_object()) continue;
        try {
            nodes.push_back({std::stoi(it.key()), &it.value()});
        } catch (...) {
        }
    }
    std::sort(nodes.begin(), nodes.end(), [](const auto& a, const auto& b) { return a.key < b.key; });
    if (nodes.empty()) return {};

    bool allHaveBusMono = std::all_of(nodes.begin(), nodes.end(), [](const auto& node) { return node.value->contains("busmono"); });
    if (!allHaveBusMono) return {laneIndex, L""};

    int laneCursor = 0;
    for (const auto& node : nodes) {
        int width = ToBool((*node.value)["busmono"]) ? 1 : 2;
        int start = laneCursor + 1;
        int end = laneCursor + width;
        laneCursor = end;
        if (laneIndex >= start && laneIndex <= end) {
            if (width == 2) return {node.key, laneIndex == start ? L"L" : L"R"};
            return {node.key, L""};
        }
    }
    return {};
}

GroupResolution ResolveRouteGroupName(const std::wstring& groupWide, int sourceIndex, const json& snapRoot) {
    const std::string group = WideToUtf8(groupWide);
    const json* ioIn = Nested(snapRoot, {"io", "in"});
    if (ioIn && ioIn->is_object()) {
        auto it = ioIn->find(group);
        if (it != ioIn->end() && it->is_object()) {
            return {NameFromGroupContainer(*it, sourceIndex), Utf8ToWide(group + "." + std::to_string(sourceIndex)), groupWide + L" " + std::to_wstring(sourceIndex), false};
        }
    }

    std::map<std::wstring, std::string> rootKeyMap = {
        {L"MAIN", "main"}, {L"MTX", "mtx"}, {L"BUS", "bus"}, {L"DCA", "dca"},
        {L"FX", "fx"}, {L"CH", "ch"}, {L"AUX", "aux"}, {L"PLAY", "play"}
    };
    auto mapIt = rootKeyMap.find(groupWide);
    if (mapIt == rootKeyMap.end()) {
        return {L"", groupWide + L"." + std::to_wstring(sourceIndex), groupWide + L" " + std::to_wstring(sourceIndex), false};
    }

    const json* container = NestedKey(snapRoot, {mapIt->second});
    if (!container || !container->is_object()) {
        return {L"", groupWide + L"." + std::to_wstring(sourceIndex), groupWide + L" " + std::to_wstring(sourceIndex), false};
    }

    LaneResolution lane = LaneToLogicalIndex(*container, sourceIndex);
    if (!lane.logicalIndex.has_value()) {
        return {L"", groupWide + L"." + std::to_wstring(sourceIndex), groupWide + L" " + std::to_wstring(sourceIndex), true};
    }

    std::wstring descriptor = groupWide + L" " + std::to_wstring(*lane.logicalIndex);
    if (!lane.side.empty()) descriptor += L" " + lane.side;
    std::wstring sourceRef = (*lane.logicalIndex == sourceIndex)
        ? groupWide + L"." + std::to_wstring(sourceIndex)
        : groupWide + L"." + std::to_wstring(sourceIndex) + L"->" + Utf8ToWide(mapIt->second) + L"." + std::to_wstring(*lane.logicalIndex);

    return {NameFromGroupContainer(*container, *lane.logicalIndex), sourceRef, SanitizeName(descriptor), true};
}

Resolution ResolveSourceName(int absoluteSlot, const json& snapRoot) {
    const json* route = NestedKey(snapRoot, {"io", "out", "CRD", std::to_string(absoluteSlot)});
    if (!route || !route->is_object()) return {L"", L"UNRESOLVED", L"missing CRD route"};

    std::wstring group = SanitizeName(ToWide(route->value("grp", json())));
    std::transform(group.begin(), group.end(), group.begin(), towupper);
    std::optional<int> sourceIndex = ToInt(route->value("in", json()));
    if (!sourceIndex.has_value()) return {L"", L"UNRESOLVED", L"invalid route index"};
    if (group.empty() || group == L"OFF") return {L"", L"UNRESOLVED", L"route is OFF"};

    GroupResolution resolution = ResolveRouteGroupName(group, *sourceIndex, snapRoot);
    if (!resolution.name.empty()) {
        std::wstring finalName = resolution.appendDescriptorSuffix ? SanitizeName(resolution.name + L" - " + resolution.descriptor) : resolution.name;
        return {finalName, L"OK", L"from " + resolution.sourceRef};
    }
    if (!resolution.descriptor.empty()) {
        return {SanitizeName(resolution.descriptor), L"OK", resolution.sourceRef + L" name missing; used route descriptor"};
    }
    return {L"", L"UNRESOLVED", resolution.sourceRef + L" label missing or unsupported"};
}

std::wstring BuildFinalFileName(int slot, const std::wstring& resolvedName) {
    std::wstringstream stream;
    std::wstring base = SanitizeName(resolvedName);
    if (base.empty()) base = L"UNNAMED";
    stream << std::setw(2) << std::setfill(L'0') << slot << L' ' << base << L".WAV";
    return stream.str();
}

bool PathsEqual(const fs::path& a, const fs::path& b) {
    return fs::weakly_canonical(a).wstring() == fs::weakly_canonical(b).wstring();
}

std::wstring ResolveCollisionName(const std::wstring& preferredName, const fs::path& destinationPath, const fs::path& sourcePath, std::set<std::wstring>& used) {
    fs::path preferred(preferredName);
    std::wstring stem = preferred.stem().wstring();
    std::wstring ext = preferred.extension().wstring();
    std::wstring candidate = preferredName;
    int counter = 1;
    for (;;) {
        fs::path candidatePath = destinationPath / candidate;
        bool sameAsSource = PathsEqual(candidatePath, sourcePath);
        bool conflictInBatch = used.find(candidatePath.wstring()) != used.end();
        bool conflictOnDisk = fs::exists(candidatePath) && !sameAsSource;
        if (!conflictInBatch && !conflictOnDisk) {
            used.insert(candidatePath.wstring());
            return candidate;
        }
        ++counter;
        candidate = stem + L" (" + std::to_wstring(counter) + L")" + ext;
    }
}

std::vector<PlanRow> BuildPlan(const std::vector<WavEntry>& wavEntries, const json& snapRoot, wchar_t card, const fs::path& destinationPath) {
    std::set<std::wstring> usedTargets;
    std::vector<PlanRow> rows;
    for (const auto& entry : wavEntries) {
        int absoluteSlot = ToAbsoluteSlot(entry.localIndex, card);
        Resolution resolved = ResolveSourceName(absoluteSlot, snapRoot);
        std::wstring finalName = ResolveCollisionName(BuildFinalFileName(absoluteSlot, resolved.name), destinationPath, entry.sourcePath, usedTargets);
        rows.push_back({entry.sourcePath, entry.originalName, entry.localIndex, card, absoluteSlot, resolved.name.empty() ? L"UNNAMED" : resolved.name, finalName, resolved.status, resolved.note, destinationPath / finalName});
    }
    return rows;
}

fs::path MakeTimestampedOutputFolder(const fs::path& baseFolder, wchar_t card) {
    SYSTEMTIME st{};
    GetLocalTime(&st);
    wchar_t stamp[32];
    swprintf(stamp, 32, L"%04d%02d%02d_%02d%02d%02d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    fs::path path = baseFolder / (std::wstring(L"copy_card_") + (card == L'A' ? L"a_" : L"b_") + stamp);
    if (fs::exists(path)) throw std::runtime_error("Output folder already exists.");
    fs::create_directories(path);
    return path;
}

void UpdateEditText(HWND hwnd, const std::wstring& text) { SetWindowTextW(hwnd, text.c_str()); }
std::wstring ReadEditText(HWND hwnd) {
    int length = GetWindowTextLengthW(hwnd);
    std::wstring value(length, L'\0');
    GetWindowTextW(hwnd, value.data(), length + 1);
    return value;
}

void SetStatus(const std::wstring& text) { SetWindowTextW(g_state.controls.status, text.c_str()); }

void RefreshMetrics() {
    SetWindowTextW(g_state.controls.rowsMetric, std::to_wstring(g_state.rows.size()).c_str());
    std::wstring card(1, g_state.card);
    SetWindowTextW(g_state.controls.cardMetric, card.c_str());
    std::wstring mode = g_state.mode;
    std::transform(mode.begin(), mode.end(), mode.begin(), towupper);
    SetWindowTextW(g_state.controls.modeMetric, mode.c_str());
}

void RefreshSelectionButtons() {
    SendMessageW(g_state.controls.cardA, BM_SETCHECK, g_state.card == L'A' ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_state.controls.cardB, BM_SETCHECK, g_state.card == L'B' ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_state.controls.modeRename, BM_SETCHECK, g_state.mode == L"rename" ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_state.controls.modeCopy, BM_SETCHECK, g_state.mode == L"copy" ? BST_CHECKED : BST_UNCHECKED, 0);
}

void RefreshRows() {
    ListView_DeleteAllItems(g_state.controls.rows);
    for (size_t i = 0; i < g_state.rows.size(); ++i) {
        const auto& row = g_state.rows[i];
        LVITEMW item{};
        item.mask = LVIF_TEXT;
        item.iItem = static_cast<int>(i);
        std::wstring original = row.originalName;
        item.pszText = original.data();
        ListView_InsertItem(g_state.controls.rows, &item);

        std::wstring abs = std::to_wstring(row.absoluteSlot);
        ListView_SetItemText(g_state.controls.rows, static_cast<int>(i), 1, abs.data());
        std::wstring finalName = row.finalName;
        ListView_SetItemText(g_state.controls.rows, static_cast<int>(i), 2, finalName.data());
        std::wstring status = row.status;
        ListView_SetItemText(g_state.controls.rows, static_cast<int>(i), 3, status.data());
    }
    RefreshMetrics();
}

void SetRunning(bool running) {
    g_state.isRunning = running;
    EnableWindow(g_state.controls.execute, running ? FALSE : TRUE);
    EnableWindow(g_state.controls.folderEdit, running ? FALSE : TRUE);
    EnableWindow(g_state.controls.snapEdit, running ? FALSE : TRUE);
    EnableWindow(g_state.controls.cardA, running ? FALSE : TRUE);
    EnableWindow(g_state.controls.cardB, running ? FALSE : TRUE);
    EnableWindow(g_state.controls.modeRename, running ? FALSE : TRUE);
    EnableWindow(g_state.controls.modeCopy, running ? FALSE : TRUE);
}

void WorkerThread(HWND hwnd, std::wstring folderPath, std::wstring snapPath, wchar_t card, std::wstring mode) {
    try {
        auto wavEntries = ScanWavs(folderPath);
        auto snapRoot = LoadSnap(snapPath);
        fs::path destination = mode == L"copy" ? MakeTimestampedOutputFolder(folderPath, card) : fs::path(folderPath);
        auto rows = BuildPlan(wavEntries, snapRoot, card, destination);

        int total = static_cast<int>(rows.size());
        for (int i = 0; i < total; ++i) {
            const auto& row = rows[i];
            if (mode == L"copy") {
                fs::copy_file(row.sourcePath, row.targetPath, fs::copy_options::overwrite_existing);
            } else if (!PathsEqual(row.sourcePath, row.targetPath)) {
                fs::rename(row.sourcePath, row.targetPath);
            }
            auto progress = std::make_unique<ProgressPayload>();
            progress->completed = i + 1;
            progress->total = total;
            progress->finalName = row.finalName;
            {
                std::lock_guard<std::mutex> lock(g_state.workerMutex);
                g_state.pendingProgress = std::move(progress);
            }
            PostMessageW(hwnd, WM_APP_PROGRESS, 0, 0);
        }

        auto result = std::make_unique<RunResult>();
        result->rows = std::move(rows);
        result->outputPath = destination;
        result->mode = mode;
        {
            std::lock_guard<std::mutex> lock(g_state.workerMutex);
            g_state.pendingResult = std::move(result);
        }
        PostMessageW(hwnd, WM_APP_DONE, 0, 0);
    } catch (const std::exception& ex) {
        auto error = std::make_unique<std::wstring>(Utf8ToWide(ex.what()));
        {
            std::lock_guard<std::mutex> lock(g_state.workerMutex);
            g_state.pendingError = std::move(error);
        }
        PostMessageW(hwnd, WM_APP_ERROR, 0, 0);
    }
}

void StartExecution(HWND hwnd) {
    g_state.folderPath = ReadEditText(g_state.controls.folderEdit);
    g_state.snapPath = ReadEditText(g_state.controls.snapEdit);
    if (g_state.folderPath.empty()) { MessageBoxW(hwnd, L"Please choose a multitrack folder.", kAppTitle, MB_OK | MB_ICONERROR); return; }
    if (g_state.snapPath.empty()) { MessageBoxW(hwnd, L"Please choose a snap file.", kAppTitle, MB_OK | MB_ICONERROR); return; }

    g_state.rows.clear();
    RefreshRows();
    SetWindowTextW(g_state.controls.output, L"");
    SendMessageW(g_state.controls.progress, PBM_SETPOS, 0, 0);
    SendMessageW(g_state.controls.progress, PBM_SETRANGE32, 0, 1);
    SetStatus(L"Building rename plan...");
    SetRunning(true);

    std::thread(WorkerThread, hwnd, g_state.folderPath, g_state.snapPath, g_state.card, g_state.mode).detach();
}

std::optional<std::wstring> PickFolder(HWND hwnd) {
    BROWSEINFOW bi{};
    bi.hwndOwner = hwnd;
    bi.lpszTitle = L"Choose multitrack folder";
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
    PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi);
    if (!pidl) return std::nullopt;
    wchar_t path[MAX_PATH]{};
    std::optional<std::wstring> result;
    if (SHGetPathFromIDListW(pidl, path)) result = path;
    CoTaskMemFree(pidl);
    return result;
}

std::optional<std::wstring> PickSnap(HWND hwnd) {
    OPENFILENAMEW ofn{};
    wchar_t fileName[MAX_PATH]{};
    wchar_t filter[] = L"Snap Files (*.snap)\0*.snap\0JSON Files (*.json)\0*.json\0All Files (*.*)\0*.*\0\0";
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = hwnd;
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = fileName;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    ofn.lpstrTitle = L"Choose snap file";
    if (GetOpenFileNameW(&ofn)) return std::wstring(fileName);
    return std::nullopt;
}

void HandleDroppedFiles(HDROP hDrop) {
    UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; ++i) {
        wchar_t path[MAX_PATH]{};
        DragQueryFileW(hDrop, i, path, MAX_PATH);
        fs::path dropped(path);
        if (fs::is_directory(dropped) && g_state.folderPath.empty()) {
            g_state.folderPath = dropped.wstring();
            UpdateEditText(g_state.controls.folderEdit, g_state.folderPath);
            continue;
        }
        if (PathMatchSpecW(dropped.extension().c_str(), L".snap") || PathMatchSpecW(dropped.extension().c_str(), L".json")) {
            g_state.snapPath = dropped.wstring();
            UpdateEditText(g_state.controls.snapEdit, g_state.snapPath);
        }
    }
    DragFinish(hDrop);
}

HWND CreateLabel(HWND parent, const wchar_t* text, int x, int y, int w, int h, HFONT font, COLORREF color = RGB(92,229,255)) {
    HWND hwnd = CreateWindowW(L"STATIC", text, WS_CHILD | WS_VISIBLE, x, y, w, h, parent, nullptr, nullptr, nullptr);
    SendMessageW(hwnd, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    return hwnd;
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
        case WM_CREATE: {
            INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_LISTVIEW_CLASSES | ICC_PROGRESS_CLASS};
            InitCommonControlsEx(&icc);
            DragAcceptFiles(hwnd, TRUE);

            HFONT font = CreateFontW(-16, 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN, L"Consolas");
            HFONT titleFont = CreateFontW(-28, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN, L"Consolas");

            CreateLabel(hwnd, L"Wing Multitrack Renamer", 20, 18, 400, 32, titleFont);

            CreateLabel(hwnd, L"SLOT 1: SOURCE", 20, 64, 200, 18, font);
            g_state.controls.folderEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 20, 86, 560, 28, hwnd, reinterpret_cast<HMENU>(IDC_FOLDER_EDIT), nullptr, nullptr);
            CreateWindowW(L"BUTTON", L"Browse...", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 590, 86, 130, 28, hwnd, reinterpret_cast<HMENU>(IDC_FOLDER_BUTTON), nullptr, nullptr);

            CreateLabel(hwnd, L"SLOT 2: REFERENCE", 20, 128, 200, 18, font);
            g_state.controls.snapEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 20, 150, 560, 28, hwnd, reinterpret_cast<HMENU>(IDC_SNAP_EDIT), nullptr, nullptr);
            CreateWindowW(L"BUTTON", L"Browse...", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 590, 150, 130, 28, hwnd, reinterpret_cast<HMENU>(IDC_SNAP_BUTTON), nullptr, nullptr);

            g_state.controls.cardA = CreateWindowW(L"BUTTON", L"CARD A  1-32", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, 20, 200, 150, 24, hwnd, reinterpret_cast<HMENU>(IDC_CARD_A), nullptr, nullptr);
            g_state.controls.cardB = CreateWindowW(L"BUTTON", L"CARD B  33-64", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, 190, 200, 170, 24, hwnd, reinterpret_cast<HMENU>(IDC_CARD_B), nullptr, nullptr);
            g_state.controls.modeRename = CreateWindowW(L"BUTTON", L"RENAME", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, 420, 200, 130, 24, hwnd, reinterpret_cast<HMENU>(IDC_MODE_RENAME), nullptr, nullptr);
            g_state.controls.modeCopy = CreateWindowW(L"BUTTON", L"COPY", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON, 570, 200, 100, 24, hwnd, reinterpret_cast<HMENU>(IDC_MODE_COPY), nullptr, nullptr);

            g_state.controls.execute = CreateWindowW(L"BUTTON", L"Execute Rename", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 20, 240, 700, 38, hwnd, reinterpret_cast<HMENU>(IDC_EXECUTE), nullptr, nullptr);

            CreateLabel(hwnd, L"SYSTEM STATUS", 20, 298, 200, 18, font);
            g_state.controls.status = CreateWindowW(L"STATIC", L"Ready", WS_CHILD | WS_VISIBLE, 20, 322, 700, 20, hwnd, reinterpret_cast<HMENU>(IDC_STATUS), nullptr, nullptr);
            g_state.controls.progress = CreateWindowExW(0, PROGRESS_CLASSW, nullptr, WS_CHILD | WS_VISIBLE, 20, 350, 700, 16, hwnd, reinterpret_cast<HMENU>(IDC_PROGRESS), nullptr, nullptr);
            CreateLabel(hwnd, L"ROWS", 20, 376, 60, 18, font);
            g_state.controls.rowsMetric = CreateWindowW(L"STATIC", L"0", WS_CHILD | WS_VISIBLE, 20, 396, 50, 20, hwnd, reinterpret_cast<HMENU>(IDC_ROWS_METRIC), nullptr, nullptr);
            CreateLabel(hwnd, L"CARD", 120, 376, 60, 18, font);
            g_state.controls.cardMetric = CreateWindowW(L"STATIC", L"A", WS_CHILD | WS_VISIBLE, 120, 396, 50, 20, hwnd, reinterpret_cast<HMENU>(IDC_CARD_METRIC), nullptr, nullptr);
            CreateLabel(hwnd, L"MODE", 220, 376, 60, 18, font);
            g_state.controls.modeMetric = CreateWindowW(L"STATIC", L"RENAME", WS_CHILD | WS_VISIBLE, 220, 396, 120, 20, hwnd, reinterpret_cast<HMENU>(IDC_MODE_METRIC), nullptr, nullptr);
            g_state.controls.output = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFTNOWORDWRAP, 20, 424, 700, 20, hwnd, reinterpret_cast<HMENU>(IDC_OUTPUT), nullptr, nullptr);

            g_state.controls.rows = CreateWindowExW(WS_EX_CLIENTEDGE, WC_LISTVIEWW, nullptr, WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_SINGLESEL, 20, 456, 700, 220, hwnd, reinterpret_cast<HMENU>(IDC_ROWS), nullptr, nullptr);
            ListView_SetExtendedListViewStyle(g_state.controls.rows, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
            LVCOLUMNW col{};
            col.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
            col.pszText = const_cast<LPWSTR>(L"Original"); col.cx = 180; ListView_InsertColumn(g_state.controls.rows, 0, &col);
            col.pszText = const_cast<LPWSTR>(L"Abs"); col.cx = 70; col.iSubItem = 1; ListView_InsertColumn(g_state.controls.rows, 1, &col);
            col.pszText = const_cast<LPWSTR>(L"Final"); col.cx = 330; col.iSubItem = 2; ListView_InsertColumn(g_state.controls.rows, 2, &col);
            col.pszText = const_cast<LPWSTR>(L"State"); col.cx = 90; col.iSubItem = 3; ListView_InsertColumn(g_state.controls.rows, 3, &col);

            for (HWND ctl : {g_state.controls.folderEdit, g_state.controls.snapEdit, g_state.controls.cardA, g_state.controls.cardB, g_state.controls.modeRename, g_state.controls.modeCopy, g_state.controls.execute, g_state.controls.status, g_state.controls.output, g_state.controls.rowsMetric, g_state.controls.cardMetric, g_state.controls.modeMetric, g_state.controls.rows}) {
                SendMessageW(ctl, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            }
            RefreshSelectionButtons();
            RefreshMetrics();
            break;
        }
        case WM_COMMAND: {
            switch (LOWORD(wParam)) {
                case IDC_FOLDER_BUTTON:
                    if (auto chosen = PickFolder(hwnd)) { g_state.folderPath = *chosen; UpdateEditText(g_state.controls.folderEdit, *chosen); }
                    break;
                case IDC_SNAP_BUTTON:
                    if (auto chosen = PickSnap(hwnd)) { g_state.snapPath = *chosen; UpdateEditText(g_state.controls.snapEdit, *chosen); }
                    break;
                case IDC_CARD_A:
                    g_state.card = L'A'; RefreshSelectionButtons(); RefreshMetrics(); break;
                case IDC_CARD_B:
                    g_state.card = L'B'; RefreshSelectionButtons(); RefreshMetrics(); break;
                case IDC_MODE_RENAME:
                    g_state.mode = L"rename"; RefreshSelectionButtons(); RefreshMetrics(); SetWindowTextW(g_state.controls.execute, L"Execute Rename"); break;
                case IDC_MODE_COPY:
                    g_state.mode = L"copy"; RefreshSelectionButtons(); RefreshMetrics(); SetWindowTextW(g_state.controls.execute, L"Execute Copy"); break;
                case IDC_EXECUTE:
                    StartExecution(hwnd); break;
            }
            break;
        }
        case WM_DROPFILES:
            HandleDroppedFiles(reinterpret_cast<HDROP>(wParam));
            break;
        case WM_APP_PROGRESS: {
            std::unique_ptr<ProgressPayload> payload;
            {
                std::lock_guard<std::mutex> lock(g_state.workerMutex);
                payload = std::move(g_state.pendingProgress);
            }
            if (payload) {
                SendMessageW(g_state.controls.progress, PBM_SETRANGE32, 0, payload->total);
                SendMessageW(g_state.controls.progress, PBM_SETPOS, payload->completed, 0);
                SetStatus((g_state.mode == L"copy" ? L"Copying " : L"Renaming ") + std::to_wstring(payload->completed) + L"/" + std::to_wstring(payload->total) + L": " + payload->finalName);
            }
            break;
        }
        case WM_APP_DONE: {
            std::unique_ptr<RunResult> result;
            {
                std::lock_guard<std::mutex> lock(g_state.workerMutex);
                result = std::move(g_state.pendingResult);
            }
            if (result) {
                g_state.rows = std::move(result->rows);
                RefreshRows();
                SetWindowTextW(g_state.controls.output, result->outputPath.wstring().c_str());
                SetStatus(result->mode == L"copy" ? (L"Done. Copied " + std::to_wstring(g_state.rows.size()) + L" files.") : (L"Done. Renamed " + std::to_wstring(g_state.rows.size()) + L" files in place."));
            }
            SetRunning(false);
            break;
        }
        case WM_APP_ERROR: {
            std::unique_ptr<std::wstring> error;
            {
                std::lock_guard<std::mutex> lock(g_state.workerMutex);
                error = std::move(g_state.pendingError);
            }
            SetRunning(false);
            if (error) {
                SetStatus(*error);
                MessageBoxW(hwnd, error->c_str(), kAppTitle, MB_OK | MB_ICONERROR);
            }
            break;
        }
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}
} // namespace

int RunApplication(HINSTANCE instance, int showCommand) {
    INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_WIN95_CLASSES | ICC_PROGRESS_CLASS | ICC_LISTVIEW_CLASSES};
    InitCommonControlsEx(&icc);

    WNDCLASSW wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = instance;
    wc.lpszClassName = kWindowClass;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassW(&wc);

    HWND hwnd = CreateWindowExW(0, kWindowClass, kAppTitle, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 760, 740, nullptr, nullptr, instance, nullptr);
    if (!hwnd) return 0;

    ShowWindow(hwnd, showCommand);
    UpdateWindow(hwnd);

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return static_cast<int>(message.wParam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    return RunApplication(instance, showCommand);
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE, LPSTR, int showCommand) {
    return RunApplication(instance, showCommand);
}
