param(
    [switch]$nonInteractive
)

Add-Type -AssemblyName PresentationFramework

#==========================
# Funções utilitárias simples do GUI
#==========================
function Write-Status {
    param([string]$msg)
    Write-Host "[ + ] $msg"
}

#==========================
# MÓDULO CORE – LIMPEZA / USUÁRIOS / INVENTÁRIO
#==========================

$ErrorActionPreference = 'Continue'

function New-ToolkitLogger {
  param([string]$LogDirectory = "$env:windir\Temp")

  $startTime = Get-Date
  if (-not (Test-Path $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null }
  $logFile = Join-Path $LogDirectory ("Win-Toolkit_{0:yyyyMMdd_HHmmss}.log" -f $startTime)

  "=== Win-Toolkit iniciado: $startTime ===" | Out-File -FilePath $logFile -Encoding utf8

  $logFileLocal = $logFile
  $logSb = {
    param([string]$msg)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$stamp  $msg" | Tee-Object -FilePath $logFileLocal -Append
  }.GetNewClosure()

  return [PSCustomObject]@{
    StartTime = $startTime
    LogFile   = $logFile
    Log       = $logSb
  }
}

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Ensure-CertareDir {
  $dir = "C:\Certare"
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Invoke-External {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$Arguments = "",
    [Parameter(Mandatory=$true)]$Logger,
    [switch]$NoThrow
  )

  & $Logger.Log ("Executando: {0} {1}" -f $FilePath, $Arguments)
  try {
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
    & $Logger.Log ("ExitCode: {0}" -f $p.ExitCode)
    if (-not $NoThrow -and $p.ExitCode -ne 0) { throw "Comando falhou (ExitCode=$($p.ExitCode))" }
  } catch {
    & $Logger.Log ("Falha executando comando: {0}" -f $_.Exception.Message)
    if (-not $NoThrow) { throw }
  }
}

function Get-LocalUsersList {
  try {
    $out = net user
    $lines = $out | ForEach-Object { $_.ToString() }

    $sep = ($lines | Select-String -Pattern "^-{3,}$").LineNumber
    if (-not $sep) { return @() }

    $names = @()
    for ($i=$sep; $i -lt $lines.Count; $i++) {
      $ln = $lines[$i].Trim()
      if ($ln -match "O comando foi conclu[ií]do com êxito" -or $ln -match "The command completed successfully") { break }
      if (-not $ln) { continue }
      $names += ($ln -split "\s+") | Where-Object { $_ }
    }

    return $names | Sort-Object -Unique
  } catch { return @() }
}

function Select-LocalUser {
  param(
    [string]$Title = "Selecione um usuário",
    [string[]]$Exclude = @()
  )

  $users = Get-LocalUsersList | Where-Object { $_ -and ($_ -notin $Exclude) }
  if (-not $users -or $users.Count -eq 0) {
    Write-Host "Não consegui listar usuários locais com 'net user'." -ForegroundColor Yellow
    return (Read-Host "Digite o username manualmente")
  }

  Write-Host ""
  Write-Host $Title
  Write-Host "---------------------------------------------"
  for ($i=0; $i -lt $users.Count; $i++) { "{0,2}) {1}" -f ($i+1), $users[$i] | Write-Host }
  Write-Host ""

  while ($true) {
    $sel = Read-Host "Digite o número (ou ENTER para digitar manual)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return (Read-Host "Username") }
    if ($sel -match '^\d+$') {
      $idx = [int]$sel - 1
      if ($idx -ge 0 -and $idx -lt $users.Count) { return $users[$idx] }
    }
    Write-Host "Opção inválida." -ForegroundColor Yellow
  }
}

function Get-FreeGB { try { return ((Get-PSDrive -Name C).Free/1GB) } catch { return $null } }

function Stop-ServiceSafe {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [int]$TimeoutSeconds = 30,
    [Parameter(Mandatory=$true)]$Logger
  )

  $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if (-not $svc) { & $Logger.Log "Serviço '$Name' não encontrado."; return }
  if ($svc.Status -eq 'Stopped') { & $Logger.Log "Serviço '$Name' já está parado."; return }

  & $Logger.Log "Parando serviço '$Name'..."
  try { Stop-Service -Name $Name -Force -ErrorAction Stop }
  catch { & $Logger.Log ("Falha ao enviar comando de parada para '$Name': {0}" -f $_.Exception.Message) }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Stopped') { & $Logger.Log "Serviço '$Name' parado com sucesso."; return }
  }

  & $Logger.Log "AVISO: Aguardou $TimeoutSeconds s e o serviço '$Name' não parou. Continuando execução."
}

