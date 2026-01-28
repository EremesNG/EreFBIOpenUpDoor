@echo off
setlocal

:: Obtener el nombre de la carpeta actual
for %%I in (.) do set "CurrentFolderName=%%~nxI"

:: Rutas
set "SourceDir=%CD%"
set "DestBaseDir=C:\Users\EremesNG\Zomboid\Workshop"
set "DestDir=%DestBaseDir%\%CurrentFolderName%"

echo Sincronizando Mod...
echo Origen: %SourceDir%
echo Destino: %DestDir%

:: 1. Borrar destino si existe
if exist "%DestDir%" (
    echo Borrando carpeta existente en destino...
    rmdir /s /q "%DestDir%"
)

:: 2. Crear carpeta de destino
echo Creando carpeta de destino...
mkdir "%DestDir%"

:: 3. Copiar archivos preview.png y workshop.txt
if exist "%SourceDir%\preview.png" (
    echo Copiando preview.png...
    copy "%SourceDir%\preview.png" "%DestDir%\" >nul
) else (
    echo [ADVERTENCIA] preview.png no encontrado.
)

if exist "%SourceDir%\workshop.txt" (
    echo Copiando workshop.txt...
    copy "%SourceDir%\workshop.txt" "%DestDir%\" >nul
) else (
    echo [ADVERTENCIA] workshop.txt no encontrado.
)

:: 4. Copiar carpeta Contents
if exist "%SourceDir%\Contents" (
    echo Copiando carpeta Contents...
    xcopy "%SourceDir%\Contents" "%DestDir%\Contents\" /E /I /Y >nul
) else (
    echo [ADVERTENCIA] Carpeta Contents no encontrada.
)

echo Sincronizacion completada.
pause
