const fs = require('fs');
const path = require('path');

const INVALID_NAME_PATTERN = /[\\/:*?"<>|]/g;
const WAV_PATTERN = /^Channel-(\d+)\.wav$/i;
const DEFAULT_UNNAMED = 'UNNAMED';

class RenamerError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RenamerError';
  }
}

function ensureFolderPath(folderPath) {
  if (!folderPath) {
    throw new RenamerError('Please choose a multitrack folder.');
  }
  const stat = safeStat(folderPath);
  if (!stat) {
    throw new RenamerError(`WAV folder does not exist: ${folderPath}`);
  }
  if (!stat.isDirectory()) {
    throw new RenamerError(`WAV path is not a folder: ${folderPath}`);
  }
  return folderPath;
}

function ensureSnapPath(snapPath) {
  if (!snapPath) {
    throw new RenamerError('Please choose a snap file.');
  }
  const stat = safeStat(snapPath);
  if (!stat) {
    throw new RenamerError(`Snap file not found: ${snapPath}`);
  }
  if (!stat.isFile()) {
    throw new RenamerError(`Snap path is not a file: ${snapPath}`);
  }
  return snapPath;
}

function safeStat(targetPath) {
  try {
    return fs.statSync(targetPath);
  } catch {
    return null;
  }
}

function scanWavs(folderPath) {
  ensureFolderPath(folderPath);
  const entries = fs.readdirSync(folderPath, { withFileTypes: true });
  const wavs = entries
    .filter((entry) => entry.isFile())
    .map((entry) => {
      const match = entry.name.match(WAV_PATTERN);
      if (!match) {
        return null;
      }
      return {
        sourcePath: path.join(folderPath, entry.name),
        originalName: entry.name,
        localIndex: Number.parseInt(match[1], 10),
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.localIndex - right.localIndex);

  if (wavs.length === 0) {
    throw new RenamerError(`No matching files found in ${folderPath}. Expected Channel-N.WAV files.`);
  }
  return wavs;
}

function loadSnap(snapPath) {
  ensureSnapPath(snapPath);
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(snapPath, 'utf8'));
  } catch (error) {
    throw new RenamerError(`Snap is not valid JSON: ${error.message}`);
  }

  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new RenamerError('Snap root is not a JSON object.');
  }

  if (isProbableDataRoot(payload.ae_data)) {
    return payload.ae_data;
  }
  if (isProbableDataRoot(payload)) {
    return payload;
  }
  for (const value of Object.values(payload)) {
    if (isProbableDataRoot(value)) {
      return value;
    }
  }

  throw new RenamerError(
    `Could not find snap data root (expected ae_data or direct data object). Top-level keys: ${Object.keys(payload).sort().join(', ')}`
  );
}

function isProbableDataRoot(value) {
  return Boolean(value && typeof value === 'object' && value.io && value.ch);
}

function buildPlan({ wavEntries, snapRoot, card, destinationPath }) {
  const usedTargets = new Set();
  return wavEntries.map((entry) => {
    const absoluteSlot = toAbsoluteSlot(entry.localIndex, card);
    const resolved = resolveSourceName(absoluteSlot, snapRoot);
    const preferredName = buildFinalFileName(absoluteSlot, resolved.name);
    const finalName = resolveCollisionName({
      preferredName,
      destinationPath,
      sourcePath: entry.sourcePath,
      usedTargets,
    });

    return {
      sourcePath: entry.sourcePath,
      originalName: entry.originalName,
      localIndex: entry.localIndex,
      card,
      absoluteSlot,
      resolvedName: resolved.name || DEFAULT_UNNAMED,
      finalName,
      status: resolved.status,
      note: resolved.note,
      targetPath: path.join(destinationPath, finalName),
    };
  });
}

