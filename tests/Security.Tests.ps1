BeforeAll { Import-Module "$PSScriptRoot/../src/Security.psm1" -Force }

Describe 'Protect-LogText' {
    It 'redacts Tailscale auth keys and named password fields' {
        $text = 'auth=tskey-auth-k123 password=SuperSecret rustdeskPassword=OtherSecret'
        $safe = Protect-LogText -Text $text
        $safe | Should -Not -Match 'tskey-|SuperSecret|OtherSecret'
        $safe | Should -Match '\[REDACTED\]'
    }

    It 'redacts quoted named values that contain spaces' {
        $text = "password=`"Super Secret Value`" authkey='Another Hidden Value' rustdeskPassword=UnquotedSecret"
        $safe = Protect-LogText -Text $text
        $safe | Should -Not -Match 'Super|Secret|Value|Another|Hidden|UnquotedSecret'
        $safe | Should -Match 'password=\[REDACTED\].*authkey=\[REDACTED\].*rustdeskPassword=\[REDACTED\]'
    }
}

Describe 'protected secret files' {
    It 'writes the secret and removes it deterministically' {
        $secret = ConvertTo-SecureString 'tskey-auth-test' -AsPlainText -Force
        $path = $null
        try {
            $path = New-ProtectedSecretFile -Secret $secret -Directory $TestDrive
            Test-Path $path | Should -BeTrue
            Get-Content -Raw $path | Should -Be 'tskey-auth-test'
        }
        finally {
            if ($path) {
                Remove-SecretFile -Path $path
            }
        }
        Test-Path $path | Should -BeFalse
    }

    It 'allows repeated cleanup of the same path' {
        $path = Join-Path $TestDrive 'already-removed.secret'
        Remove-SecretFile -Path $path
        Remove-SecretFile -Path $path
        Test-Path $path | Should -BeFalse
    }

    It 'limits the secret file ACL to SYSTEM and built-in Administrators' {
        $secret = ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force
        $path = New-ProtectedSecretFile -Secret $secret -Directory $TestDrive
        try {
            $sids = @((Get-Acl -LiteralPath $path).Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
            $sids | Should -HaveCount 2
            $sids | Should -Contain 'S-1-5-18'
            $sids | Should -Contain 'S-1-5-32-544'
        }
        finally {
            Remove-SecretFile -Path $path
        }
    }
}
