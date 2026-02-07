#!/usr/bin/env bash
set -euo pipefail

if command -v chromium >/dev/null 2>&1 || \
   command -v chromium-browser >/dev/null 2>&1 || \
   command -v google-chrome >/dev/null 2>&1 || \
   command -v google-chrome-stable >/dev/null 2>&1 || \
   command -v chrome >/dev/null 2>&1; then
  echo "Chromium/Chrome already installed"
  exit 0
fi

OS="$(uname -s)"
case "$OS" in
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      echo "Installing Chromium via apt-get..."
      sudo apt-get update
      sudo apt-get install -y chromium-browser || sudo apt-get install -y chromium
      exit 0
    fi

    if command -v dnf >/dev/null 2>&1; then
      echo "Installing Chromium via dnf..."
      sudo dnf install -y chromium
      exit 0
    fi

    if command -v pacman >/dev/null 2>&1; then
      echo "Installing Chromium via pacman..."
      sudo pacman -Sy --noconfirm chromium
      exit 0
    fi

    if command -v zypper >/dev/null 2>&1; then
      echo "Installing Chromium via zypper..."
      sudo zypper install -y chromium
      exit 0
    fi

    echo "Could not detect supported package manager for Chromium install."
    echo "Install Chromium manually, then run: make pdf-check"
    exit 1
    ;;
  Darwin)
    if command -v brew >/dev/null 2>&1; then
      echo "Installing Chromium via Homebrew cask..."
      brew install --cask chromium
      exit 0
    fi

    echo "Homebrew not found. Install Chromium manually, then run: make pdf-check"
    exit 1
    ;;
  *)
    echo "Unsupported OS: $OS"
    echo "Install Chromium/Chrome manually, then run: make pdf-check"
    exit 1
    ;;
esac

