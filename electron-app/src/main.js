const { app, BrowserWindow, dialog, ipcMain } = require('electron');
const path = require('path');
const {
  buildPlan,
  applyPlan,
  ensureFolderPath,
  ensureSnapPath,
  makeTimestampedOutputFolder,
  scanWavs,
  loadSnap,
} = require('./renamer-core');

let mainWindow = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 880,
    height: 760,
    minWidth: 880,
    minHeight: 760,
    backgroundColor: '#121212',
    title: 'Wing Multitrack Renamer',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

ipcMain.handle('dialog:choose-folder', async (_, startingPath) => {
  const defaultPath = startingPath && startingPath.length ? startingPath : app.getPath('home');
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openDirectory'],
    defaultPath,
    title: 'Choose Multitrack Folder',
  });
  if (result.canceled || result.filePaths.length === 0) {
    return null;
  }
  return result.filePaths[0];
});

ipcMain.handle('dialog:choose-snap', async (_, startingPath) => {
  const defaultPath = startingPath && startingPath.length ? startingPath : app.getPath('home');
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile'],
    defaultPath,
    title: 'Choose Snap File',
    filters: [
      { name: 'Snap Files', extensions: ['snap'] },
      { name: 'JSON Files', extensions: ['json'] },
      { name: 'All Files', extensions: ['*'] },
    ],
  });
  if (result.canceled || result.filePaths.length === 0) {
    return null;
  }
  return result.filePaths[0];
});

ipcMain.handle('path:classify', async (_, targetPath) => {
  if (!targetPath || typeof targetPath !== 'string') {
    return null;
  }

  try {
    const stats = require('fs').statSync(targetPath);
    return {
      exists: true,
      isDirectory: stats.isDirectory(),
      isFile: stats.isFile(),
      extension: path.extname(targetPath).toLowerCase(),
    };
  } catch {
    return {
      exists: false,
      isDirectory: false,
      isFile: false,
      extension: path.extname(targetPath).toLowerCase(),
    };
  }
});

ipcMain.handle('renamer:execute', async (_, payload) => {
  const folderPath = ensureFolderPath(payload.folderPath);
  const snapPath = ensureSnapPath(payload.snapPath);
  const card = payload.card === 'A' ? 'A' : 'B';
  const operation = payload.operation === 'copy' ? 'copy' : 'rename';

  const folderUrl = folderPath;
  const snapRoot = loadSnap(snapPath);
  const wavEntries = scanWavs(folderUrl);
  const destinationPath = operation === 'copy'
    ? makeTimestampedOutputFolder(folderPath, card)
    : folderPath;

  const rows = buildPlan({
    wavEntries,
    snapRoot,
    card,
    destinationPath,
  });

  let completed = 0;
  const progressEvents = [];
  applyPlan({
    rows,
    operation,
    onProgress: ({ finalName }) => {
      completed += 1;
      const event = {
        completed,
        total: rows.length,
        finalName,
      };
      progressEvents.push(event);
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('renamer:progress', event);
      }
    },
  });

  return {
    rows,
    destinationPath,
    operation,
    progressEvents,
  };
});
