# CamMac

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

Interface em português brasileiro. Áudio, PTZ, gravação, reprodução do cartão SD, login na nuvem e P2P não foram implementados. Acesso remoto depende de VPN já configurada; o app não instala nem configura VPN.

## Compilar e abrir

Requisitos: **Mac Apple Silicon, macOS 14+, toolchain Swift 6, Python 3 e FFmpeg**. Com Homebrew disponível:

```sh
xcode-select --install
brew install ffmpeg
git clone https://github.com/ndelanhese/cammac.git
cd cammac
python3 build.py
open dist/CamMac.app
```

Build direto com `swiftc`, sem projeto Xcode ou dependências Swift externas. FFmpeg é executável separado, procurado em `/opt/homebrew/bin/ffmpeg` ou `/usr/local/bin/ffmpeg`. Não está incluído neste repositório. Java foi usado na ferramenta de análise Android, não no app final.

Assinatura local **ad hoc**, sem Developer ID, notarização, instalador pronto ou atualizações automáticas. Builds Intel e todas as versões de macOS suportadas ainda não foram validados.

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

Primeiro comando não precisa de câmera nem sessão gráfica. Segundo adiciona testes de janelas; terceiro testa tela cheia e Esc. Ambos precisam de sessão gráfica. CI compila o app e executa testes do núcleo, sem acessar câmeras reais.

Leia [arquitetura](docs/ARCHITECTURE.md), [investigação](docs/REVERSE_ENGINEERING.md) e [regras de contribuição](CONTRIBUTING.md). Issues e PRs aceitam português ou inglês. Não envie senhas, vídeos privados, APKs ou dados da sua rede.

## Origem e licença

Desenvolvido com assistência do Codex, usando [REA](https://rea.tools/) e a skill [`reverse-engineer-anything`](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md) para investigação, além de skills de Swift/macOS, depuração, testes, revisão e verificação. O documento de [engenharia reversa](docs/REVERSE_ENGINEERING.md) explica usos e limitações.

Código e documentação originais sob [MIT](LICENSE). Sem redistribuição de APK, código descompilado, bibliotecas proprietárias ou imagens das câmeras. Ferramentas externas mantêm suas próprias licenças: [avisos de terceiros](THIRD_PARTY_NOTICES.md).
