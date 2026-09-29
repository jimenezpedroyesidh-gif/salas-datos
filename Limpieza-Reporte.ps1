<#
    Limpieza-Reporte.ps1
    Uso: tarea de INICIO como SYSTEM. Debe vivir en una carpeta que solo
    SYSTEM y Administradores puedan modificar (ver icacls en la guía).

    1) Limpia carpetas y navegadores (bloque original, sin cambios).
    2) Espera a que haya red, detecta si el equipo va por Wi-Fi o Ethernet.
    3) Sube status/<EQUIPO>.json al repo de DATOS.
    Si el equipo no tiene internet no puede reportar: en el panel aparece
    como "sin reporte".
#>

# ================= CONFIGURACIÓN =================
$GitHubUser   = "jimenezpedroyesidh-gif"
$RepoName     = "salas-datos"                      # repo de datos, no el del código
$Base         = "C:\ProgramData\EstadoSalas"
$RepoLocal    = "$Base\repo"
$TokenFile    = "$Base\token.txt"
$GitUserName  = "sala-bot"
$GitUserEmail = "sala-bot@example.com"

# ================= 1. LIMPIEZA DE CARPETAS (todos los perfiles) =================
# Como corre como SYSTEM, $env:USERPROFILE NO es el de los usuarios: se recorre C:\Users.
# Perfiles que NO se tocan (agrega aqui el nombre de tu cuenta de administrador):
$PerfilesExcluidos = @("Public", "Default", "Default User", "All Users", "Administrador", "Administrator")

$perfiles = Get-ChildItem "C:\Users" -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $PerfilesExcluidos -notcontains $_.Name -and (Test-Path "$($_.FullName)\NTUSER.DAT") }

$carpetas = @("$env:TEMP", "C:\Windows\Temp")
foreach ($p in $perfiles) {
    $carpetas += @(
        "$($p.FullName)\AppData\Local\Temp",
        "$($p.FullName)\Downloads",
        "$($p.FullName)\Documents",
        "$($p.FullName)\Pictures",
        "$($p.FullName)\Music"
    )
}
foreach ($carpeta in ($carpetas | Select-Object -Unique)) {
    if (Test-Path $carpeta) {
        Get-ChildItem -Path $carpeta -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ================= 2. LIMPIEZA DE NAVEGADORES (todos los perfiles) =================
Stop-Process -Name "chrome","msedge","firefox" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

foreach ($p in $perfiles) {
    $rutasChromium = @(
        "$($p.FullName)\AppData\Local\Google\Chrome\User Data\Default\Cache",
        "$($p.FullName)\AppData\Local\Google\Chrome\User Data\Default\History",
        "$($p.FullName)\AppData\Local\Microsoft\Edge\User Data\Default\Cache",
        "$($p.FullName)\AppData\Local\Microsoft\Edge\User Data\Default\History"
    )
    foreach ($ruta in $rutasChromium) {
        Remove-Item -Path $ruta -Recurse -Force -ErrorAction SilentlyContinue
    }

    $perfilFirefox = Get-ChildItem "$($p.FullName)\AppData\Roaming\Mozilla\Firefox\Profiles" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($perfilFirefox) {
        Remove-Item "$($perfilFirefox.FullName)\cache2" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$($perfilFirefox.FullName)\places.sqlite" -Force -ErrorAction SilentlyContinue
    }
}

# ================= 3. ESPERAR INTERNET =================
function Test-Internet {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $r = $c.BeginConnect("github.com", 443, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(3000) -and $c.Connected
        $c.Close()
        return $ok
    } catch { return $false }
}
$internet = $false
while (-not $internet) {                                # espera sin limite hasta que haya internet
    $internet = Test-Internet
    if (-not $internet) { Start-Sleep -Seconds 10 }
}
if (-not (Test-Path $TokenFile)) { Write-Warning "Falta $TokenFile"; return }
$Token = (Get-Content $TokenFile -Raw).Trim()

# ================= 4. DATOS DEL EQUIPO =================
# Adaptador de la ruta principal: 9 = Wi-Fi (802.11), 14 = Ethernet (802.3)
$conexion = "ninguna"
$ruta = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
if ($ruta) {
    $ad = Get-NetAdapter -InterfaceIndex $ruta.InterfaceIndex -ErrorAction SilentlyContinue
    if ($ad) {
        if ($ad.NdisPhysicalMedium -eq 9 -or $ad.InterfaceDescription -match 'wi-?fi|wireless|802\.11') {
            $conexion = "wifi"
        } else { $conexion = "ethernet" }
    }
}

$hostname  = $env:COMPUTERNAME
$timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$arranque  = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss")
$procesos  = @(Get-Process | Where-Object { $_.MainWindowTitle -ne "" } |
    Select-Object -ExpandProperty ProcessName -Unique)

$estadoJson = [PSCustomObject]@{
    hostname   = $hostname
    ultima_vez = $timestamp
    arranque   = $arranque
    conexion   = $conexion
    procesos   = $procesos
} | ConvertTo-Json -Depth 3

# ================= 5. SUBIR A GITHUB (token no se guarda en .git/config) =================
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
$gitAuth = @("-c", "http.extraheader=AUTHORIZATION: basic $auth")
$RepoUrl = "https://github.com/$GitHubUser/$RepoName.git"

if (-not (Test-Path "$RepoLocal\.git")) {
    git @gitAuth clone $RepoUrl $RepoLocal 2>$null
} else {
    git @gitAuth -C $RepoLocal pull --rebase 2>$null
}

$statusFolder = Join-Path $RepoLocal "status"
if (-not (Test-Path $statusFolder)) { New-Item -ItemType Directory -Path $statusFolder | Out-Null }
$estadoJson | Out-File -FilePath (Join-Path $statusFolder "$hostname.json") -Encoding utf8

git -C $RepoLocal config user.name  $GitUserName
git -C $RepoLocal config user.email $GitUserEmail
git -C $RepoLocal add "status/$hostname.json"
git -C $RepoLocal commit -m "Estado de $hostname - $timestamp" 2>$null

# Varios equipos empujan a la vez: reintentar con pausa aleatoria
for ($i = 0; $i -lt 5; $i++) {
    git @gitAuth -C $RepoLocal push 2>$null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds (Get-Random -Minimum 3 -Maximum 15)
    git @gitAuth -C $RepoLocal pull --rebase 2>$null
}
