#!/usr/bin/env python3
"""Rename split WING WAV files from a WING .snap mapping."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

WAV_PATTERN = re.compile(r"^Channel-(\d+)\.wav$", re.IGNORECASE)
INVALID_FILENAME_CHARS = re.compile(r"[\\/:*?\"<>|]+")
SPACE_RUN = re.compile(r"\s+")
DEFAULT_UNNAMED = "UNNAMED"


class SnapError(Exception):
    """Raised when the snap structure is invalid for this tool."""


@dataclass
class WavEntry:
    path: Path
    original_name: str
    local_index: int


@dataclass
class ResolvedName:
    name: str
    status: str
    note: str


@dataclass
class RouteResolution:
    name: str
    source_ref: str
    descriptor: str
    append_descriptor_suffix: bool


@dataclass
class PlanRow:
    source_path: Path
    original_name: str
    local_index: int
    card: str
    absolute_slot: int
    mode: str
    resolved_name: str
    final_name: str
    status: str
    note: str
    target_path: Path


def scan_wavs(folder: Path) -> list[WavEntry]:
    if not folder.exists():
        raise FileNotFoundError(f"WAV folder does not exist: {folder}")
    if not folder.is_dir():
        raise NotADirectoryError(f"WAV path is not a folder: {folder}")

    matches: list[WavEntry] = []
    for entry in folder.iterdir():
        if not entry.is_file():
            continue
        match = WAV_PATTERN.match(entry.name)
        if not match:
            continue
        local_index = int(match.group(1))
        matches.append(WavEntry(path=entry, original_name=entry.name, local_index=local_index))

    matches.sort(key=lambda item: item.local_index)
    if not matches:
        raise FileNotFoundError(f"No matching files found in {folder}. Expected Channel-N.WAV files.")
    return matches


def _is_probable_data_root(obj: Any) -> bool:
    if not isinstance(obj, dict):
        return False
    return {"io", "ch"}.issubset(obj.keys())


def _extract_data_root(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise SnapError("Snap root is not a JSON object.")

    if "ae_data" in payload and isinstance(payload["ae_data"], dict):
        return payload["ae_data"]

    if _is_probable_data_root(payload):
        return payload

    for value in payload.values():
        if _is_probable_data_root(value):
            return value

    top_keys = ", ".join(sorted(payload.keys()))
    raise SnapError(
        "Could not find snap data root (expected ae_data or direct data object). "
        f"Top-level keys: {top_keys}"
    )


def load_snap(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"Snap file not found: {path}")
    if not path.is_file():
        raise FileNotFoundError(f"Snap path is not a file: {path}")

    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SnapError(f"Snap is not valid JSON: {exc}") from exc

    data_root = _extract_data_root(payload)
    required_paths = ["io.out.CRD", "ch"]
    missing: list[str] = []

    def has_path(root: dict[str, Any], dotted: str) -> bool:
        current: Any = root
        for key in dotted.split("."):
            if not isinstance(current, dict) or key not in current:
                return False
            current = current[key]
        return True

    for dotted in required_paths:
        if not has_path(data_root, dotted):
            missing.append(dotted)

    if missing:
        keys = ", ".join(sorted(data_root.keys()))
        raise SnapError(
            "Snap data root is missing required sections: "
            f"{', '.join(missing)}. Available root keys: {keys}"
        )

    return data_root


def to_absolute_slot(local_index: int, card: str) -> int:
    if local_index < 1:
        raise ValueError(f"Invalid local index: {local_index}")
    card_norm = card.upper()
    absolute_slot = local_index if card_norm == "A" else local_index + 32
    if not 1 <= absolute_slot <= 64:
        raise ValueError(
            f"Absolute slot out of range for local index {local_index} and card {card_norm}: {absolute_slot}"
        )
    return absolute_slot


def _string_name(value: Any) -> str:
    return value if isinstance(value, str) else ""


def sanitize_name(name: str) -> str:
    cleaned = INVALID_FILENAME_CHARS.sub(" ", name)
    cleaned = SPACE_RUN.sub(" ", cleaned).strip()
    return cleaned


def _name_from_group_container(container: Any, index: int) -> str:
    if not isinstance(container, dict):
        return ""
    node = container.get(str(index), {})
    if not isinstance(node, dict):
        return ""
    return sanitize_name(_string_name(node.get("name")))


def _numeric_nodes(container: Any) -> list[tuple[int, dict[str, Any]]]:
    if not isinstance(container, dict):
        return []
    nodes: list[tuple[int, dict[str, Any]]] = []
    for key, value in container.items():
        if not key.isdigit() or not isinstance(value, dict):
            continue
        nodes.append((int(key), value))
    nodes.sort(key=lambda item: item[0])
    return nodes


def _lane_to_logical_index(container: Any, lane_index: int) -> tuple[int | None, str]:
    """Map lane-based route index to a logical source index and stereo side label."""
    if lane_index < 1:
        return None, ""

    nodes = _numeric_nodes(container)
    if not nodes:
        return None, ""

    # Groups with busmono expose one logical node per bus, but routing indices
    # can be lane-based (L/R) for stereo buses.
    if all("busmono" in node for _idx, node in nodes):
        lane_cursor = 0
        for logical_idx, node in nodes:
            width = 1 if bool(node.get("busmono")) else 2
            lane_start = lane_cursor + 1
            lane_end = lane_cursor + width
            lane_cursor = lane_end
            if lane_start <= lane_index <= lane_end:
                if width == 2:
                    side = "L" if lane_index == lane_start else "R"
                    return logical_idx, side
                return logical_idx, ""
        return None, ""

    # Some groups use direct logical indexing (one entry per route index).
    return lane_index, ""


def _resolve_route_group_name(group: str, source_index: int, snap_root: dict[str, Any]) -> RouteResolution:
    io_in = snap_root.get("io", {}).get("in", {})
    if isinstance(io_in, dict) and group in io_in:
        name = _name_from_group_container(io_in.get(group), source_index)
        descriptor = f"{group} {source_index}"
        return RouteResolution(name=name, source_ref=f"{group}.{source_index}", descriptor=descriptor, append_descriptor_suffix=False)

    mix_group_map = {
        "MAIN": "main",
        "MTX": "mtx",
        "BUS": "bus",
        "DCA": "dca",
        "FX": "fx",
        "CH": "ch",
        "AUX": "aux",
        "PLAY": "play",
    }
    root_key = mix_group_map.get(group)
    if root_key is None:
        descriptor = f"{group} {source_index}"
        return RouteResolution(name="", source_ref=f"{group}.{source_index}", descriptor=descriptor, append_descriptor_suffix=False)

    container = snap_root.get(root_key)
    logical_index, side = _lane_to_logical_index(container, source_index)
    if logical_index is None:
        descriptor = f"{group} {source_index}"
        return RouteResolution(name="", source_ref=f"{group}.{source_index}", descriptor=descriptor, append_descriptor_suffix=True)

    name = _name_from_group_container(container, logical_index)
    descriptor = f"{group} {logical_index} {side}" if side else f"{group} {logical_index}"
    descriptor = sanitize_name(descriptor)
    if logical_index != source_index:
        source_ref = f"{group}.{source_index}->{root_key}.{logical_index}"
    else:
        source_ref = f"{group}.{source_index}"
    return RouteResolution(
        name=name,
        source_ref=source_ref,
        descriptor=descriptor,
        append_descriptor_suffix=True,
    )


def resolve_source_name(absolute_slot: int, snap_root: dict[str, Any]) -> ResolvedName:
    route = snap_root.get("io", {}).get("out", {}).get("CRD", {}).get(str(absolute_slot))
    if not isinstance(route, dict):
        return ResolvedName("", "UNRESOLVED", "missing CRD route")

    group = _string_name(route.get("grp")).upper().strip()
    source_index = route.get("in")
    if not isinstance(source_index, int):
        return ResolvedName("", "UNRESOLVED", f"slot {absolute_slot} has invalid route index")

    if group in {"", "OFF"}:
        return ResolvedName("", "UNRESOLVED", f"slot {absolute_slot} route is OFF")

    route = _resolve_route_group_name(group, source_index, snap_root)
    if route.name:
        final_name = route.name
        if route.append_descriptor_suffix:
            final_name = sanitize_name(f"{final_name} - {route.descriptor}")
        return ResolvedName(final_name, "OK", f"from {route.source_ref}")

    if route.descriptor:
        fallback = sanitize_name(route.descriptor)
        if fallback:
            return ResolvedName(fallback, "OK", f"{route.source_ref} name missing; used route descriptor")

    return ResolvedName("", "UNRESOLVED", f"{route.source_ref} label missing or unsupported")


def resolve_channel_name(absolute_slot: int, snap_root: dict[str, Any]) -> ResolvedName:
    channel = snap_root.get("ch", {}).get(str(absolute_slot), {})
    if not isinstance(channel, dict):
        return ResolvedName("", "UNRESOLVED", f"missing channel slot {absolute_slot}")

    channel_name = sanitize_name(_string_name(channel.get("name")))
    if not channel_name:
        return ResolvedName("", "UNRESOLVED", f"channel {absolute_slot} name missing")
    return ResolvedName(channel_name, "OK", "from channel strip")


def _build_final_name(absolute_slot: int, resolved_name: str) -> str:
    base_name = sanitize_name(resolved_name) or DEFAULT_UNNAMED
    return f"{absolute_slot:02d} {base_name}.WAV"


def build_plan(
    wav_entries: list[WavEntry],
    snap_root: dict[str, Any],
    card: str,
    mode: str,
    destination_dir: Path,
) -> list[PlanRow]:
    rows: list[PlanRow] = []
    mode_norm = mode.lower()

    for entry in wav_entries:
        absolute_slot = to_absolute_slot(entry.local_index, card)
        resolved = (
            resolve_source_name(absolute_slot, snap_root)
            if mode_norm == "source"
            else resolve_channel_name(absolute_slot, snap_root)
        )

        final_name = _build_final_name(absolute_slot, resolved.name)
        rows.append(
            PlanRow(
                source_path=entry.path,
                original_name=entry.original_name,
                local_index=entry.local_index,
                card=card.upper(),
                absolute_slot=absolute_slot,
                mode=mode_norm,
                resolved_name=resolved.name or DEFAULT_UNNAMED,
                final_name=final_name,
                status=resolved.status,
                note=resolved.note,
                target_path=destination_dir / final_name,
            )
        )

    resolve_collisions(rows, destination_dir)
    return rows


def resolve_collisions(rows: list[PlanRow], destination_dir: Path) -> None:
    used_targets: set[str] = set()

    for row in rows:
        stem = Path(row.final_name).stem
        suffix = Path(row.final_name).suffix
        candidate_name = row.final_name
        counter = 1
        adjusted = False

        while True:
            target_path = destination_dir / candidate_name
            key = str(target_path).lower()
            source_is_same_target = target_path.exists() and row.source_path.resolve() == target_path.resolve()

            conflict_in_batch = key in used_targets
            conflict_on_disk = target_path.exists() and not source_is_same_target

            if not conflict_in_batch and not conflict_on_disk:
                break

            counter += 1
            adjusted = True
            candidate_name = f"{stem} ({counter}){suffix}"

        row.final_name = candidate_name
        row.target_path = destination_dir / candidate_name
        if adjusted:
            suffix_note = f"collision adjusted to {candidate_name}"
            row.note = f"{row.note}; {suffix_note}" if row.note else suffix_note

        used_targets.add(str(row.target_path).lower())


def _format_cell(value: Any, width: int) -> str:
    text = str(value)
    if len(text) <= width:
        return text.ljust(width)
    if width <= 1:
        return text[:width]
    return text[: width - 1] + "…"


def render_preview(rows: list[PlanRow]) -> str:
    headers = [
        "Original",
        "Local",
        "Card",
        "Absolute",
        "Mode",
        "Resolved Name",
        "Final Filename",
        "Status",
        "Note",
    ]

    data_rows = [
        [
            row.original_name,
            row.local_index,
            row.card,
            row.absolute_slot,
            row.mode,
            row.resolved_name,
            row.final_name,
            row.status,
            row.note,
        ]
        for row in rows
    ]

    max_widths = [len(head) for head in headers]
    for row in data_rows:
        for idx, cell in enumerate(row):
            max_widths[idx] = min(max(max_widths[idx], len(str(cell))), 42)

    lines: list[str] = []
    header_line = " | ".join(_format_cell(headers[i], max_widths[i]) for i in range(len(headers)))
    separator = "-+-".join("-" * max_widths[i] for i in range(len(headers)))
    lines.append(header_line)
    lines.append(separator)

    for row in data_rows:
        lines.append(" | ".join(_format_cell(row[i], max_widths[i]) for i in range(len(headers))))

    ok_count = sum(1 for row in rows if row.status == "OK")
    unresolved_count = sum(1 for row in rows if row.status != "OK")
    collision_adjusted = sum(1 for row in rows if "collision adjusted" in row.note)
    lines.append("")
    lines.append(
        f"Summary: total={len(rows)} ok={ok_count} unresolved={unresolved_count} "
        f"collisions_adjusted={collision_adjusted}"
    )

    return "\n".join(lines)


def _require_confirmation() -> bool:
    answer = input("Apply file operations? Type 'yes' to continue: ").strip().lower()
    return answer == "yes"


def apply_plan(rows: list[PlanRow], operation: str, destination_dir: Path) -> None:
    op = operation.lower()
    if op == "preview":
        return

    if not _require_confirmation():
        print("Operation cancelled.")
        return

    if op == "copy":
        destination_dir.mkdir(parents=True, exist_ok=True)
        for row in rows:
            shutil.copy2(row.source_path, row.target_path)
        print(f"Copied {len(rows)} files to {destination_dir}")
        return

    if op == "rename":
        temp_rows: list[tuple[Path, Path, Path]] = []
        for index, row in enumerate(rows):
            source = row.source_path
            target = row.target_path
            if source.resolve() == target.resolve():
                continue
            temp_name = f".__wing_tmp__{uuid.uuid4().hex}__{index}.tmp"
            temp_path = source.parent / temp_name
            source.rename(temp_path)
            temp_rows.append((temp_path, source, target))

        try:
            for temp_path, _original, target in temp_rows:
                temp_path.rename(target)
        except Exception:
            for temp_path, original, _target in temp_rows:
                if temp_path.exists() and not original.exists():
                    temp_path.rename(original)
            raise

        print(f"Renamed {len(rows)} files in place at {destination_dir}")
        return

    raise ValueError(f"Unsupported operation mode: {operation}")


def _prompt_if_missing(value: str | None, label: str) -> str:
    if value is not None:
        return value
    return input(f"{label}: ").strip()


def _normalize_card(value: str) -> str:
    card = value.strip().upper()
    if card not in {"A", "B"}:
        raise ValueError("Card must be A or B")
    return card


def _normalize_mode(value: str) -> str:
    mode = value.strip().lower()
    if mode not in {"source", "channel"}:
        raise ValueError("Mode must be 'source' or 'channel'")
    return mode


def _normalize_operation(value: str) -> str:
    op = value.strip().lower()
    if op not in {"preview", "rename", "copy"}:
        raise ValueError("Operation must be 'preview', 'rename', or 'copy'")
    return op


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="WING Snap WAV Renamer")
    parser.add_argument("--wav-folder", help="Folder containing Channel-N.WAV files")
    parser.add_argument("--snap", help="Path to WING .snap file")
    parser.add_argument("--card", help="Card selection: A or B")
    parser.add_argument("--mode", help="Naming mode: source or channel")
    parser.add_argument("--op", help="Operation: preview, rename, copy")
    parser.add_argument("--out", help="Output folder for copy mode")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    try:
        wav_folder = Path(_prompt_if_missing(args.wav_folder, "WAV folder path")).expanduser()
        snap_path = Path(_prompt_if_missing(args.snap, "Snap file path")).expanduser()
        card = _normalize_card(_prompt_if_missing(args.card, "Card (A/B)"))
        mode = _normalize_mode(_prompt_if_missing(args.mode, "Naming mode (source/channel)"))
        operation = _normalize_operation(_prompt_if_missing(args.op, "Operation (preview/rename/copy)"))

        out_raw = args.out
        if operation == "copy":
            if out_raw is None:
                out_raw = input("Output folder for copies: ").strip()
            if not out_raw:
                raise ValueError("Output folder is required in copy mode")
            destination_dir = Path(out_raw).expanduser()
            if destination_dir.exists() and not destination_dir.is_dir():
                raise NotADirectoryError(f"Output path is not a folder: {destination_dir}")
        else:
            destination_dir = wav_folder

        wav_entries = scan_wavs(wav_folder)
        snap_root = load_snap(snap_path)
        rows = build_plan(
            wav_entries=wav_entries,
            snap_root=snap_root,
            card=card,
            mode=mode,
            destination_dir=destination_dir,
        )

        print(render_preview(rows))
        apply_plan(rows, operation, destination_dir)
        return 0
    except KeyboardInterrupt:
        print("\nCancelled.")
        return 130
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
