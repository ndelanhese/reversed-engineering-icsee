# Reversed engineering Icsee

<img src="Assets/AppIcon.png" width="96" alt="Ícone original com lente e seta de retorno">

**Cliente nativo macOS para câmeras iCSee / Xiongmai pela sua rede.**

[English](README.md) · [Engenharia reversa e evidências](docs/REVERSE_ENGINEERING.md) · [Contribuir](CONTRIBUTING.md)

Projeto independente, criado para assistir às próprias câmeras no Mac com janelas nativas. A investigação do app Android exportado pelo proprietário ajudou identificar a família do SDK; testes autenticados nas câmeras confirmaram o comportamento RTSP necessário para esta implementação em Swift.

Sem vínculo com iCSee ou Xiongmai. Compatibilidade depende do firmware e do RTSP local de cada câmera. O APK e o SDK Android não fazem parte do app.

## Recursos

- Grade com múltiplas câmeras, nomes editáveis, porta, canal e fluxo principal/leve.
- Renomear sem interromper vídeo.
- Modo cinema, popup flutuante redimensionável e tela cheia nativa.
- Mesma conexão compartilhada entre as visualizações de uma câmera.
- Credenciais locais, salvamento opcional no Chaves e tentativa de compatibilidade Sofia após erro de autenticação.
- Diagnóstico de conexão e detecção de vídeo congelado.

Interface segue idioma preferido no macOS: **inglês ou português brasileiro**, respeitando ordem de preferências e idioma específico por app. Inglês é fallback quando nenhum idioma preferido compatível é encontrado. Após mudar em **Ajustes do Sistema → Geral → Idioma e Região → Aplicativos**, encerre e reabra app. Nomes das câmeras permanecem como você definiu.

Áudio, PTZ, gravação, reprodução do cartão SD, login na nuvem e P2P não foram implementados. Acesso remoto depende de VPN já configurada; o app não instala nem configura VPN.

## Baixar e instalar

