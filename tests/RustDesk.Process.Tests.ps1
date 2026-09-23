BeforeAll { Import-Module "$PSScriptRoot/../src/RustDesk.psm1" -Force }

Describe 'RustDesk installer process lifetime' {
    It 'continues after the installer exits while its background child is still running' {
        $fixture = Join-Path $TestDrive 'installer-fixture.exe'
        Add-Type -OutputAssembly $fixture -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public class InstallerFixture {
    public static void Main(string[] args) {
        if (args.Length > 0 && args[0] == "--worker") { Thread.Sleep(8000); return; }
        string executable = System.Reflection.Assembly.GetExecutingAssembly().Location;
        var start = new ProcessStartInfo(executable, "--worker");
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        var child = Process.Start(start);
        File.WriteAllText(executable + ".pid", child.Id.ToString());
    }
}
'@
        $pathChecks = [Collections.Queue]::new()
        $pathChecks.Enqueue($false)
        $pathChecks.Enqueue($true)
        Mock Test-Path -ModuleName RustDesk { $pathChecks.Dequeue() }
        Mock Wait-RustDeskService -ModuleName RustDesk {}
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Install-RustDesk -InstallerPath $fixture
            $watch.Stop()
            $result.Installed | Should -BeTrue
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
        }
        finally {
            if ([IO.File]::Exists($fixture + '.pid')) {
                $childId = [int][IO.File]::ReadAllText($fixture + '.pid')
                Stop-Process -Id $childId -ErrorAction SilentlyContinue
            }
        }
    }
}
