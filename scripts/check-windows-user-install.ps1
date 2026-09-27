# Native acceptance only: an ephemeral standard account on the GitHub runner.
param(
    [string]$CandidateDirectory,
    [string]$UpgradeDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$AsStandardUser
)
$ErrorActionPreference = 'Stop'

function Get-BundleFileHash([string]$Path) {
    # Keep hashing independent of module discovery in the clean user session.
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($hash.ComputeHash($stream)) }
        finally { $stream.Dispose() }
    } finally { $hash.Dispose() }
}

if ($AsStandardUser) {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Installer acceptance must run without administrator rights'
        }
        $privileges = & "$env:SystemRoot\System32\whoami.exe" /priv
        if ($LASTEXITCODE -ne 0 -or ($privileges -match 'SeCreateSymbolicLinkPrivilege')) {
            throw 'Expected a user without symbolic-link privilege'
        }
        $development = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
        if ($development.AllowDevelopmentWithoutDevLicense -eq 1) {
            throw 'Developer Mode must be disabled for this acceptance check'
        }
        $env:PATH = ''
        $base = (Get-ChildItem "$OutputDirectory\base" -Recurse -Filter isled.exe).FullName
        $next = (Get-ChildItem "$OutputDirectory\upgrade" -Recurse -Filter isled.exe).FullName
        $root = Join-Path $OutputDirectory 'standard user storage'
        $versions = @()
        foreach ($program in @($base, $next, $base)) {
            $wire = & $program install --directory $root --json
            if ($LASTEXITCODE -ne 0) { throw "Installation failed: $wire" }
            $paths = $wire | ConvertFrom-Json
            $versions += $paths.version
            if ($paths.executable -ne "$root\current\isled.exe" -or
                $paths.skill_file -ne "$root\current\skill\SKILL.md") {
                throw 'Installer did not show stable current paths'
            }
            if ((Get-Item "$root\current").LinkType -ne 'Junction') {
                throw 'Expected a directory junction'
            }
            $actual = & $paths.executable --version
            if ($LASTEXITCODE -ne 0 -or $actual -ne "isled $($paths.version)") {
                throw 'Selected executable did not run'
            }
            foreach ($name in @('isled.exe', 'LICENSE', 'bundle.json', 'skill\SKILL.md',
                                'skill\references\mutations.md', 'skill\references\recovery.md')) {
                $source = Get-BundleFileHash (Join-Path (Split-Path $program) $name)
                $installed = Get-BundleFileHash (Join-Path "$root\current" $name)
                if ($source -ne $installed) { throw "Selected bundle differs: $name" }
            }
        }
        if ($versions[0] -eq $versions[1] -or $versions[0] -ne $versions[2]) {
            throw 'Upgrade and rollback did not select the expected versions'
        }
        # Simulate interruption between the two Windows renames, then retry.
        Move-Item "$root\current" "$root\.previous-current"
        & $base install --directory $root --json | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$root\current\skill\SKILL.md")) {
            throw 'Interrupted junction activation did not recover'
        }
        @{ result = 'passed'; user = $identity.Name; administrator = $false;
           symbolic_link_privilege = $false; developer_mode = $false;
           versions = $versions; paths = $paths; privileges = $privileges } |
            ConvertTo-Json -Depth 5 | Set-Content "$OutputDirectory\receipt.json" -Encoding UTF8
        exit 0
    } catch {
        $_ | Out-String | Set-Content "$OutputDirectory\failure.txt"
        exit 1
    }
}

$user = 'isled-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$work = Join-Path $env:PUBLIC $user
$created = $false
$developmentKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$developmentName = 'AllowDevelopmentWithoutDevLicense'
$developmentSettings = Get-ItemProperty $developmentKey -ErrorAction SilentlyContinue
$developmentProperty = if ($developmentSettings) { $developmentSettings.PSObject.Properties[$developmentName] }
$developmentChanged = $false
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    foreach ($entry in @(@($CandidateDirectory, 'base'), @($UpgradeDirectory, 'upgrade'))) {
        $archives = @(Get-ChildItem $entry[0] -Filter '*-x86_64-pc-windows-msvc.zip')
        if ($archives.Count -ne 1) { throw 'Expected one native Windows archive' }
        Expand-Archive $archives[0].FullName (Join-Path $work $entry[1])
    }
    $script = Join-Path $work 'check.ps1'
    Copy-Item $PSCommandPath $script
    $password = ConvertTo-SecureString ([guid]::NewGuid().ToString('N') + 'aB9!') -AsPlainText -Force
    $account = New-LocalUser -Name $user -Password $password
    $created = $true
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $account
    $acl = Get-Acl $work
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $account.SID, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl $work $acl
    $credential = [Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$user", $password)
    # Hosted Windows images enable Developer Mode. Tighten the disposable VM's
    # setting for this check; the child still requires it to be disabled.
    if ($developmentProperty -and $developmentProperty.Value -eq 1) {
        Set-ItemProperty -Path $developmentKey -Name $developmentName -Value 0
        $developmentChanged = $true
    }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Credential $credential -LoadUserProfile -Wait -PassThru `
        -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -AsStandardUser -OutputDirectory `"$work`""
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Copy-Item "$work\*.json", "$work\*.txt" $OutputDirectory -ErrorAction SilentlyContinue
    if ($process.ExitCode -ne 0) {
        if (Test-Path "$OutputDirectory\failure.txt") { Get-Content "$OutputDirectory\failure.txt" }
        throw "Standard-user installation failed; inspect $OutputDirectory"
    }
    Get-Content "$OutputDirectory\receipt.json"
} finally {
    if ($developmentChanged) {
        Set-ItemProperty -Path $developmentKey -Name $developmentName -Value $developmentProperty.Value
    }
    if ($created) { Remove-LocalUser -Name $user }
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
}
