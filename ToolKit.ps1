param(
    [switch]$revertMode,
    [switch]$backupMode,
    [switch]$nonInteractive
)

Add-Type -AssemblyName PresentationFramework

#==========================
# Funções utilitárias
#==========================
function Write-Status {
    param(
        [string]$msg
    )
    Write-Host "[ + ] $msg"
}

#==========================
# Funções de ação
#==========================

function Add-Autodesk-Regs {
    Write-Status -msg "Adicionando registros para Autodesk..."
    reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Autodesk\ODIS" /v AllowSystemContextInstall /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Installer" /v DisableLUAInRepair /t REG_DWORD /d 1 /f | Out-Null
}

function Run-System-Repair {
    Write-Status -msg "Executando SFC /SCANNOW..."
    sfc /scannow
    Write-Status -msg "Executando DISM /RestoreHealth..."
    Dism /Online /Cleanup-Image /RestoreHealth
}

function Open-Massgrave {
    Write-Status -msg "Abrindo Massgrave (get.activated.win)..."
    irm https://get.activated.win | iex
}

function Install-VC-Redist {
    Write-Status -msg "Instalando pacotes VC++ mais recentes..."

    $env:TEMPVC = Join-Path $env:TEMP 'vc_redist'
    mkdir $env:TEMPVC -Force | Out-Null

    curl.exe -L -o "$env:TEMPVC\vc_redist.x86.exe" https://aka.ms/vc14/vc_redist.x86.exe
    & "$env:TEMPVC\vc_redist.x86.exe" /install /quiet /norestart

    # Aqui estava o erro: use ${env:ProgramFiles(x86)}
    if ($env:ProgramFiles -and ${env:ProgramFiles(x86)}) {
        curl.exe -L -o "$env:TEMPVC\vc_redist.x64.exe" https://aka.ms/vc14/vc_redist.x64.exe
        & "$env:TEMPVC\vc_redist.x64.exe" /install /quiet /norestart
    }

    Write-Status -msg "Instalação dos runtimes VC++ concluída."
}

function Set-StaticIP {
    Write-Status -msg "Definindo IP estático 192.168.0.77..."
    $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $nic) {
        Write-Status -msg "Nenhum adaptador ativo encontrado."
        return
    }

    # Ajuste gateway/DNS conforme sua rede
    $ip = '192.168.0.77'
    $prefix = 24
    $gateway = '192.168.0.1'
    $dns = '192.168.0.1'

    # Remove IPs antigos IPv4
    Get-NetIPAddress -InterfaceAlias $nic.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceAlias $nic.Name -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $nic.Name -ServerAddresses $dns
}

function Set-DHCPIP {
    Write-Status -msg "Voltando IP para DHCP..."
    $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $nic) {
        Write-Status -msg "Nenhum adaptador ativo encontrado."
        return
    }

    Set-NetIPInterface -InterfaceAlias $nic.Name -Dhcp Enabled -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $nic.Name -ResetServerAddresses -ErrorAction SilentlyContinue
}

function Open-RemoveWindowsAI {
    Write-Status -msg "Abrindo RemoveWindowsAI..."
    & ([scriptblock]::Create(
        (irm "https://raw.githubusercontent.com/zoicware/RemoveWindowsAI/main/RemoveWindowsAi.ps1")
    ))
}