function Start-ServiceSafe {
  param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)]$Logger)
  try { & $Logger.Log ("Iniciando serviço {0}..." -f $Name); Start-Service -Name $Name -ErrorAction SilentlyContinue }
  catch { & $Logger.Log ("Falha ao iniciar {0}: {1}" -f $Name, $_.Exception.Message) }
}

function Disable-Hibernation {
  param([Parameter(Mandatory=$true)]$Logger)
  try { & $Logger.Log "Desativando hibernação..."; powercfg -h off | Out-Null; & $Logger.Log "Hibernação desativada." }
  catch { & $Logger.Log ("Falha ao desativar hibernação: {0}" -f $_.Exception.Message) }
}

function Clear-SoftwareDistributionDownload {
  param([Parameter(Mandatory=$true)]$Logger)
  $sdDownload = Join-Path $env:windir "SoftwareDistribution\Download"
  try {
    if (Test-Path $sdDownload) {
      & $Logger.Log "Limpando $sdDownload ..."
      Get-ChildItem $sdDownload -Force -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
      New-Item -ItemType Directory -Path $sdDownload -Force | Out-Null
      & $Logger.Log "SoftwareDistribution\Download limpo."
    } else {
      & $Logger.Log "Pasta não encontrada: $sdDownload"
    }
  } catch { & $Logger.Log ("Falha limpando SoftwareDistribution: {0}" -f $_.Exception.Message) }
}

function Clear-TempFolder {
  param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$Logger)
  if (Test-Path $Path) {
    try {
      & $Logger.Log "Limpando Temp: $Path"
      Get-ChildItem $Path -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } catch { & $Logger.Log ("Falha limpando Temp ($Path): {0}" -f $_.Exception.Message) }
  }
}

function Clear-TempsAllUsers {
  param([Parameter(Mandatory=$true)]$Logger)
  Clear-TempFolder -Path "$env:windir\Temp" -Logger $Logger
  Get-ChildItem "C:\Users" -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Clear-TempFolder -Path (Join-Path $_.FullName "AppData\Local\Temp") -Logger $Logger
  }
}

function Clear-RecycleBinAllUsers {
  param([Parameter(Mandatory=$true)]$Logger)

  & $Logger.Log "Esvaziando Lixeira do usuário atual (cmdlet)..."
  try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue | Out-Null } catch {}

  if (-not (Test-IsAdmin)) {
    & $Logger.Log "AVISO: Sem privilégios de Administrador. Limpei apenas a lixeira do usuário atual."
    return
  }

  & $Logger.Log "Esvaziando Lixeiras de TODOS os usuários (por volume)..."
  Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    $root = $_.Root.TrimEnd('\')
    $targets = @((Join-Path $root '$Recycle.Bin'), (Join-Path $root 'Recycler'), (Join-Path $root 'Recycled'))
    foreach ($t in $targets) {
      if (Test-Path -LiteralPath $t) {
        try {
          Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
          & $Logger.Log ("Lixeira limpa em: {0}" -f $t)
        } catch { & $Logger.Log ("Falha limpando {0}: {1}" -f $t, $_.Exception.Message) }
      }
    }
  }
}

