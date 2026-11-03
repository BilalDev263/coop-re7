@echo off
rem Double-click after copying "Third Person Full Model Placeholders" (Nexus RE7 mod 86)
rem into your co-op folder: sets its models up for the co-op lobby only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0use-full-models.ps1" %*
echo.
pause