#==========================
# XAML da GUI (estilo inspirado no RemoveWindowsAI)
#==========================
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ToolKit Isaacs" Height="600" Width="850"
        WindowStartupLocation="CenterScreen"
        Background="#FF000000" Foreground="White"
        ResizeMode="NoResize" WindowStyle="None">
    <Grid Margin="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="60"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="60"/>
        </Grid.RowDefinitions>

        <!-- Cabeçalho -->
        <Border Grid.Row="0" Background="#FF000000">
            <Grid>
                <TextBlock Text="ToolKit Isaacs" HorizontalAlignment="Center" VerticalAlignment="Center"
                           FontSize="28" FontWeight="Bold" Foreground="#00FFFF"/>
            </Grid>
        </Border>

        <!-- Conteúdo rolável -->
        <ScrollViewer Grid.Row="1" Margin="40,10,40,10" VerticalScrollBarVisibility="Auto">
            <StackPanel>

                <!-- 1 - Autodesk Regs -->
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkAutodeskRegs" IsChecked="True" VerticalAlignment="Center"/>
                    <TextBlock Text="Adicionar registros Autodesk (AllowSystemContextInstall / DisableLUAInRepair)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- 2 - Reparos SFC/DISM -->
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkSystemRepair" VerticalAlignment="Center"/>
                    <TextBlock Text="Executar reparo de sistema (sfc /scannow + DISM /RestoreHealth)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- 3 - Massgrave -->
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkMassgrave" VerticalAlignment="Center"/>
                    <TextBlock Text="Abrir Massgrave (irm https://get.activated.win | iex)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- 4 - VC++ -->
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkVC" VerticalAlignment="Center"/>
                    <TextBlock Text="Instalar pacotes VC++ mais recentes (vc_redist x86/x64)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- 5 - IP estático -->
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkStaticIP" VerticalAlignment="Center"/>
                    <TextBlock Text="Definir IP estático 192.168.0.77 (gateway/DNS 192.168.0.1)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- 6 - IP DHCP -->
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                    <CheckBox x:Name="chkDHCPIP" VerticalAlignment="Center"/>
                    <TextBlock Text="Definir IP automático (DHCP)"
                               Margin="10,0,0,0" FontSize="16" VerticalAlignment="Center"/>
                </StackPanel>

            </StackPanel>
        </ScrollViewer>

        <!-- Rodapé -->
        <Grid Grid.Row="2" Margin="20,0,20,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <Button x:Name="btnOpenRWAI" Grid.Column="0" Margin="0,10,10,0" Height="40"
                    Content="Abrir RemoveWindowsAI" Background="#FF333333" Foreground="White"
                    FontSize="14"/>

            <Button x:Name="btnCancel" Grid.Column="1" Margin="0,10,10,0" Width="120" Height="40"
                    Content="Cancelar" Background="#FF990000" Foreground="White" FontSize="14"/>

            <Button x:Name="btnApply" Grid.Column="2" Margin="0,10,0,0" Width="120" Height="40"
                    Content="Aplicar" Background="#FF00AA00" Foreground="White" FontSize="14"/>

        </Grid>
    </Grid>
</Window>
"@


#==========================
# Carregar XAML
#==========================
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Controles
$chkAutodeskRegs = $window.FindName("chkAutodeskRegs")
$chkSystemRepair = $window.FindName("chkSystemRepair")
$chkMassgrave    = $window.FindName("chkMassgrave")
$chkVC           = $window.FindName("chkVC")
$chkStaticIP     = $window.FindName("chkStaticIP")
$chkDHCPIP       = $window.FindName("chkDHCPIP")

$btnApply        = $window.FindName("btnApply")
$btnCancel       = $window.FindName("btnCancel")
$btnOpenRWAI     = $window.FindName("btnOpenRWAI")

#==========================
# Eventos de botões
#==========================
$btnCancel.Add_Click({
    $window.Close()
})

$btnOpenRWAI.Add_Click({
    Open-RemoveWindowsAI
    $window.Close()
})

$btnApply.Add_Click({
    if ($chkAutodeskRegs.IsChecked) { Add-Autodesk-Regs }
    if ($chkSystemRepair.IsChecked) { Run-System-Repair }
    if ($chkMassgrave.IsChecked)    { Open-Massgrave }
    if ($chkVC.IsChecked)           { Install-VC-Redist }
    if ($chkStaticIP.IsChecked)     { Set-StaticIP }
    if ($chkDHCPIP.IsChecked)       { Set-DHCPIP }

    [System.Windows.MessageBox]::Show("Operações concluídas.","Certare Tools",
        'OK','Information') | Out-Null
})

#==========================
# Execução
#==========================
if ($nonInteractive) {
    # Modo não interativo (executa tudo marcado por padrão)
    Add-Autodesk-Regs
    Run-System-Repair
    Install-VC-Redist
    # IPs e Massgrave só em modo interativo por segurança
}
else {
    $window.ShowDialog() | Out-Null
}