function Clear-DeliveryOptimizationCache {
  param([Parameter(Mandatory=$true)]$Logger)
  $doPath = Join-Path $env:ProgramData "Microsoft\Windows\DeliveryOptimization\Cache"
  try {
    if (Test-Path $doPath) {
      & $Logger.Log "Limpando Delivery Optimization Cache..."
      Get-ChildItem $doPath -Force -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      & $Logger.Log "Delivery Optimization limpo."
    }
  } catch { & $Logger.Log ("Falha ao limpar Delivery Optimization: {0}" -f $_.Exception.Message) }
}

function Invoke-CleanupOptimizations {
  param(
    [switch]$Aggressive,
    [switch]$OnlyRecycle,
    [switch]$OnlyTemps,
    [switch]$OnlyWindowsUpdateCache
  )

  $logger = New-ToolkitLogger
  & $logger.Log "Limpeza/Otimizações iniciado."
  $freeBefore = Get-FreeGB
  if ($null -ne $freeBefore) { & $logger.Log ("Espaço livre antes: {0:N2} GB" -f $freeBefore) }

  try {
    if ($OnlyRecycle) { Clear-RecycleBinAllUsers -Logger $logger; return }
    if ($OnlyTemps) { Clear-TempsAllUsers -Logger $logger; return }

    if ($OnlyWindowsUpdateCache) {
      Stop-ServiceSafe -Name 'wuauserv' -TimeoutSeconds 30 -Logger $logger
      Stop-ServiceSafe -Name 'bits'     -TimeoutSeconds 30 -Logger $logger
      Clear-SoftwareDistributionDownload -Logger $logger
      Start-ServiceSafe -Name 'wuauserv' -Logger $logger
      Start-ServiceSafe -Name 'bits'     -Logger $logger
      return
    }

    Disable-Hibernation -Logger $logger

    Stop-ServiceSafe -Name 'wuauserv' -TimeoutSeconds 30 -Logger $logger
    Stop-ServiceSafe -Name 'bits'     -TimeoutSeconds 30 -Logger $logger
    Clear-SoftwareDistributionDownload -Logger $logger
    Start-ServiceSafe -Name 'wuauserv' -Logger $logger
    Start-ServiceSafe -Name 'bits'     -Logger $logger

    Clear-TempsAllUsers -Logger $logger
    Clear-RecycleBinAllUsers -Logger $logger
    Clear-DeliveryOptimizationCache -Logger $logger

    if ($Aggressive) {
      try {
        & $logger.Log "Executando DISM StartComponentCleanup (isso pode demorar)..."
        Dism.exe /Online /Cleanup-Image /StartComponentCleanup |
          Tee-Object -FilePath $logger.LogFile -Append | Out-Null
        & $logger.Log "DISM StartComponentCleanup concluído."
      } catch { & $logger.Log ("Falha no DISM: {0}" -f $_.Exception.Message) }
    }
  } finally {
    $freeAfter = Get-FreeGB
    if ($null -ne $freeAfter -and $null -ne $freeBefore) {
      & $logger.Log ("Espaço livre depois: {0:N2} GB" -f $freeAfter)
      & $logger.Log ("Espaço liberado: {0:N2} GB" -f ($freeAfter - $freeBefore))
    }
    $endTime = Get-Date
    & $logger.Log ("=== Limpeza/Otimizações finalizado: {0} (duração: {1}) ===" -f $endTime, ($endTime - $logger.StartTime))
    Write-Host ""
    Write-Host "Concluído. Log em: $($logger.LogFile)"
  }
}

#==========================
# Funções específicas do ToolKit
#==========================

function Add-Autodesk-Regs {
    Write-Status "Adicionando registros para Autodesk..."
    reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Autodesk\ODIS" /v AllowSystemContextInstall /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Installer" /v DisableLUAInRepair /t REG_DWORD /d 1 /f | Out-Null
}

function Run-System-Repair {
    Write-Status "Executando SFC /SCANNOW..."
    sfc /scannow
    Write-Status "Executando DISM /RestoreHealth..."
    Dism /Online /Cleanup-Image /RestoreHealth
}

function Open-Massgrave {
    Write-Status "Abrindo Massgrave..."
    irm "https://get.activated.win" | iex
}

