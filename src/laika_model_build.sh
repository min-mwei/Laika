#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

QUANTIZER_DIR="${QUANTIZER_DIR:-${REPO_ROOT}/src/local_llm_quantizer}"
MODEL_OUT_DIR="${MODEL_OUT_DIR:-${REPO_ROOT}/src/laika/extension/lib/models/Qwen3-0.6B-MLX-4bit}"
PYTHON="${PYTHON:-python3}"
VENV="${VENV:-${QUANTIZER_DIR}/.venv}"

if [ ! -d "${QUANTIZER_DIR}" ]; then
  echo "local_llm_quantizer not found at ${QUANTIZER_DIR}" >&2
  exit 1
fi

if [ ! -f "${QUANTIZER_DIR}/convert_qwen3_to_mlx_4bit.py" ]; then
  echo "Converter not found at ${QUANTIZER_DIR}/convert_qwen3_to_mlx_4bit.py" >&2
  exit 1
fi

if ! command -v "${PYTHON}" >/dev/null 2>&1; then
  echo "Python not found (set PYTHON or install python3)." >&2
  exit 1
fi

mkdir -p "$(dirname "${MODEL_OUT_DIR}")"

if [ ! -x "${VENV}/bin/python" ]; then
  echo "Creating venv at ${VENV}"
  "${PYTHON}" -m venv "${VENV}"
  "${VENV}/bin/pip" install -r "${QUANTIZER_DIR}/requirements.txt"
fi

echo "Publishing MLX model to ${MODEL_OUT_DIR}"
"${VENV}/bin/python" "${QUANTIZER_DIR}/convert_qwen3_to_mlx_4bit.py" \
  --out-dir "${MODEL_OUT_DIR}" \
  --overwrite \
  "$@"
