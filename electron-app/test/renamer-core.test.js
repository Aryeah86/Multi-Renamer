const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  applyPlan,
  buildPlan,
  loadSnap,
  makeTimestampedOutputFolder,
  scanWavs,
} = require('../src/renamer-core');

const fixturesDir = path.join(__dirname, 'fixtures');
const wavDir = path.join(fixturesDir, 'in');
const snapPath = path.join(fixturesDir, 'test.snap');

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'wing-electron-test-'));
}

test('scanWavs finds and numerically sorts Channel-N.WAV files', () => {
  const wavs = scanWavs(wavDir);
  assert.deepEqual(wavs.map((row) => row.localIndex), [1, 2, 10]);
  assert.deepEqual(wavs.map((row) => row.originalName), ['Channel-1.WAV', 'Channel-2.WAV', 'Channel-10.WAV']);
});

test('buildPlan resolves card A input names', () => {
  const wavs = scanWavs(wavDir);
  const snap = loadSnap(snapPath);
  const outDir = makeTempDir();
  const rows = buildPlan({ wavEntries: wavs.slice(0, 2), snapRoot: snap, card: 'A', destinationPath: outDir });

  assert.equal(rows[0].finalName, '01 BD IN.WAV');
  assert.equal(rows[1].finalName, '02 BD OUT.WAV');
  assert.equal(rows[0].status, 'OK');
});

test('buildPlan resolves stereo MAIN lanes and unnamed patched fallback', () => {
  const snap = loadSnap(snapPath);
  const wavEntries = [1, 2, 3, 4, 5].map((index) => ({
    sourcePath: path.join(wavDir, 'Channel-1.WAV'),
    originalName: `Channel-${index}.WAV`,
    localIndex: index,
  }));
  const outDir = makeTempDir();
  const rows = buildPlan({ wavEntries, snapRoot: snap, card: 'B', destinationPath: outDir });

  assert.equal(rows[0].finalName, '33 DRUMS - MAIN 1 L.WAV');
  assert.equal(rows[1].finalName, '34 DRUMS - MAIN 1 R.WAV');
  assert.equal(rows[2].finalName, '35 STRINGS - MAIN 2 L.WAV');
  assert.equal(rows[3].finalName, '36 STRINGS - MAIN 2 R.WAV');
  assert.equal(rows[4].finalName, '37 UNNAMED.WAV');
  assert.match(rows[4].note, /OFF/);
});

test('copy mode creates renamed files', () => {
  const snap = loadSnap(snapPath);
  const sourceDir = makeTempDir();
  fs.copyFileSync(path.join(wavDir, 'Channel-1.WAV'), path.join(sourceDir, 'Channel-1.WAV'));
  const destination = makeTimestampedOutputFolder(sourceDir, 'A');
  const rows = buildPlan({ wavEntries: scanWavs(sourceDir), snapRoot: snap, card: 'A', destinationPath: destination });

  applyPlan({ rows, operation: 'copy', onProgress: () => {} });

  assert.ok(fs.existsSync(path.join(destination, '01 BD IN.WAV')));
  assert.ok(fs.existsSync(path.join(sourceDir, 'Channel-1.WAV')));
});

test('rename mode renames files in place', () => {
  const snap = loadSnap(snapPath);
  const sourceDir = makeTempDir();
  fs.copyFileSync(path.join(wavDir, 'Channel-1.WAV'), path.join(sourceDir, 'Channel-1.WAV'));
  const rows = buildPlan({ wavEntries: scanWavs(sourceDir), snapRoot: snap, card: 'A', destinationPath: sourceDir });

  applyPlan({ rows, operation: 'rename', onProgress: () => {} });

  assert.ok(fs.existsSync(path.join(sourceDir, '01 BD IN.WAV')));
  assert.ok(!fs.existsSync(path.join(sourceDir, 'Channel-1.WAV')));
});