function Install-VC-Redist {
    Write-Status "Instalando pacotes VC++..."

    $env:TEMPVC = Join-Path $env:TEMP 'vc_redist'
    mkdir $env:TEMPVC -Force | Out-Null

    curl.exe -L -o "$env:TEMPVC\vc_redist.x86.exe" "https://aka.ms/vc14/vc_redist.x86.exe"
    & "$env:TEMPVC\vc_redist.x86.exe" /install /quiet /norestart

    if ($env:ProgramFiles -and ${env:ProgramFiles(x86)}) {
        curl.exe -L -o "$env:TEMPVC\vc_redist.x64.exe" "https://aka.ms/vc14/vc_redist.x64.exe"
        & "$env:TEMPVC\vc_redist.x64.exe" /install /quiet /norestart
    }

    Write-Status "Instalação dos runtimes VC++ concluída."
}

function Get-ActiveAdapterName {
    $nic = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $nic) {
        throw "Nenhum adaptador de rede ativo encontrado."
    }
    return $nic.Name
}

function Set-StaticIP {
    Write-Status "Definindo IP estático 192.168.0.77..."

    $ip      = "192.168.0.77"
    $prefix  = 24
    $gateway = "192.168.0.1"
    $dns     = "192.168.0.1"

    $nicName = Get-ActiveAdapterName

    Get-NetIPAddress -InterfaceAlias $nicName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceAlias $nicName -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $nicName -ServerAddresses $dns -ErrorAction SilentlyContinue
}

function Set-DHCPIP {
    Write-Status "Voltando IP para DHCP..."

    $nicName = Get-ActiveAdapterName
    Set-NetIPInterface -InterfaceAlias $nicName -Dhcp Enabled -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $nicName -ResetServerAddresses -ErrorAction SilentlyContinue
}

function Run-SystemCleanupBasic {
    Invoke-CleanupOptimizations
}

function Run-SystemCleanupAggressive {
    Invoke-CleanupOptimizations -Aggressive
}

function Open-RemoveWindowsAI {
    Write-Status "Abrindo RemoveWindowsAI..."
    & ([scriptblock]::Create(
        (irm "https://raw.githubusercontent.com/zoicware/RemoveWindowsAI/main/RemoveWindowsAi.ps1")
    ))
}

function Open-WinUtil-Stable {
    Write-Status "Abrindo WinUtil (Stable)..."
    irm "https://christitus.com/win" | iex
}

function Open-WinUtil-Dev {
    Write-Status "Abrindo WinUtil (Dev)..."
    irm "https://christitus.com/windev" | iex
}