function applyPlan({ rows, operation, onProgress }) {
  if (operation === 'copy') {
    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      fs.copyFileSync(row.sourcePath, row.targetPath);
      onProgress({ completed: index + 1, total: rows.length, finalName: row.finalName });
    }
    return;
  }

  const staged = [];
  try {
    for (const row of rows) {
      if (path.resolve(row.sourcePath) === path.resolve(row.targetPath)) {
        continue;
      }
      const tempPath = path.join(path.dirname(row.sourcePath), `.__wing_tmp__${Math.random().toString(16).slice(2)}.tmp`);
      fs.renameSync(row.sourcePath, tempPath);
      staged.push({ tempPath, originalPath: row.sourcePath, targetPath: row.targetPath, finalName: row.finalName });
    }

    for (let index = 0; index < staged.length; index += 1) {
      const item = staged[index];
      fs.renameSync(item.tempPath, item.targetPath);
      onProgress({ completed: index + 1, total: staged.length, finalName: item.finalName });
    }
  } catch (error) {
    for (const item of staged) {
      if (fs.existsSync(item.tempPath) && !fs.existsSync(item.originalPath)) {
        try {
          fs.renameSync(item.tempPath, item.originalPath);
        } catch {
          // best effort rollback
        }
      }
    }
    throw error;
  }
}

function makeTimestampedOutputFolder(baseFolder, card) {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, '').replace('T', '_');
  const destinationPath = path.join(baseFolder, `copy_card_${card.toLowerCase()}_${stamp}`);
  if (fs.existsSync(destinationPath)) {
    throw new RenamerError(`Output folder already exists: ${destinationPath}`);
  }
  fs.mkdirSync(destinationPath);
  return destinationPath;
}

function toAbsoluteSlot(localIndex, card) {
  const slot = card === 'A' ? localIndex : localIndex + 32;
  if (slot < 1 || slot > 64) {
    throw new RenamerError(`Absolute slot out of range: ${slot}`);
  }
  return slot;
}

function resolveSourceName(absoluteSlot, snapRoot) {
  const route = nestedDict(snapRoot, ['io', 'out', 'CRD', String(absoluteSlot)]);
  if (!route) {
    return { name: '', status: 'UNRESOLVED', note: 'missing CRD route' };
  }

  const group = String(route.grp || '').trim().toUpperCase();
  const sourceIndex = typeof route.in === 'number' ? route.in : Number.parseInt(String(route.in || ''), 10);
  if (!Number.isInteger(sourceIndex)) {
    return { name: '', status: 'UNRESOLVED', note: `slot ${absoluteSlot} has invalid route index` };
  }
  if (!group || group === 'OFF') {
    return { name: '', status: 'UNRESOLVED', note: `slot ${absoluteSlot} route is OFF` };
  }

  const resolution = resolveRouteGroupName(group, sourceIndex, snapRoot);
  if (resolution.name) {
    const finalName = resolution.appendDescriptorSuffix
      ? sanitizeName(`${resolution.name} - ${resolution.descriptor}`)
      : resolution.name;
    return { name: finalName, status: 'OK', note: `from ${resolution.sourceRef}` };
  }

  if (resolution.descriptor) {
    return {
      name: sanitizeName(resolution.descriptor),
      status: 'OK',
      note: `${resolution.sourceRef} name missing; used route descriptor`,
    };
  }

  return { name: '', status: 'UNRESOLVED', note: `${resolution.sourceRef} label missing or unsupported` };
}

function resolveRouteGroupName(group, sourceIndex, snapRoot) {
  const ioIn = nestedDict(snapRoot, ['io', 'in']);
  if (ioIn && ioIn[group] && typeof ioIn[group] === 'object') {
    return {
      name: nameFromGroupContainer(ioIn[group], sourceIndex),
      sourceRef: `${group}.${sourceIndex}`,
      descriptor: `${group} ${sourceIndex}`,
      appendDescriptorSuffix: false,
    };
  }

  const rootKeyMap = {
    MAIN: 'main',
    MTX: 'mtx',
    BUS: 'bus',
    DCA: 'dca',
    FX: 'fx',
    CH: 'ch',
    AUX: 'aux',
    PLAY: 'play',
  };
  const rootKey = rootKeyMap[group];
  const container = rootKey ? snapRoot[rootKey] : null;
  if (!rootKey || !container || typeof container !== 'object') {
    return {
      name: '',
      sourceRef: `${group}.${sourceIndex}`,
      descriptor: `${group} ${sourceIndex}`,
      appendDescriptorSuffix: false,
    };
  }

  const lane = laneToLogicalIndex(container, sourceIndex);
  if (!lane.logicalIndex) {
    return {
      name: '',
      sourceRef: `${group}.${sourceIndex}`,
      descriptor: `${group} ${sourceIndex}`,
      appendDescriptorSuffix: true,
    };
  }

  const name = nameFromGroupContainer(container, lane.logicalIndex);
  const descriptor = lane.side ? `${group} ${lane.logicalIndex} ${lane.side}` : `${group} ${lane.logicalIndex}`;
  const sourceRef = lane.logicalIndex === sourceIndex
    ? `${group}.${sourceIndex}`
    : `${group}.${sourceIndex}->${rootKey}.${lane.logicalIndex}`;

  return {
    name,
    sourceRef,
    descriptor: sanitizeName(descriptor),
    appendDescriptorSuffix: true,
  };
}

