Set ws = CreateObject("WScript.Shell")
scriptPath = "D:\AI\Antigravity-Chinese-Localization\watch-and-auto-localize.ps1"
ws.Run "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """", 0, False
