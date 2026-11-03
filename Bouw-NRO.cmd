@echo off
rem Bouw-NRO.cmd - the double-click entry point for the one-click builder.
rem
rem Double-click this file: out comes a native Switch .nro plus a drag-and-drop
rem SD folder from this folder. With Python 3 you get a window in your browser
rem (pick a ROM, Start, progress); without Python the same builder runs on in
rem this terminal window.
rem Options work too, for example:  Bouw-NRO.cmd --full  or  --zip
rem For the full list:              Bouw-NRO.cmd --help
rem
rem Needed: Git for Windows and your own Wii dump. Builds natively with devkitA64
rem (fetch it with: bash tools\setup-native.sh --install); Docker is only the fallback.
rem
rem Python is looked up by tools\ensure-ui-env.sh, not by this file. Reason: cmd's
rem PATH points at the Microsoft Store alias, which looks like Python but is not,
rem so the old probe answered "no Python" on a machine that had it and dropped you
rem into the terminal with no ROM picker. If Python really is missing, this file
rem asks before installing it.
chcp 65001 >nul
setlocal EnableExtensions
set "ROOT=%~dp0"
cd /d "%ROOT%"

set "BASH="
if exist "C:\Program Files\Git1\bin\bash.exe" set "BASH=C:\Program Files\Git1\bin\bash.exe"
if not defined BASH if exist "C:\Program Files\Git\bin\bash.exe" set "BASH=C:\Program Files\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH for /f "delims=" %%i in ('where bash.exe 2^>nul') do if not defined BASH set "BASH=%%i"

set "FINDER=%ROOT%tools\ensure-ui-env.sh"

echo.
echo ==========================================================
echo  Mario Kart Wii - native Switch builder (one click)
echo ==========================================================
echo.

if not defined BASH (
  echo Error: Git Bash was not found.
  echo Install Git for Windows ^("https://git-scm.com/download/win^"^)
  echo and double-click this file again.
  echo.
  pause
  exit /b 1
)

echo tooling:     %BASH%
rem Hand the verified Git Bash to the window: cmd's PATH points at the WSL relay,
rem which exists as a file but has no bash behind it (execvpe /bin/bash failed).
set "MKW_BASH=%BASH%"
set "PYCMD="
call :findpython
if defined PYCMD echo interface:   %PYCMD%

if "%~1"=="--help" (
  "%BASH%" tools/nro-engine.sh --help
  echo.
  echo Extra options for the window: --no-browser --port 8765 --dump path
  pause
  exit /b 0
)

if defined PYCMD goto window

echo.
echo  The window - pick a ROM, press Start, watch the progress - runs on Python 3,
echo  and this machine has no reachable one.
call "%BASH%" "%FINDER%" --reason
echo.
set "ANS="
set /p ANS=Install Python 3 now and open the window? [y/N]:
if /i not "%ANS%"=="y" goto terminal

call "%BASH%" "%FINDER%" --install
set "PYCMD="
call :findpython
if not defined PYCMD (
  echo.
  echo  Python 3 is still not reachable from this window, so the build continues here.
  echo  After a fresh install: close this window and double-click again, a new window
  echo  does see the updated PATH.
) else goto window

:terminal
echo.
echo entry point: %ROOT%tools\build-nro.sh
echo  (Terminal mode: it asks for the dump path, then builds. Same engine, no window.)
echo.
"%BASH%" tools/build-nro.sh %*
goto done

:window
echo entry point: %ROOT%tools\nro-webui.py
echo.
echo  A window opens in your browser. There: pick a ROM, Start, progress.
echo  (No browser? "%PYCMD%" tools\nro-webui.py --no-browser prints the address.)
echo  Keep this terminal window open while it builds.
echo.
"%PYCMD%" tools\nro-webui.py %*
goto done

:done
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo DONE.
  echo    drag-and-drop SD folder: dist\MarioKartWii-Switch\   ^(the switch/ folder goes at the root of your SD^)
  echo    the .nro itself:         WiiCompiled-Switch\local-product\native-deko3d\
  echo The .sha256 file for checking is there too.
) else (
  echo FAILED, exit code %RC%. The full build log is in the logs\ folder.
)
echo.
pause
exit /b %RC%

rem One line on stdout = the interpreter this machine can really run (see finder).
rem The word `call` is needed: without it cmd strips the first quote of the
rem command line and bash.exe becomes 'C:\Program' - not a command.
:findpython
for /f "delims=" %%i in ('call "%BASH%" "%FINDER%" 2^>nul') do if not defined PYCMD set "PYCMD=%%i"
goto :eof
