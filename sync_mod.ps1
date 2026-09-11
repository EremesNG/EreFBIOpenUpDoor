param(
    [string]$WorkshopRoot = 'C:\Users\EremesNG\Zomboid\Workshop'
)

$ErrorActionPreference = 'Stop'

try {
    $sourceDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
    $workshopDir = [System.IO.Path]::GetFullPath($WorkshopRoot)
    $destinationDir = Join-Path $workshopDir 'EreFBIOpenUpDoor'

    # Validar todo el origen antes de modificar la instalacion local.
    foreach ($fileName in @('preview.png', 'workshop.txt')) {
        $sourceFile = Join-Path $sourceDir $fileName
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            throw "Falta el archivo requerido: $sourceFile"
        }
    }
    $sourceContents = Join-Path $sourceDir 'Contents'
    if (-not (Test-Path -LiteralPath $sourceContents -PathType Container)) {
        throw "Falta la carpeta requerida: $sourceContents"
    }

    # El destino debe ser un hijo directo de Workshop y no solaparse con el origen.
    $destinationDir = [System.IO.Path]::GetFullPath($destinationDir)
    if ([System.IO.Path]::GetDirectoryName($destinationDir) -ne $workshopDir.TrimEnd('\')) {
        throw 'El destino no pertenece a la carpeta Workshop indicada.'
    }
    $sourcePrefix = $sourceDir.TrimEnd('\') + '\'
    $destinationPrefix = $destinationDir.TrimEnd('\') + '\'
    if ($sourcePrefix.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $destinationPrefix.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'El origen y el destino no pueden ser iguales ni contenerse entre si.'
    }
    if (Test-Path -LiteralPath $destinationDir) {
        $destination = Get-Item -LiteralPath $destinationDir -Force
        if (-not $destination.PSIsContainer -or
            ($destination.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw 'El destino debe ser una carpeta normal, no un archivo ni un enlace.'
        }
    }

    Write-Host 'Sincronizando Mod...'
    Write-Host "Origen: $sourceDir"
    Write-Host "Destino: $destinationDir"

    if (Test-Path -LiteralPath $destinationDir) {
        Remove-Item -LiteralPath $destinationDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

    foreach ($fileName in @('preview.png', 'workshop.txt', 'Contents')) {
        Copy-Item -LiteralPath (Join-Path $sourceDir $fileName) -Destination $destinationDir -Recurse -Force
    }

    Write-Host 'Sincronizacion completada.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("[ERROR] Sincronizacion fallida: $($_.Exception.Message)")
    exit 1
}
