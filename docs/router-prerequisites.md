# Pré-requisitos da estação roteadora

Use este modo quando a estação Windows não terá Tailscale local, mas precisa alcançar o servidor RustDesk privado por outro equipamento da mesma LAN.

## Topologia

```text
Windows 11 ── LAN ── estação roteadora ── Tailscale ── 100.105.235.114
                    192.168.1.10
```

O Darckware Remoto cria no Windows somente a rota persistente:

```text
100.105.235.114/32 via <IPv4-LAN-do-roteador>
```

Ele nunca redireciona toda a faixa CGNAT `100.64.0.0/10`.

## Requisitos obrigatórios

A estação roteadora precisa:

1. estar conectada simultaneamente à LAN do cliente e à tailnet;
2. manter endereço IPv4 LAN estável ou reservado por DHCP;
3. encaminhar pacotes IPv4 entre a LAN e a interface Tailscale;
4. fornecer caminho de retorno para a sub-rede do cliente, ou aplicar source NAT de forma deliberada;
5. permitir no firewall o tráfego necessário para `100.105.235.114`;
6. estar autorizada pela política/ACL da tailnet a alcançar o servidor;
7. permitir TCP `21116` e `21117` até o servidor RustDesk.

O instalador testa somente TCP. UDP `21116` não é confirmado por esse preflight.

## Verificação antes da instalação

Na estação Windows, substitua o exemplo pelo IPv4 LAN real do roteador:

```powershell
Find-NetRoute -RemoteIPAddress '192.168.1.10'
Test-NetConnection -ComputerName '100.105.235.114' -Port 21116
Test-NetConnection -ComputerName '100.105.235.114' -Port 21117
```

No roteador, confirme:

- encaminhamento IPv4 habilitado de forma persistente;
- rota/masquerade de retorno coerente com a topologia;
- firewall ativo com regras mínimas;
- `tailscale status` indicando conexão;
- política Tailscale autorizando o destino.

Os comandos exatos variam conforme Windows, Linux, appliance e firewall. Não copie regras de NAT genéricas sem validar a topologia, pois elas podem ampliar acesso indevidamente.

## Conflitos de rota

- rota inexistente: o instalador propõe criar;
- rota idêntica: reutiliza sem mudança;
- rota diferente anteriormente gerenciada: exige confirmação para substituir;
- rota diferente não gerenciada: interrompe e preserva a configuração existente.

Consulte [Solução de problemas](troubleshooting.md) para inspeção e remoção segura.
