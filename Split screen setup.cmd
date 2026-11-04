@echo off
rem Double-click once after Install.cmd: sets up two players on one PC (split screen) and puts
rem "RE7 Co-op split screen" on the desktop. See split-screen\README.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-screen\Start-RE7-SplitScreen.ps1" -Setup %*