#==========================
# XAML da GUI
#==========================

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Isaac Tools" Height="650" Width="900"
        WindowStartupLocation="CenterScreen"
        Background="#FF000000" Foreground="White"
        ResizeMode="NoResize" WindowStyle="None">
    <Grid Margin="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="60"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="140"/>
        </Grid.RowDefinitions>

        <!-- Cabeçalho -->
        <Border Grid.Row="0" Background="#FF000000">
            <Grid>
                <TextBlock Text="Isaac Tools" HorizontalAlignment="Center" VerticalAlignment="Center"
                           FontSize="28" FontWeight="Bold" Foreground="#00FFFF"/>
            </Grid>
        </Border>

        <!-- Conteúdo -->
        <ScrollViewer Grid.Row="1" Margin="40,10,40,10" VerticalScrollBarVisibility="Auto">
            <StackPanel>

                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkAutodeskRegs" IsChecked="False" VerticalAlignment="Center"/>
                    <TextBlock Text="Adicionar registros Autodesk (AllowSystemContextInstall / DisableLUAInRepair)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkSystemRepair" VerticalAlignment="Center"/>
                    <TextBlock Text="Executar reparo de sistema (sfc /scannow + DISM /RestoreHealth)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkVC" VerticalAlignment="Center"/>
                    <TextBlock Text="Instalar pacotes VC++ mais recentes (vc_redist x86/x64)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkStaticIP" VerticalAlignment="Center"/>
                    <TextBlock Text="Definir IP estático 192.168.0.77 (gateway/DNS 192.168.0.1) no adaptador ativo"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkDHCPIP" VerticalAlignment="Center"/>
                    <TextBlock Text="Definir IP automático (DHCP) no adaptador ativo"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
                    <CheckBox x:Name="chkCleanupBasic" VerticalAlignment="Center"/>
                    <TextBlock Text="Limpeza básica (Temp, Lixeira, cache Windows Update, hibernação)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkCleanupAggressive" VerticalAlignment="Center"/>
                    <TextBlock Text="Limpeza agressiva (inclui DISM StartComponentCleanup – pode demorar)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

            </StackPanel>
        </ScrollViewer>

        <!-- Rodapé -->
        <Grid Grid.Row="2" Margin="20,0,20,10">
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="40"/>
            </Grid.RowDefinitions>

            <!-- Linha de botões de ferramentas externas -->
            <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Left">
                <Button x:Name="btnOpenRWAI" Margin="0,10,10,0" Height="30"
                        Content="Abrir RemoveWindowsAI" Background="#FF333333" Foreground="White"
                        FontSize="14"/>
                <Button x:Name="btnOpenWinUtil" Margin="0,10,10,0" Height="30"
                        Content="Abrir WinUtil" Background="#FF333333" Foreground="White"
                        FontSize="14"/>
                <Button x:Name="btnOpenWinUtilDev" Margin="0,10,10,0" Height="30"
                        Content="Abrir WinUtil (Dev)" Background="#FF333333" Foreground="White"
                        FontSize="14"/>
                <Button x:Name="btnOpenMassgrave" Margin="0,10,10,0" Height="30"
                        Content="Abrir Massgrave" Background="#FF333333" Foreground="White"
                        FontSize="14"/>
            </StackPanel>

            <!-- Log + barra de progresso -->
            <Grid Grid.Row="1" Margin="0,5,0,5">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="20"/>
                </Grid.RowDefinitions>

                <TextBox x:Name="txtLog"
                         Grid.Row="0"
                         Margin="0,0,0,5"
                         Background="#FF111111"
                         Foreground="White"
                         FontSize="12"
                         HorizontalScrollBarVisibility="Auto"
                         VerticalScrollBarVisibility="Auto"
                         IsReadOnly="True"
                         TextWrapping="Wrap"/>

                <ProgressBar x:Name="pbStatus"
                             Grid.Row="1"
                             Height="16"
                             Minimum="0"
                             Maximum="100"
                             IsIndeterminate="False"
                             Visibility="Collapsed"/>
            </Grid>

            <!-- Botões principais -->
            <Grid Grid.Row="2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Button x:Name="btnCancel" Grid.Column="1" Margin="0,0,10,0" Width="120" Height="30"
                        Content="Cancelar" Background="#FF990000" Foreground="White" FontSize="14"/>

                <Button x:Name="btnApply" Grid.Column="2" Margin="0,0,0,0" Width="120" Height="30"
                        Content="Aplicar" Background="#FF00AA00" Foreground="White" FontSize="14"/>
            </Grid>
        </Grid>
    </Grid>
</Window>
"@

#==========================
# Carregar XAML e ligar eventos
#==========================

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$chkAutodeskRegs   = $window.FindName("chkAutodeskRegs")
$chkSystemRepair   = $window.FindName("chkSystemRepair")
$chkVC             = $window.FindName("chkVC")
$chkStaticIP       = $window.FindName("chkStaticIP")
$chkDHCPIP         = $window.FindName("chkDHCPIP")
$chkCleanupBasic   = $window.FindName("chkCleanupBasic")
$chkCleanupAggress = $window.FindName("chkCleanupAggressive")

