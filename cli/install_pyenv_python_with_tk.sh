#!/usr/bin/env bash
set -euo pipefail

# Install a pyenv Python with Tkinter support on macOS (Homebrew).
#
# Usage:
#   chmod +x cli/install_pyenv_python_with_tk.sh
#   ./cli/install_pyenv_python_with_tk.sh 3.11.7
#
# Notes:
# - This script installs brew deps and compiles Python via pyenv.
# - It does NOT modify your shell init files. Ensure pyenv is initialized in your shell.

PYTHON_VERSION="${1:-3.11.7}"

echo "📦 Installing Python ${PYTHON_VERSION} with Tkinter support (pyenv + Homebrew)"

# ----------------------------
# 0. Platform guard
# ----------------------------
if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ This script is for macOS (Darwin) only."
  echo "Linux: install Tk dev packages (tcl/tk) and build Python with pyenv using your distro packages."
  exit 1
fi

# ----------------------------
# 1. Homebrew check
# ----------------------------
if ! command -v brew >/dev/null 2>&1; then
  echo "❌ Homebrew is required. Install from https://brew.sh"
  exit 1
fi

# ----------------------------
# 2. Install dependencies
# ----------------------------
echo "🔧 Installing/Updating build dependencies..."
brew update

# Prefer modern formula names on Homebrew
brew install pyenv tcl-tk readline sqlite3 xz zlib || true
# openssl is versioned; try openssl@3 first
brew install openssl@3 || brew install openssl || true

# ----------------------------
# 3. Resolve prefixes (handle keg-only formulae)
# ----------------------------
TCLTK_PREFIX="$(brew --prefix tcl-tk)"
READLINE_PREFIX="$(brew --prefix readline)"
SQLITE3_PREFIX="$(brew --prefix sqlite3)"
XZ_PREFIX="$(brew --prefix xz)"
ZLIB_PREFIX="$(brew --prefix zlib)"

OPENSSL_PREFIX=""
if brew --prefix openssl@3 >/dev/null 2>&1; then
  OPENSSL_PREFIX="$(brew --prefix openssl@3)"
elif brew --prefix openssl >/dev/null 2>&1; then
  OPENSSL_PREFIX="$(brew --prefix openssl)"
else
  echo "⚠️  Could not resolve OpenSSL prefix via brew --prefix."
fi

# Make sure Tcl/Tk tools are discoverable
export PATH="${TCLTK_PREFIX}/bin:${PATH}"

# ----------------------------
# 4. Build flags
# ----------------------------
export LDFLAGS="-L${TCLTK_PREFIX}/lib -L${READLINE_PREFIX}/lib -L${SQLITE3_PREFIX}/lib -L${XZ_PREFIX}/lib -L${ZLIB_PREFIX}/lib"
export CPPFLAGS="-I${TCLTK_PREFIX}/include -I${READLINE_PREFIX}/include -I${SQLITE3_PREFIX}/include -I${XZ_PREFIX}/include -I${ZLIB_PREFIX}/include"
export PKG_CONFIG_PATH="${TCLTK_PREFIX}/lib/pkgconfig:${READLINE_PREFIX}/lib/pkgconfig:${SQLITE3_PREFIX}/lib/pkgconfig:${XZ_PREFIX}/lib/pkgconfig:${ZLIB_PREFIX}/lib/pkgconfig"

if [[ -n "${OPENSSL_PREFIX}" ]]; then
  export LDFLAGS="${LDFLAGS} -L${OPENSSL_PREFIX}/lib"
  export CPPFLAGS="${CPPFLAGS} -I${OPENSSL_PREFIX}/include"
  export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}:${OPENSSL_PREFIX}/lib/pkgconfig"
fi

# Framework build helps GUI tooling on macOS
export PYTHON_CONFIGURE_OPTS="--enable-framework"

echo "✅ Build env configured:"
echo " - TCLTK_PREFIX=${TCLTK_PREFIX}"
echo " - OPENSSL_PREFIX=${OPENSSL_PREFIX:-<none>}"
echo " - PYTHON_CONFIGURE_OPTS=${PYTHON_CONFIGURE_OPTS}"

# ----------------------------
# 5. Ensure pyenv exists
# ----------------------------
if ! command -v pyenv >/dev/null 2>&1; then
  echo "❌ pyenv not found after brew install."
  echo "Make sure your shell initializes pyenv (e.g. eval \"$(pyenv init -)\" ), then rerun."
  exit 1
fi

# ----------------------------
# 6. Reinstall prompt if already installed
# ----------------------------
if pyenv versions --bare | grep -q "^${PYTHON_VERSION}$"; then
  echo "⚠️  Python ${PYTHON_VERSION} already installed in pyenv."
  read -r -p "Reinstall? (y/N): " REINSTALL || true
  if [[ "${REINSTALL:-N}" =~ ^[Yy]$ ]]; then
    pyenv uninstall -f "${PYTHON_VERSION}"
  else
    echo "✔ Using existing version"
    pyenv global "${PYTHON_VERSION}"
    echo "🧪 Testing tkinter..."
    python -m tkinter >/dev/null 2>&1 && echo "✅ tkinter OK (window should appear if GUI available)" || true
    exit 0
  fi
fi

# ----------------------------
# 7. Install Python
# ----------------------------
echo "🚀 Building Python ${PYTHON_VERSION} via pyenv..."
pyenv install "${PYTHON_VERSION}"

# ----------------------------
# 8. Activate
# ----------------------------
pyenv global "${PYTHON_VERSION}"

# ----------------------------
# 9. Ensure pip
# ----------------------------
python -m ensurepip --upgrade
python -m pip install --upgrade pip

# ----------------------------
# 10. Verify tkinter
# ----------------------------
echo "🧪 Testing tkinter..."
python - <<'PY'
import sys
try:
    import tkinter as tk
    print("✅ Tkinter import OK:", tk.TkVersion)
except Exception as e:
    print("❌ Tkinter failed:", e)
    sys.exit(1)
PY

echo ""
echo "🎉 SUCCESS"
echo "Python ${PYTHON_VERSION} with Tkinter is ready."
echo "Tip: If VSCode still can't find tkinter/customtkinter, ensure it uses this pyenv interpreter."
