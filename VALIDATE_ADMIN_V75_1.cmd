@echo off
setlocal
cd /d %~dp0

echo === WISSA ADMIN V75.1 ===
call npm run typecheck || exit /b 1
call npm test || exit /b 1
call npm run build || exit /b 1

echo WISSA ADMIN V75.1: VALIDACION OK
