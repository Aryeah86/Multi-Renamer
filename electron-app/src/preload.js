const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('wingRenamer', {
  chooseFolder: (startingPath) => ipcRenderer.invoke('dialog:choose-folder', startingPath),
  chooseSnap: (startingPath) => ipcRenderer.invoke('dialog:choose-snap', startingPath),
  classifyPath: (targetPath) => ipcRenderer.invoke('path:classify', targetPath),
  execute: (payload) => ipcRenderer.invoke('renamer:execute', payload),
  onProgress: (handler) => {
    const listener = (_, payload) => handler(payload);
    ipcRenderer.on('renamer:progress', listener);
    return () => ipcRenderer.removeListener('renamer:progress', listener);
  },
});
