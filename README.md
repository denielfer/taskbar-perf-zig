# TaskbarPerf Zig

Minigráficos de CPU, RAM, GPU, disco e rede sobre a barra de tarefas principal do Windows. Abra `zig-out\bin\TaskbarPerfZig.exe`.

> **Outra versão:** existe uma implementação independente da mesma ideia em C++20 com Win32 e Direct2D, no repositório [**`taskbar-perf`**](https://github.com/denielfer/taskbar-perf) (*TaskbarPerf*). Ela fica perto do relógio por padrão e tem menu para escolher métricas, monitor e posição, além de iniciar com o Windows. As duas não compartilham código nem configuração.

O programa acompanha a barra via `SetWinEventHook` e timer adaptativo, mede o espaço livre entre os botões na metade esquerda por UI Automation e se oculta quando nenhum bloco cabe ou quando um aplicativo em tela cheia ocupa o mesmo monitor. Coleta e desenho também pausam quando a tela desliga ou a sessão é bloqueada.

- **Clique esquerdo** em um minigráfico para abrir ou recolher o painel **Desempenho**. Ele mostra uso e frequência da CPU, memória usada e total, atividade por disco, envio e recebimento por interface ativa e uso/temperatura por GPU. Os tipos de disco e as temperaturas aparecem quando o Windows ou o driver fornecem os dados.
- **Clique direito** em um minigráfico para acessar **Abrir resumo** e **Encerrar TaskbarPerf**. O ícone na bandeja oferece os mesmos controles e pode estar sob a seta de ícones ocultos.
- Feche o painel pelo **×**, pela tecla **Esc** ou clicando em outra janela. Use a roda do mouse ou as teclas de navegação (`↑`, `↓`, `Page Up`, `Page Down`) para percorrer a lista se ela ultrapassar a altura disponível.

Cada gráfico tem até 60 amostras, uma por segundo. CPU, RAM, GPU e disco usam uma escala de 0 a 100%. O disco mostra o mais ocupado e a GPU mostra o motor mais ocupado. A rede soma tráfego de entrada e saída das interfaces físicas ativas (ou de todas, caso não haja interface física), em `k`, `M` ou `G` bits por segundo. `--` indica uma leitura indisponível.

## Compilação e Testes

Compile a partir desta pasta com o Zig 0.15.2 no PATH. Por padrão, o build usa `ReleaseSafe` (com checagens de segurança em runtime ativas), embute o manifesto Windows (`app.manifest`) e configura `DependentLoadFlags = 0x0800` (`LOAD_LIBRARY_SEARCH_SYSTEM32`) no cabeçalho PE:

```powershell
zig build
```

Também é possível escolher explicitamente o modo de otimização (`ReleaseSafe` é o recomendado; `ReleaseSmall` gera binário menor, porém desabilita checagens de runtime):

```powershell
zig build -Doptimize=ReleaseSafe
```

Para rodar os testes unitários e o smoke test de inicialização/encerramento:

```powershell
zig build test
zig build smoke
```

O `smoke` precisa que nenhuma instância do TaskbarPerfZig esteja aberta. Se houver uma, ele avisa e falha sem iniciar outra.

A interface usa APIs nativas do Windows. A versão atual atende à barra horizontal do Explorer no monitor principal. Os espaços livres são identificados por UI Automation, cuja árvore de controles pode variar em versões do Windows ou com mods da barra.
