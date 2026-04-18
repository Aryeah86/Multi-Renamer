# WING Snap WAV Renamer — Codex Instructions

## Task
Build a small desktop script/app that renames already-extracted WAV files based on names found in a Behringer WING `.snap` file.

This tool does **not** extract audio and does **not** split multichannel WAV files.
It only renames existing files such as:

- `Channel-1.WAV`
- `Channel-2.WAV`
- ...

into names such as:

- `01 BD IN.WAV`
- `02 SNR TOP.WAV`
- or for Card B:
- `33 OH L.WAV`
- `34 OH R.WAV`

---

## Main Goal
Given:
1. a folder containing already split WAV files named `Channel-N.WAV`
2. the relevant WING `.snap` file
3. the user choice of **Card A** or **Card B**
4. the user choice of **Source names** or **Channel names**

Rename the files using the correct names from the snap.

---

## Core Rule: Card A vs Card B
The app/script must ask:

**Is this Card A or Card B?**

This matters because:
- **Card A** represents record slots **1–32**
- **Card B** represents record slots **33–64**

So:
- Card A + `Channel-1.WAV` => absolute slot `1`
- Card A + `Channel-2.WAV` => absolute slot `2`
- Card B + `Channel-1.WAV` => absolute slot `33`
- Card B + `Channel-2.WAV` => absolute slot `34`

### Required mapping formula
- If Card A: `absolute_slot = local_index`
- If Card B: `absolute_slot = local_index + 32`

Where:
- `local_index` is the number extracted from `Channel-N.WAV`
- `absolute_slot` is the real WING recording slot used for lookup and output naming

This absolute slot must be used for:
- lookup in the snap
- output filename prefix

Do **not** use the local file number for final naming when Card B is selected.

Example:
- Input file: `Channel-1.WAV`
- Card selected: `B`
- Resolved name: `OH L`
- Final file name: `33 OH L.WAV`

---

## Naming Modes
The tool must support **two naming modes**.

### 1. Source-name mode
Rename according to the **actual recorded source** assigned to the WING card recording output.

This is the preferred / more correct mode when recording is routed by source.

Flow:
1. Compute `absolute_slot`
2. Read the card routing for that slot from the snap
3. Resolve the source group + source index
4. Resolve the source name
5. Rename using that source name

Example intent:
- slot `33` may point to a specific source
- source label might be `OH L`
- output becomes `33 OH L.WAV`

### 2. Channel-name mode
Rename according to the channel strip name.

Use this when the intended naming is based on channel strips instead of the actual routed source.

Flow:
1. Compute `absolute_slot`
2. Resolve the matching channel name
3. Rename using that channel name

Example:
- channel 1 name = `BD IN`
- output becomes `01 BD IN.WAV`

---

## Required User Prompts / Inputs
The tool must ask for or accept:

1. **Path to the folder containing the WAV files**
2. **Path to the WING `.snap` file**
3. **Card selection**
   - `A`
   - `B`
4. **Naming mode**
   - `source`
   - `channel`
5. **Operation mode**
   - preview only / dry run
   - rename in place
   - copy to a new output folder

Optional:
6. **Custom output folder** (only if using copy mode)

---

## File Matching Rules
Only target files matching this pattern:

- `Channel-1.WAV`
- `Channel-2.WAV`
- `Channel-12.WAV`

Pattern should be case-insensitive regarding extension.

Do not rename unrelated files.

Sort files numerically by extracted channel number.

Examples:
- `Channel-2.WAV` should come before `Channel-10.WAV`

---

## Output Filename Format
Final filenames must use:

`<absolute_slot zero-padded to 2 digits> <resolved_name>.WAV`

Examples:
- `01 BD IN.WAV`
- `02 SNR TOP.WAV`
- `09 TOM 1.WAV`
- `33 OH L.WAV`
- `64 FX PRINT.WAV`

### Important
Use the **absolute slot number**, not the local extracted file number.

So for Card B:
- `Channel-1.WAV` => `33 ...`
- not `01 ...`

---

## Name Resolution Strategy
Implement both modes, but design the resolution layer cleanly so it can inspect the snap structure robustly.

### A. Source-name mode resolution
Use the absolute card recording slot to resolve the actual recorded source.

Conceptually:
1. Find the recording/card output entry for the absolute slot
2. Read its assigned group / source routing info
3. Resolve the matching source object
4. Read the source name

If source-name mode is selected, the script must try to use the **actual source label**, not the channel label.

### B. Channel-name mode resolution
Resolve the name from the channel object.

If channel-name mode is selected, the script must use the relevant channel strip name.

---

## Snap Parsing Requirements
The `.snap` parser must be robust and defensive.

Requirements:
- Load the file safely
- Detect whether the content is:
  - direct JSON-like object
  - wrapped object with a parent key such as `ae_data`
  - other simple wrapper layouts
- Print / log the top-level keys in debug mode if parsing fails
- Fail clearly and specifically if the expected structure cannot be found

Do not hardcode only one wrapper layout if that can be avoided.

---

## Rename Safety Rules
The tool must never rename blindly.

### Required behavior
Before applying any rename:
- build a preview table
- show:
  - original file name
  - local index
  - selected card
  - absolute slot
  - resolved mode (`source` / `channel`)
  - resolved name
  - final filename
  - confidence / notes if relevant

