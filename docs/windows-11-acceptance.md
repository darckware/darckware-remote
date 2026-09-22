# Aceitação em Windows 11

Este roteiro precisa ser executado em uma VM Windows 11 x86-64 limpa antes de uma release ser classificada como pronta para produção.

## Evidência da execução

- Data:
- Responsável:
- Versão/commit:
- Imagem do Windows:
- Snapshot inicial:
- Tailnet/ambiente de teste:

Não registre auth keys nem senhas neste documento.

## Matriz obrigatória

| Caso | Resultado esperado | Status |
|---|---|---|
| Tailscale somente | cliente conectado, IP tailnet atribuído, chave temporária removida | Pendente |
| RustDesk + Tailscale local existente | configuração aplicada, serviço Running, ID numérico | Pendente |
| RustDesk por roteador | rota `/32`, duas portas TCP alcançáveis, ID numérico | Pendente |
| Tailscale + RustDesk | Tailscale antes do RustDesk, nenhuma rota estática | Pendente |
| Auth key inválida | falha redigida, nenhum RustDesk dependente instalado | Pendente |
| Roteador inacessível | falha antes do RustDesk | Pendente |
| TCP 21116/21117 bloqueada | falha antes do RustDesk | Pendente |
| Download modificado | hash falha antes da execução | Pendente |
| UAC cancelado | código 1223, nenhuma alteração | Pendente |
| Segunda execução de cada sucesso | estado idempotente e sem duplicação | Pendente |

## Critérios de aprovação

- todos os casos bem-sucedidos produzem resultado estruturado e log redigido;
- todos os casos negativos falham antes de mudanças dependentes;
- nenhuma credencial aparece no log, estado, tela de revisão ou saída;
- a interface funciona com teclado, escala de exibição comum e foco visível;
- o snapshot pode ser restaurado e os resultados são anexados à release.
