# Identifica o chip de um adaptador USB-Ethernet conectado a este PC (Windows).
# Uso:  pwsh -File scripts\identificar-adaptador.ps1  [-Todos]
#   -Todos  lista todos os dispositivos USB, não só os de rede.
param([switch]$Todos)

$chips = @{
    '0BDA:8152' = 'Realtek RTL8152 (100M) -> r8152'
    '0BDA:8153' = 'Realtek RTL8153 (1G) -> r8152'
    '0BDA:8156' = 'Realtek RTL8156 (2.5G) -> r8152 (kernel recente)'
    '17EF:7205' = 'Realtek RTL8153 (Lenovo) -> r8152'
    '045E:07C6' = 'Realtek RTL8153 (Microsoft) -> r8152'
    '13B1:0041' = 'Realtek RTL8153 (Linksys) -> r8152'
    '0B95:1790' = 'ASIX AX88179/AX88178A (1G) -> ax88179_178a'
    '0B95:7720' = 'ASIX AX88772 (100M) -> asix'
    '0B95:772A' = 'ASIX AX88772A (100M) -> asix'
    '0B95:772B' = 'ASIX AX88772B (100M) -> asix'
    '0B95:1780' = 'ASIX AX88178 (1G) -> asix'
    '0424:EC00' = 'SMSC LAN9512/9514 -> smsc95xx'
    '0424:7500' = 'SMSC LAN7500 -> smsc75xx'
    '0424:7800' = 'Microchip LAN7800 -> lan78xx'
    '0FE6:9700' = 'CoreChips SR9700 (adaptador barato) -> sr9700'
    '0A46:9601' = 'Davicom DM9601 -> dm9601'
}

$vistos = @{}
$lista = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})' } |
    ForEach-Object {
        $null = $_.InstanceId -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})'
        $id = "$($Matches[1]):$($Matches[2])"
        $chip = $chips[$id]
        if (-not $Todos -and -not $chip -and $_.Class -ne 'Net') { return }
        if ($vistos[$id]) { return }
        $vistos[$id] = $true
        [pscustomobject]@{
            'VID:PID' = $id
            Nome      = $_.FriendlyName
            Classe    = $_.Class
            Chip      = if ($chip) { $chip } else { 'desconhecido' }
        }
    }

if ($lista) {
    $lista | Format-Table -AutoSize -Wrap
} else {
    Write-Host 'Nenhum adaptador USB de rede encontrado. Conecte o adaptador ou use -Todos.'
}
