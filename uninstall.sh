#!/bin/bash
# Removes every trace of Murmur. Nothing here needs sudo.
set -u

pkill -x Murmur 2>/dev/null || true
pkill -f parakeetd.py 2>/dev/null || true
sleep 1

osascript -e 'tell application "System Events" to delete login item "Murmur"' 2>/dev/null || true
rm -rf /Applications/Murmur.app
rm -rf "$HOME/Library/Application Support/Murmur"
rm -rf "$HOME/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3"
rm -rf "$HOME/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-Instruct-2507-4bit"
defaults delete com.ramy.murmur 2>/dev/null || true
security delete-certificate -c "Murmur Local Signing" 2>/dev/null || true

echo "Murmur removed — app, venv, model, settings and signing certificate."
echo
echo "Revoke Microphone, Accessibility and Input Monitoring for Murmur in"
echo "System Settings › Privacy & Security."
