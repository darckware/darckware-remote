BeforeAll {
    Import-Module "$PSScriptRoot/../src/RustDesk.psm1" -Force
    $script:commandFixture = Join-Path $TestDrive 'rustdesk-gui-fixture.exe'
    Add-Type -OutputAssembly $script:commandFixture -OutputType WindowsApplication -TypeDefinition @'
using System;
using System.Threading;
public class RustDeskCommandFixture {
    public static int Main(string[] args) {
        Thread.Sleep(200);
        Console.Error.WriteLine("diagnostic output");
        if (args[0] == "--get-id") { Console.WriteLine("123456789"); return 0; }
        if (args[0] == "--fail") { return 7; }
        Console.WriteLine(args.Length);
        Console.WriteLine(args[1]);
        return 0;
    }
}
'@
}

Describe 'RustDesk GUI command output' {
    It 'waits for a GUI executable and reads its ID from stdout only' {
        Get-RustDeskId -ExecutablePath $script:commandFixture | Should -Be '123456789'
    }

    It 'returns the GUI process exit code instead of a stale native exit code' {
        $result = & (Get-Module RustDesk) { param($Path)
            Invoke-RustDeskCommand -ExecutablePath $Path -Arguments @('--fail')
        } $script:commandFixture
        $result.ExitCode | Should -Be 7
    }

    It 'preserves spaces quotes and trailing backslashes in a single argument' {
        $argument = 'test "quoted" value\'
        $result = & (Get-Module RustDesk) { param($Path, $Value)
            Invoke-RustDeskCommand -ExecutablePath $Path -Arguments @('--echo', $Value)
        } $script:commandFixture $argument
        $result.ExitCode | Should -Be 0
        ($result.Output -split '\r?\n')[0] | Should -Be '2'
        ($result.Output -split '\r?\n')[1] | Should -Be $argument
    }
}
