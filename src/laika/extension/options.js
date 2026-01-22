"use strict";

var DEFAULT_SIDE = "right";
var DEFAULT_STICKY = true;
var statusEl = document.getElementById("status");
var radios = Array.prototype.slice.call(document.querySelectorAll('input[name="sidecar-side"]'));
var stickyToggle = document.getElementById("sidecar-sticky");

function setStatus(text) {
  if (statusEl) {
    statusEl.textContent = text;
  }
}

function getSelectedSide() {
  var selected = radios.find(function (radio) {
    return radio.checked;
  });
  return selected ? selected.value : DEFAULT_SIDE;
}

function applySelection(side, sticky) {
  radios.forEach(function (radio) {
    radio.checked = radio.value === side;
  });
  if (stickyToggle) {
    stickyToggle.checked = sticky !== false;
  }
}

async function loadSettings() {
  if (!browser.storage || !browser.storage.local) {
    applySelection(DEFAULT_SIDE, DEFAULT_STICKY);
    return;
  }
  var stored = await browser.storage.local.get({ sidecarSide: DEFAULT_SIDE, sidecarSticky: DEFAULT_STICKY });
  var side = stored.sidecarSide === "left" ? "left" : DEFAULT_SIDE;
  var sticky = stored.sidecarSticky !== false;
  applySelection(side, sticky);
}

async function saveSettings() {
  var side = getSelectedSide();
  var sticky = stickyToggle ? stickyToggle.checked : DEFAULT_STICKY;
  if (!browser.storage || !browser.storage.local) {
    setStatus("Settings unavailable in this environment.");
    return;
  }
  await browser.storage.local.set({ sidecarSide: side, sidecarSticky: sticky });
  setStatus("Saved: " + side + ", " + (sticky ? "sticky" : "per-tab"));
}

radios.forEach(function (radio) {
  radio.addEventListener("change", function () {
    saveSettings();
  });
});
if (stickyToggle) {
  stickyToggle.addEventListener("change", function () {
    saveSettings();
  });
}

loadSettings();