$btnApply          = $window.FindName("btnApply")
$btnCancel         = $window.FindName("btnCancel")
$btnOpenRWAI       = $window.FindName("btnOpenRWAI")
$btnOpenWinUtil    = $window.FindName("btnOpenWinUtil")
$btnOpenWinUtilDev = $window.FindName("btnOpenWinUtilDev")
$btnOpenMassgrave  = $window.FindName("btnOpenMassgrave")
$txtLog            = $window.FindName("txtLog")
$pbStatus          = $window.FindName("pbStatus")

# Função simples para logar também na TextBox
function Add-GuiLog {
    param([string]$Message)
    $window.Dispatcher.Invoke([action]{
        $txtLog.AppendText("$Message`r`n")
        $txtLog.ScrollToEnd()
    })
}

$btnCancel.Add_Click({ $window.Close() })

$btnOpenRWAI.Add_Click({
    try {
        Add-GuiLog "Abrindo RemoveWindowsAI..."
        Open-RemoveWindowsAI
    } catch {
        [System.Windows.MessageBox]::Show(
            "Erro ao abrir RemoveWindowsAI:`n$($_.Exception.Message)",
            "Isaac Tools",'OK','Error') | Out-Null
    }
})

$btnOpenWinUtil.Add_Click({
    try {
        Add-GuiLog "Abrindo WinUtil (Stable)..."
        Open-WinUtil-Stable
    } catch {
        [System.Windows.MessageBox]::Show(
            "Erro ao abrir WinUtil:`n$($_.Exception.Message)",
            "Isaac Tools",'OK','Error') | Out-Null
    }
})

$btnOpenWinUtilDev.Add_Click({
    try {
        Add-GuiLog "Abrindo WinUtil (Dev)..."
        Open-WinUtil-Dev
    } catch {
        [System.Windows.MessageBox]::Show(
            "Erro ao abrir WinUtil (Dev):`n$($_.Exception.Message)",
            "Isaac Tools",'OK','Error') | Out-Null
    }
})

$btnOpenMassgrave.Add_Click({
    try {
        Add-GuiLog "Abrindo Massgrave..."
        Open-Massgrave
    } catch {
        [System.Windows.MessageBox]::Show(
            "Erro ao abrir Massgrave:`n$($_.Exception.Message)",
            "Isaac Tools",'OK','Error') | Out-Null
    }
})

$btnApply.Add_Click({
    $pbStatus.Visibility = 'Visible'
    $pbStatus.IsIndeterminate = $true
    Add-GuiLog "Iniciando operações selecionadas..."

    try {
        if ($chkAutodeskRegs.IsChecked)   { Add-GuiLog "Aplicando registros Autodesk..."; Add-Autodesk-Regs }
        if ($chkSystemRepair.IsChecked)   { Add-GuiLog "Executando reparo de sistema..."; Run-System-Repair }
        if ($chkVC.IsChecked)             { Add-GuiLog "Instalando VC++ Redistributables..."; Install-VC-Redist }
        if ($chkStaticIP.IsChecked)       { Add-GuiLog "Definindo IP estático..."; Set-StaticIP }
        if ($chkDHCPIP.IsChecked)         { Add-GuiLog "Voltando IP para DHCP..."; Set-DHCPIP }
        if ($chkCleanupBasic.IsChecked)   { Add-GuiLog "Executando limpeza básica..."; Run-SystemCleanupBasic }
        if ($chkCleanupAggress.IsChecked) { Add-GuiLog "Executando limpeza agressiva..."; Run-SystemCleanupAggressive }

        Add-GuiLog "Operações concluídas."
        [System.Windows.MessageBox]::Show("Operações concluídas.","Isaac Tools",
            'OK','Information') | Out-Null
    }
    catch {
        Add-GuiLog "Erro: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Erro durante a execução:`n$($_.Exception.Message)",
            "Isaac Tools",'OK','Error') | Out-Null
    }
    finally {
        $pbStatus.IsIndeterminate = $false
        $pbStatus.Visibility = 'Collapsed'
    }
})

#==========================
# Execução
#==========================

if ($nonInteractive) {
    $window.ShowDialog() | Out-Null
} else {
    $window.ShowDialog() | Out-Null
}
