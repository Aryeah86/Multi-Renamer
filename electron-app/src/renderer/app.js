const state = {
  folderPath: '',
  snapPath: '',
  card: 'A',
  operation: 'rename',
  rows: [],
  isRunning: false,
};

const folderPanel = document.getElementById('folderPanel');
const snapPanel = document.getElementById('snapPanel');
const folderPrimary = document.getElementById('folderPrimary');
const folderSecondary = document.getElementById('folderSecondary');
const snapPrimary = document.getElementById('snapPrimary');
const snapSecondary = document.getElementById('snapSecondary');
const executeButton = document.getElementById('executeButton');
const statusText = document.getElementById('statusText');
const statusFlag = document.getElementById('statusFlag');
const progressBar = document.getElementById('progressBar');
const rowsMetric = document.getElementById('rowsMetric');
const cardMetric = document.getElementById('cardMetric');
const modeMetric = document.getElementById('modeMetric');
const outputPath = document.getElementById('outputPath');
const rowsBody = document.getElementById('rowsBody');

function basename(filePath) {
  return filePath.split(/[\\/]/).pop();
}

function render() {
  folderPrimary.textContent = state.folderPath ? basename(state.folderPath) : 'Select multitrack folder';
  folderSecondary.textContent = state.folderPath || 'Browse or drop the WAV folder here';
  snapPrimary.textContent = state.snapPath ? basename(state.snapPath) : 'Select snap reference';
  snapSecondary.textContent = state.snapPath || 'Browse or drop a .snap file here';
  executeButton.textContent = state.operation === 'copy' ? 'Execute Copy' : 'Execute Rename';
  executeButton.disabled = state.isRunning;
  statusFlag.textContent = state.isRunning ? 'ACTIVE' : 'IDLE';
  rowsMetric.textContent = String(state.rows.length);
  cardMetric.textContent = state.card;
  modeMetric.textContent = state.operation.toUpperCase();

  document.querySelectorAll('[data-card]').forEach((button) => {
    button.classList.toggle('active', button.dataset.card === state.card);
  });
  document.querySelectorAll('[data-mode]').forEach((button) => {
    button.classList.toggle('active', button.dataset.mode === state.operation);
  });

  if (state.rows.length === 0) {
    rowsBody.innerHTML = '<tr class="placeholder"><td colspan="4">Run a rename or copy operation to preview the resulting filenames.</td></tr>';
    return;
  }

  rowsBody.innerHTML = state.rows.slice(0, 24).map((row) => {
    const stateClass = row.status === 'OK' ? 'state-ok' : 'state-unresolved';
    return `
      <tr>
        <td title="${row.originalName}">${row.originalName}</td>
        <td>${row.absoluteSlot}</td>
        <td title="${row.finalName}">${row.finalName}</td>
        <td class="${stateClass}" title="${row.note}">${row.status}</td>
      </tr>
    `;
  }).join('');
}

async function chooseFolder() {
  const selected = await window.wingRenamer.chooseFolder(state.folderPath);
  if (selected) {
    state.folderPath = selected;
    render();
  }
}

async function chooseSnap() {
  const selected = await window.wingRenamer.chooseSnap(state.snapPath || state.folderPath);
  if (selected) {
    state.snapPath = selected;
    render();
  }
}

function setDropTarget(element, active) {
  element.classList.toggle('drop-target', active);
}

function wireDropTarget(element, accept) {
  ['dragenter', 'dragover'].forEach((eventName) => {
    element.addEventListener(eventName, (event) => {
      event.preventDefault();
      setDropTarget(element, true);
    });
  });

  ['dragleave', 'dragend', 'drop'].forEach((eventName) => {
    element.addEventListener(eventName, () => setDropTarget(element, false));
  });

  element.addEventListener('drop', async (event) => {
    event.preventDefault();
    const files = Array.from(event.dataTransfer?.files || []);
    let match = null;
    for (const file of files) {
      const classification = await window.wingRenamer.classifyPath(file.path);
      if (accept(file, classification)) {
        match = file;
        break;
      }
    }
    if (!match) {
      return;
    }
    if (element === folderPanel) {
      state.folderPath = match.path;
    } else {
      state.snapPath = match.path;
    }
    render();
  });
}

async function execute() {
  state.isRunning = true;
  state.rows = [];
  progressBar.value = 0;
  progressBar.max = 1;
  outputPath.textContent = '';
  statusText.textContent = 'Building rename plan...';
  render();

  try {
    const result = await window.wingRenamer.execute({
      folderPath: state.folderPath,
      snapPath: state.snapPath,
      card: state.card,
      operation: state.operation,
    });
    state.rows = result.rows;
    outputPath.textContent = `${state.operation === 'copy' ? 'OUTPUT' : 'TARGET'} ${result.destinationPath}`;
    statusText.textContent = result.operation === 'copy'
      ? `Done. Copied ${result.rows.length} files.`
      : `Done. Renamed ${result.rows.length} files in place.`;
  } catch (error) {
    statusText.textContent = error.message || String(error);
  } finally {
    state.isRunning = false;
    render();
  }
}

folderPanel.addEventListener('click', chooseFolder);
snapPanel.addEventListener('click', chooseSnap);
executeButton.addEventListener('click', execute);

document.querySelectorAll('[data-card]').forEach((button) => {
  button.addEventListener('click', () => {
    state.card = button.dataset.card;
    render();
  });
});

document.querySelectorAll('[data-mode]').forEach((button) => {
  button.addEventListener('click', () => {
    state.operation = button.dataset.mode;
    render();
  });
});

wireDropTarget(folderPanel, (_file, classification) => Boolean(classification?.isDirectory));
wireDropTarget(
  snapPanel,
  (_file, classification) => Boolean(classification?.isFile && classification.extension === '.snap')
);

window.wingRenamer.onProgress((event) => {
  progressBar.max = event.total || 1;
  progressBar.value = event.completed || 0;
  statusText.textContent = `${state.operation === 'copy' ? 'Copying' : 'Renaming'} ${event.completed}/${event.total}: ${event.finalName}`;
});

render();
