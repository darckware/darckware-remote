# Solução de problemas

Execute os comandos desta página em PowerShell elevado.

## Localizar logs e estado

```powershell
$stateRoot = Join-Path $env:ProgramData 'Darckware\RustDeskInstaller'
Get-Content (Join-Path $stateRoot 'installer.log') -Tail 100
Get-Content (Join-Path $stateRoot 'state.json') -Raw
```

O log deve conter somente dados não secretos. Se encontrar uma credencial real, interrompa o uso, revogue-a e abra um incidente.

## UAC cancelado

O código `1223` indica que o operador cancelou o UAC ou fechou o assistente. Execute novamente `install.cmd` e confira o caminho antes de aceitar a elevação.

## Falha de download, hash ou assinatura

O instalador falha antes de executar o arquivo quando URL, SHA-256, Authenticode ou fornecedor divergem.

1. Não desative a validação.
2. Exclua somente o cache `downloads` dentro da pasta de estado.
3. Confirme acesso HTTPS sem proxy que substitua binários.
4. Verifique se o manifesto ainda aponta para a versão aprovada.
5. Para atualizar versões, altere URL e hash de forma explícita e execute toda a suíte.

## Diagnóstico do Tailscale

```powershell
& "$env:ProgramFiles\Tailscale\tailscale.exe" status --json
Get-Service -Name Tailscale
```

Se a autenticação falhar, revogue a chave utilizada e gere outra chave one-off, pré-aprovada e com tags mínimas. Não cole a chave em tickets ou logs.

## Diagnóstico do RustDesk

```powershell
Get-Service -Name RustDesk
& "$env:ProgramFiles\RustDesk\rustdesk.exe" --get-id
Test-NetConnection -ComputerName '100.105.235.114' -Port 21116
Test-NetConnection -ComputerName '100.105.235.114' -Port 21117
```

Uma porta bloqueada no modo roteador interrompe a instalação antes da etapa RustDesk.

## Inspecionar a rota gerenciada

```powershell
Get-NetRoute -DestinationPrefix '100.105.235.114/32' |
  Format-Table DestinationPrefix, NextHop, InterfaceIndex, PolicyStore
```

Compare o gateway com `state.json`. Não remova uma rota cujo destino e gateway não correspondam ao registro gerenciado.

### Remoção manual segura

Depois de validar destino, gateway e interface, forneça os três valores exatos:

```powershell
Remove-NetRoute `
  -DestinationPrefix '100.105.235.114/32' `
  -NextHop '192.168.1.10' `
  -InterfaceIndex 7 `
  -PolicyStore PersistentStore
```

O PowerShell solicitará confirmação. Substitua o gateway e a interface pelos valores realmente inspecionados.

## Reexecução

Uma segunda execução é suportada. Se ela divergir da primeira:

- confirme que o hostname Tailscale é válido e único;
- verifique se a estação já está conectada à tailnet esperada;
- confira se uma rota foi alterada fora do instalador;
- confirme que os serviços Tailscale e RustDesk estão em execução;
- consulte o erro redigido no final de `installer.log`.

## Desinstalação

Remova os aplicativos por **Configurações > Aplicativos > Aplicativos instalados**. O Darckware Remoto não remove automaticamente software, estado ou rotas durante uma desinstalação de fornecedor.