Then only rename when the user confirms.

---

## Fallback Behavior
If a valid name cannot be resolved:

### Preferred fallback
- `01 UNNAMED.WAV`
- `33 UNNAMED.WAV`

Alternative acceptable fallback:
- keep original file name unchanged in preview and mark as unresolved

But do not silently invent incorrect names.

If the route is partially resolved, include a note in preview.

Examples:
- `33 UNNAMED (missing source label)`
- or preview note: `slot resolved, name missing`

---

## Duplicate Name Handling
Duplicate human names are expected.

Because the numeric prefix is always included, these are valid and should not necessarily be treated as collisions:
- `01 TOM 1.WAV`
- `02 TOM 1.WAV`

That is acceptable.

However, if the exact same full output filename would be produced twice in the same folder, handle it safely.

Safe collision strategy:
- append ` (2)`, ` (3)` only when absolutely necessary

---

## Filename Sanitization
Resolved names must be sanitized for filesystem safety.

Required cleanup:
- remove or replace invalid filename characters
- trim leading/trailing spaces
- collapse repeated spaces
- preserve readable capitalization as found in the snap if possible

Do not over-normalize the names.

Example:
- `SNR/TOP` => `SNR TOP`
- `  BD IN  ` => `BD IN`

---

## Scope Limits
This tool should **not**:
- extract WAVs from WING media
- split poly WAV files
- edit audio content
- alter metadata inside the WAV
- rewrite the WING snap
- assume the recording is always 1:1 with channel strips

This is a **renamer only**.

---

## Suggested UX
A minimal simple UX is enough.

Either of these is acceptable:
- command-line script
- small desktop utility

If desktop utility:
- keep it very simple
- file picker for snap file
- folder picker for audio folder
- card A/B selector
- naming mode selector
- preview table
- apply button

No need for a complex UI.

---

## Recommended Internal Architecture
Use a small modular structure.

### 1. File scanner
Responsible for:
- finding matching `Channel-N.WAV` files
- extracting numeric indices
- sorting them correctly

### 2. Snap loader
Responsible for:
- loading `.snap`
- detecting wrapper structure
- exposing the relevant data root

### 3. Name resolver
Responsible for:
- converting local index -> absolute slot based on selected card
- resolving names in `source` mode
- resolving names in `channel` mode
- returning:
  - resolved name
  - notes
  - confidence / status

### 4. Rename planner
Responsible for:
- building the preview rows
- generating final target names
- checking collisions
- applying rename or copy

This separation is important.

---

## Preview Table Fields
At minimum, each preview row should contain:

- original filename
- local index
- card selection
- absolute slot
- naming mode
- resolved name
- final filename
- status

Example row:

| Original | Local | Card | Absolute | Mode | Resolved Name | Final Filename | Status |
|---|---:|---|---:|---|---|---|---|
| Channel-1.WAV | 1 | B | 33 | source | OH L | 33 OH L.WAV | OK |

---

## Error Handling
Handle these clearly:

### Snap-related
- snap file cannot be opened
- snap file is invalid / unsupported
- required keys not found
- expected routing data missing

### File-related
- no `Channel-N.WAV` files found
- destination filename already exists
- insufficient permissions
- output folder invalid

### Mapping-related
- absolute slot out of range
- source/channel name missing
- mode selected but no valid mapping available

Errors must be explicit and practical.

---

## Acceptance Criteria
The task is complete when all of these work:

### A. Card A basic test
Input files:
- `Channel-1.WAV`
- `Channel-2.WAV`

Card selected:
- `A`

Resolved names:
- `BD IN`
- `SNR TOP`

Output:
- `01 BD IN.WAV`
- `02 SNR TOP.WAV`

### B. Card B basic test
Input files:
- `Channel-1.WAV`
- `Channel-2.WAV`

Card selected:
- `B`

Resolved names:
- `OH L`
- `OH R`

Output:
- `33 OH L.WAV`
- `34 OH R.WAV`

### C. Preview mode
The script can show the rename plan without renaming anything.

### D. Copy mode
The script can create renamed copies into a new folder without touching originals.

### E. Missing names
If a name cannot be resolved, the result is flagged clearly and handled safely.

---

## Implementation Notes for Codex
- Keep the code small and readable
- Prioritize correctness over feature creep
- Build the name resolution logic cleanly so structure inspection is easy
- Add helpful logging for snap traversal
- Avoid assumptions that only work for one snap layout unless confirmed
- Do not implement unrelated extra features

---

## Development Order
1. Build WAV file scanner and numeric sorting
2. Build card A/B absolute-slot conversion
3. Build snap loader with wrapper detection
4. Build source-name resolution
5. Build channel-name resolution
6. Build preview table
7. Add rename-in-place mode
8. Add copy mode
9. Test with real Card A and Card B cases

---

## Final Summary
Build a small WING snap-based WAV renamer with these defining rules:

- it only renames existing split WAV files
- it must ask whether the files came from **Card A** or **Card B**
- Card A means slots **1–32**
- Card B means slots **33–64**
- it must support naming by **source** or by **channel**
- final filenames must use the **absolute WING slot number**
- it must always show a safe preview before applying changes
