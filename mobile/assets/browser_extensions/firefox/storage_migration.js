// Firefox sync storage limits are too small for the app rule payload.
globalThis.ffFirefoxLocalStorageReady=(async()=>{const local=await chrome.storage.local.get(null);if(local.ffFirefoxLocalStorageV1)return;const old=await chrome.storage.sync.get(null);await chrome.storage.local.set({...old,...local,ffFirefoxLocalStorageV1:Date.now()});})();
