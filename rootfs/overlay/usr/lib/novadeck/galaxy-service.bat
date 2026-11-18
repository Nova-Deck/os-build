@echo off
rem Register Comet's dummy GalaxyCommunication service in this prefix (a NovaDeck first-run step).
rem
rem Some Galaxy SDK versions start this Windows service when no Galaxy client runs, and fail
rem without it. Heroic's sequence (launcher.ts): the stub at the path Galaxy itself uses, the
rem service, and the GalaxyClient paths key. The novadeck-stores plugin stages this file next to
rem GalaxyCommunication.exe in the store home (the step runs inside the game's runtime container,
rem which shares /home but not the host's /usr), so %~dp0 is that staging dir.
rem See .claude/plans/gog-galaxy-comet.plan.md design 7. The exit code is recorded in the prefix.
set "target=C:\ProgramData\GOG.com\Galaxy\redists"
if not exist "%target%" mkdir "%target%"
copy /y "%~dp0GalaxyCommunication.exe" "%target%\GalaxyCommunication.exe" >nul || exit /b 1
sc query GalaxyCommunication >nul 2>&1 || sc create GalaxyCommunication binpath= "%target%\GalaxyCommunication.exe" >nul || exit /b 2
reg add "HKLM\SOFTWARE\WOW6432Node\GOG.com\GalaxyClient\paths" /v client /t REG_SZ /d "C:\Program Files\GOG Galaxy" /f >nul || exit /b 3
exit /b 0