function nameFromGroupContainer(container, index) {
  const node = container[String(index)];
  if (!node || typeof node !== 'object') {
    return '';
  }
  return sanitizeName(String(node.name || ''));
}

function sanitizeName(raw) {
  return String(raw || '')
    .replace(INVALID_NAME_PATTERN, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function buildFinalFileName(slot, resolvedName) {
  const base = sanitizeName(resolvedName) || DEFAULT_UNNAMED;
  return `${String(slot).padStart(2, '0')} ${base}.WAV`;
}

function resolveCollisionName({ preferredName, destinationPath, sourcePath, usedTargets }) {
  const extension = path.extname(preferredName);
  const stem = preferredName.slice(0, -extension.length);
  let candidate = preferredName;
  let counter = 1;

  while (true) {
    const candidatePath = path.join(destinationPath, candidate);
    const candidateKey = candidatePath.toLowerCase();
    const sameAsSource = path.resolve(candidatePath) === path.resolve(sourcePath);
    const conflictInBatch = usedTargets.has(candidateKey);
    const conflictOnDisk = fs.existsSync(candidatePath) && !sameAsSource;

    if (!conflictInBatch && !conflictOnDisk) {
      usedTargets.add(candidateKey);
      return candidate;
    }

    counter += 1;
    candidate = `${stem} (${counter})${extension}`;
  }
}

function nestedDict(root, keys) {
  let current = root;
  for (const key of keys) {
    if (!current || typeof current !== 'object' || Array.isArray(current) || !(key in current)) {
      return null;
    }
    current = current[key];
  }
  return current && typeof current === 'object' && !Array.isArray(current) ? current : null;
}

function laneToLogicalIndex(container, laneIndex) {
  if (laneIndex <= 0) {
    return { logicalIndex: null, side: '' };
  }

  const numericNodes = Object.entries(container)
    .map(([key, value]) => {
      const numericKey = Number.parseInt(key, 10);
      if (!Number.isInteger(numericKey) || !value || typeof value !== 'object') {
        return null;
      }
      return [numericKey, value];
    })
    .filter(Boolean)
    .sort((left, right) => left[0] - right[0]);

  if (numericNodes.length === 0) {
    return { logicalIndex: null, side: '' };
  }

  const allHaveBusMono = numericNodes.every(([, value]) => Object.prototype.hasOwnProperty.call(value, 'busmono'));
  if (!allHaveBusMono) {
    return { logicalIndex: laneIndex, side: '' };
  }

  let laneCursor = 0;
  for (const [logicalIndex, value] of numericNodes) {
    const width = value.busmono ? 1 : 2;
    const start = laneCursor + 1;
    const end = laneCursor + width;
    laneCursor = end;
    if (laneIndex >= start && laneIndex <= end) {
      if (width === 2) {
        return { logicalIndex, side: laneIndex === start ? 'L' : 'R' };
      }
      return { logicalIndex, side: '' };
    }
  }

  return { logicalIndex: null, side: '' };
}

module.exports = {
  RenamerError,
  applyPlan,
  buildPlan,
  ensureFolderPath,
  ensureSnapPath,
  loadSnap,
  makeTimestampedOutputFolder,
  scanWavs,
};
