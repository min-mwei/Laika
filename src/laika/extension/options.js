"use strict";

var DEFAULT_SIDE = "right";
var statusEl = document.getElementById("status");
var radios = Array.prototype.slice.call(document.querySelectorAll('input[name="sidecar-side"]'));

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

function applySelection(side) {
  radios.forEach(function (radio) {
    radio.checked = radio.value === side;
  });
}

async function loadSettings() {
  if (!browser.storage || !browser.storage.local) {
    applySelection(DEFAULT_SIDE);
    return;
  }
  var stored = await browser.storage.local.get({ sidecarSide: DEFAULT_SIDE });
  applySelection(stored.sidecarSide === "left" ? "left" : DEFAULT_SIDE);
}

async function saveSettings() {
  var side = getSelectedSide();
  if (!browser.storage || !browser.storage.local) {
    setStatus("Settings unavailable in this environment.");
    return;
  }
  await browser.storage.local.set({ sidecarSide: side });
  setStatus("Saved: " + side);
}

radios.forEach(function (radio) {
  radio.addEventListener("change", function () {
    saveSettings();
  });
});

loadSettings();