**[Baixar release para macOS](https://github.com/ndelanhese/reversed-engineering-icsee/releases/latest)** — Apple Silicon, macOS 14 ou posterior.

1. Baixe arquivo **macos-arm64.dmg**, abra e arraste **Reversed engineering Icsee** para **Applications**. ZIP também disponível.
2. Abra pela pasta Applications. Release já inclui FFmpeg; não precisa instalar Homebrew, Python ou compilador.
3. Assinatura **ad hoc**, sem Developer ID e sem notarização. Se macOS bloquear primeira abertura e você confiar no download, siga [orientações da Apple](https://support.apple.com/en-us/102445): **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim**, após tentativa bloqueada. Nenhum script desativa Gatekeeper.

Release inclui `SHA256SUMS.txt`, configuração de build e fonte correspondente do FFmpeg. App usa [FFmpeg](https://ffmpeg.org/) sob LGPL-2.1-or-later como executável separado; [fonte disponível junto ao app](https://github.com/ndelanhese/reversed-engineering-icsee/releases/latest/download/ffmpeg-9.0.2.tar.xz). Código e ícone originais sob MIT.

Builds Intel e todas as versões de macOS suportadas ainda não foram validados. Sem atualizador automático.

## Compilar do código-fonte

Requisitos: **Mac Apple Silicon, macOS 14+, toolchain Swift 6, Python 3.12+ e FFmpeg**. Para build de desenvolvimento, com Homebrew disponível:

```sh
xcode-select --install
brew install ffmpeg
git clone https://github.com/ndelanhese/reversed-engineering-icsee.git
cd reversed-engineering-icsee
python3 build.py
open "dist/Reversed engineering Icsee.app"
```

Build direto com `swiftc`, sem projeto Xcode ou dependências Swift externas. Build de desenvolvimento usa FFmpeg externo de `/opt/homebrew/bin/ffmpeg` ou `/usr/local/bin/ffmpeg`. Releases incluem decoder LGPL independente, com preferência sobre instalações externas. Java foi usado na ferramenta de análise Android, não no app final.

Para gerar app independente e pacotes iguais aos distribuídos:

```sh
python3 Tools/build_ffmpeg.py
python3 build.py --bundle-ffmpeg
python3 Tools/package_release.py
```

Pacotes ficam em `dist/release/`. Veja [manutenção de releases](docs/RELEASING.md) para tags, validação e automação.

## Conectar

1. Clique **Adicionar câmera**. Instalações novas começam vazias.
2. Informe IP/hostname local, porta RTSP (geralmente `554`) e canal (geralmente `1`). Consulte os dispositivos conectados no roteador ou as configurações de rede da câmera.
3. Clique **Conectar** e informe usuário/senha **locais da câmera**. Podem ser diferentes da conta iCSee.
4. Marque **Salvar no Chaves** se quiser lembrar as credenciais.
5. Tente **Fluxo leve** se o principal estiver pesado ou incompatível.

Não exponha portas das câmeras na internet. RTSP local não é transporte criptografado; use rede confiável ou VPN.

| Ação | Controle |
| --- | --- |
| Cinema | Duplo clique no vídeo ou botão ampliar |
| Sair do cinema | `Esc` ou **Voltar** |
| Popup flutuante | Menu **⋯ → Popup flutuante** |
| Tela cheia da câmera | Menu **⋯ → Tela cheia** |
| Sair da tela cheia | `Esc` |
| Alternar tela cheia da janela em foco | `Control + Command + F` |
| Renomear / configurar conexão | Menu **⋯** |
| Fechar popup | Botão nativo ou `Command + W` |

Fechar popup mantém transmissão compartilhada. Fechar a última janela encerra app e transmissões.

## Privacidade e limites

Nomes, endereços e ajustes ficam nas preferências locais do macOS. Credenciais persistem no Chaves somente quando solicitado. URL autenticada chega ao FFmpeg por pipe em memória; não por argumento do processo nem arquivo de playlist. Diagnósticos brutos são classificados em memória. Sem telemetria ou integração com conta na nuvem.

Credenciais e vídeo decodificado existem na memória enquanto usados. Transformação Sofia serve para compatibilidade legada, não para criptografia ou armazenamento moderno de senhas. Vídeo é decodificado com largura de saída de 1280 pixels e até 15 quadros por segundo. Veja [política de segurança](SECURITY.md).

## Testes e contribuição

```sh
python3 test.py --core-only
python3 test.py
python3 test.py --interactive
```

Primeiro comando verifica núcleo e seleção nativa de idioma, sem câmera nem sessão gráfica. Segundo adiciona testes de janelas; terceiro verifica interface renderizada em inglês/português, tela cheia e Esc. Ambos precisam de sessão gráfica. CI também compila FFmpeg e valida DMG/ZIP com vídeos H.264/HEVC sintéticos, sem Homebrew no caminho. Primeiro build de empacotamento baixa fonte oficial do FFmpeg; não acessa câmeras reais.

Leia [arquitetura](docs/ARCHITECTURE.md), [investigação](docs/REVERSE_ENGINEERING.md) e [regras de contribuição](CONTRIBUTING.md). Issues e PRs aceitam português ou inglês. Não envie senhas, vídeos privados, APKs ou dados da sua rede.

## Origem e licença

Desenvolvido com assistência do Codex, usando [REA](https://rea.tools/) e a skill [`reverse-engineer-anything`](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md) para investigação, além de skills de Swift/macOS, depuração, testes, revisão e verificação. O documento de [engenharia reversa](docs/REVERSE_ENGINEERING.md) explica usos e limitações.

Código, ícone e documentação originais sob [MIT](LICENSE). Releases incluem FFmpeg sob LGPL-2.1-or-later, avisos dentro do app e fonte correspondente como download separado. Sem redistribuição de APK, código descompilado, bibliotecas proprietárias ou imagens das câmeras. Veja [avisos de terceiros](THIRD_PARTY_NOTICES.md).
