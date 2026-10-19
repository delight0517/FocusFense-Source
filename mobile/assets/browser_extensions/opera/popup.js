/**
 * Chat command popup — talks to the already-running 6 VPN Blocker app over
 * its loopback rules API (same port background.js polls for /rules).
 * Reuses the app's existing preview -> confirm chat-schedule endpoints
 * (mobile/lib/services/usage_ingest_server.dart: /chat/schedules,
 * /chat/schedule/preview, /chat/schedule) so there is exactly one place
 * that understands Korean schedule commands — the same one the in-app
 * "채팅으로 스케줄 만들기" panel already uses.
 */
const API_BASE = "http://127.0.0.1:17361";

const els = {
  offline: document.getElementById("offline"),
  main: document.getElementById("mainArea"),
  log: document.getElementById("log"),
  msgInput: document.getElementById("msgInput"),
  sendBtn: document.getElementById("sendBtn"),
  qBlockPage: document.getElementById("qBlockPage"),
  qAddToSchedule: document.getElementById("qAddToSchedule"),
  schedulePicker: document.getElementById("schedulePicker"),
  scheduleSelect: document.getElementById("scheduleSelect"),
  scheduleAddBtn: document.getElementById("scheduleAddBtn"),
  previewCard: document.getElementById("previewCard"),
  previewSummary: document.getElementById("previewSummary"),
  previewWarnings: document.getElementById("previewWarnings"),
  previewCancel: document.getElementById("previewCancel"),
  previewConfirm: document.getElementById("previewConfirm"),
  openOptions: document.getElementById("openOptions"),
};

let currentHost = null;
// Message text awaiting the user's confirm tap. Kept as the exact string
// sent for preview so confirm re-sends an identical command (the backend
// re-parses on confirm rather than trusting the client's copy of the
// intent — matching the in-app ChatSchedulePanel's own re-send pattern).
let pendingMessage = null;

function appendLine(text, fromUser) {
  const div = document.createElement("div");
  div.className = "line " + (fromUser ? "fromUser" : "fromBot");
  div.textContent = text;
  els.log.appendChild(div);
  els.log.scrollTop = els.log.scrollHeight;
}

async function apiGet(path) {
  const res = await fetch(API_BASE + path, { cache: "no-store" });
  if (!res.ok) throw new Error("HTTP " + res.status);
  return res.json();
}

async function apiPost(path, body) {
  const res = await fetch(API_BASE + path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || "HTTP " + res.status);
  return data;
}

async function checkHealth() {
  try {
    await apiGet("/health");
    return true;
  } catch {
    return false;
  }
}

async function getActiveTabHost() {
  try {
    const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
    const url = tabs && tabs[0] && tabs[0].url;
    if (!url) return null;
    const u = new URL(url);
    if (!/^https?:$/.test(u.protocol)) return null;
    return u.hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
}

function showPreview(preview) {
  els.previewCard.classList.remove("hidden");
  els.previewSummary.textContent = preview.summary || "";
  els.previewWarnings.innerHTML = "";
  for (const w of preview.warnings || []) {
    const li = document.createElement("li");
    li.textContent = w;
    els.previewWarnings.appendChild(li);
  }
}

function hidePreview() {
  els.previewCard.classList.add("hidden");
  els.previewWarnings.innerHTML = "";
}

async function sendCommand(message) {
  const text = message.trim();
  if (!text) return;
  appendLine(text, true);
  els.msgInput.value = "";
  hidePreview();
  try {
    const data = await apiPost("/chat/schedule", { message: text, confirm: false });
    if (data.preview) {
      appendLine(data.preview.summary, false);
      pendingMessage = text;
      showPreview(data.preview);
    } else {
      appendLine("미리보기를 가져오지 못했어요.", false);
    }
  } catch (e) {
    appendLine("오류: " + e.message, false);
  }
}

async function confirmPending() {
  const message = pendingMessage;
  if (!message) return;
  hidePreview();
  try {
    const result = await apiPost("/chat/schedule", { message, confirm: true });
    if (result.pendingEdit) {
      appendLine("예약됨 — " + (result.message || "잠시 후 자동 적용됩니다."), false);
    } else {
      appendLine(result.message || "적용됐어요.", false);
    }
  } catch (e) {
    appendLine("적용 실패: " + e.message, false);
  } finally {
    pendingMessage = null;
  }
}

async function loadSchedulesInto(select) {
  select.innerHTML = "";
  try {
    const data = await apiGet("/chat/schedules");
    const schedules = data.schedules || [];
    if (schedules.length === 0) {
      const opt = document.createElement("option");
      opt.textContent = "스케줄 없음 (새로 생성됨)";
      opt.value = "";
      select.appendChild(opt);
      return;
    }
    for (const s of schedules) {
      const opt = document.createElement("option");
      opt.value = s.name;
      opt.textContent = s.name;
      select.appendChild(opt);
    }
  } catch {
    const opt = document.createElement("option");
    opt.textContent = "불러오기 실패 - 앱이 켜져 있는지 확인하세요";
    select.appendChild(opt);
  }
}

function initQuickActions() {
  els.qBlockPage.addEventListener("click", () => {
    if (!currentHost) {
      appendLine("이 페이지에는 차단할 사이트 주소가 없어요.", false);
      return;
    }
    sendCommand(`${currentHost} 사이트는 항상 차단해줘`);
  });

  els.qAddToSchedule.addEventListener("click", async () => {
    const isHidden = els.schedulePicker.classList.contains("hidden");
    if (isHidden) {
      await loadSchedulesInto(els.scheduleSelect);
      els.schedulePicker.classList.remove("hidden");
    } else {
      els.schedulePicker.classList.add("hidden");
    }
  });

  els.scheduleAddBtn.addEventListener("click", () => {
    if (!currentHost) return;
    const scheduleName = els.scheduleSelect.value;
    els.schedulePicker.classList.add("hidden");
    const msg = scheduleName
      ? `${scheduleName} 스케줄에 ${currentHost} 추가해줘`
      : `${currentHost} 사이트는 항상 차단해줘`;
    sendCommand(msg);
  });
}

function initChatInput() {
  els.sendBtn.addEventListener("click", () => sendCommand(els.msgInput.value));
  els.msgInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") sendCommand(els.msgInput.value);
  });
}

function initPreviewButtons() {
  els.previewConfirm.addEventListener("click", confirmPending);
  els.previewCancel.addEventListener("click", () => {
    hidePreview();
    pendingMessage = null;
    appendLine("취소했어요.", false);
  });
}

els.openOptions.addEventListener("click", (e) => {
  e.preventDefault();
  if (chrome.runtime.openOptionsPage) {
    chrome.runtime.openOptionsPage();
  } else {
    window.open(chrome.runtime.getURL("options.html"));
  }
});

(async function init() {
  initQuickActions();
  initChatInput();
  initPreviewButtons();

  const healthy = await checkHealth();
  if (!healthy) {
    els.offline.classList.remove("hidden");
    els.main.classList.add("hidden");
    return;
  }

  currentHost = await getActiveTabHost();
  if (currentHost) {
    els.qBlockPage.textContent = `🚫 ${currentHost} 차단`;
  } else {
    els.qBlockPage.disabled = true;
    els.qAddToSchedule.disabled = true;
  }

  appendLine("말로 스케줄을 바꿀 수 있어요. 먼저 미리보기를 보여주고, 확인해야 적용돼요.", false);
})();
