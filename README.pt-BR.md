# Reversed engineering Icsee

**Prévia Android:** versão nativa Rust/Kotlin em APK alpha. Veja [instalação, recursos e limites de validação](Android/README.pt-BR.md).

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
- Ícone na barra de menus com prévia ao passar o mouse e câmera padrão salva.
- Credenciais locais, salvamento opcional no Chaves e tentativa de compatibilidade Sofia após erro de autenticação.
- Diagnóstico de conexão e detecção de vídeo congelado.
- Movimento PTZ curto, parada, posições salvas e imagem conforme os perfis e opções da câmera.
- Ajustes locais descobertos, com edição estruturada, detecção de conflitos e verificação por leitura.
- Calendário e histórico do cartão SD, reprodução nativa, busca por horário, velocidade e exportação do original, vídeo ou intervalo.

Interface segue idioma preferido no macOS: **inglês ou português brasileiro**, respeitando ordem de preferências e idioma específico por app. Inglês é fallback quando nenhum idioma preferido compatível é encontrado. Após mudar em **Ajustes do Sistema → Geral → Idioma e Região → Aplicativos**, encerre e reabra app. Nomes das câmeras permanecem como você definiu.

Áudio ao vivo/bidirecional, gravação do vídeo ao vivo no Mac, login na nuvem e P2P não foram implementados. Gravações do cartão são reproduzidas separadamente, com áudio G.711 convertido para AAC quando compatível. Ajustes de gravação/áudio na própria câmera podem estar disponíveis nos controles do dispositivo. Acesso remoto depende de VPN já configurada; o app não instala nem configura VPN.

## Gravações do cartão SD

Abra **⋯ → Gravações…** na câmera. A janela também está disponível nas visualizações ampliadas. Autentique com as credenciais locais ou reutilize o login em memória quando o vídeo já estiver conectado.

Escolha mês, dia, canal e fluxo. Os pontos no calendário indicam dias informados pela câmera; quando a consulta mensal não for compatível, selecione qualquer dia para consultá-lo diretamente. A linha do tempo usa o **horário local da câmera**, preservado sem conversão silenciosa para o fuso do Mac. Clique em um intervalo gravado ou escolha um horário para reproduzir.

O trecho escolhido é baixado para um cache privado antes da reprodução. Há pausa, busca, avanço/retorno de 15 segundos, seleção de velocidade e troca de gravação. Os arquivos do cartão permanecem intactos. **Exportar original…** preserva o formato da câmera; **Exportar vídeo…** gera um `.mov` nativo; **Exportar intervalo…** mostra os limites efetivos alinhados a quadros-chave. Não são cortes garantidos entre quaisquer dois quadros.

Os horários entre quadros-chave e o alinhamento do áudio são estimados a partir dos dados disponíveis no protocolo, incluindo taxas fracionárias arredondadas pela câmera. Lacunas permanecem identificadas. Áudio incompatível é informado. Downloads incompletos não viram vídeos concluídos. O temporário é apagado após falha, cancelamento, troca de gravação, fechamento da janela ou saída do app. Temporários de processos encerrados são limpos na próxima abertura. Somente um **Save** explícito mantém uma exportação; após falha, **Exportar original…** baixa novamente para esse salvamento, sem guardar o download anterior.

Consultas e downloads têm limites de tamanho, tempo e paginação. A busca inclui as 24 horas anteriores ao dia escolhido para encontrar gravações atravessando a meia-noite; arquivos iniciados antes desse intervalo podem ficar fora da lista. Não há exclusão, formatação ou alteração automática no cartão. Veja [detalhes técnicos e escopo de validação](docs/RECORDINGS.md).

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

### Credenciais salvas e Chaves

Senhas salvas permanecem no Chaves do macOS; não são gravadas em preferências, logs ou arquivos do repositório.
O aviso do sistema pede a **senha de início de sessão/Chaves do Mac**, não a senha da câmera.
Falhas ou cancelamentos de acesso são informados separadamente e não apagam credenciais existentes.

Builds públicos usam assinatura ad hoc. Cada build novo muda a identidade da assinatura, então a opção
**Permitir Sempre** pode precisar ser autorizada novamente após uma atualização. Reabrir o mesmo build
já autorizado deve preservar o acesso. Mantenha o Chaves de início de sessão desbloqueado conforme sua política normal do macOS.

Para manter a mesma identidade entre builds locais e atualizações baixadas, execute uma vez a partir de um checkout confiável:

```sh
python3 Tools/local_sign.py --create "/caminho/para/Reversed engineering Icsee.app"
```

Isso cria uma identidade de assinatura autoassinada no Mac. A chave privada é importada como não exportável
no Chaves padrão, por pipes em memória, com acesso de assinatura para `/usr/bin/codesign`.
Nenhuma configuração de confiança de certificados raiz é alterada. Isso **não** é assinatura Developer ID
nem notarização. A identidade pertence ao Chaves local e não é enviada ao GitHub.
Itens existentes podem precisar de uma última autorização **Permitir Sempre** após essa mudança.

`build.py` reutiliza essa identidade automaticamente quando disponível. Após substituir o app por um download
público novo, execute `python3 Tools/local_sign.py "/caminho/para/Reversed engineering Icsee.app"`
**antes de abri-lo**. O empacotamento público continua usando assinatura ad hoc e não distribui sua identidade local.
Não apague nem recrie a identidade a cada build. Identidade expirada ou perdida exige nova autorização.
Use `--sign-identity FINGERPRINT` para selecionar outro certificado ou `--sign-identity -` para gerar um build ad hoc.

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

Fechar a janela principal mantém o app na barra de menus. O vídeo pausa quando a câmera não tem visualização visível, incluindo janelas fechadas, minimizadas ou totalmente cobertas. Abrir a janela ou a prévia retoma câmeras conectadas nesta sessão sem pedir senha novamente. **Parar** impede retomada automática. Use `Command + Q` para encerrar.

## Prévia na barra de menus

Passe o mouse sobre o ícone de lente na barra de menus do macOS para ver a câmera selecionada. O painel contém somente o seletor de câmera e o vídeo; sair do ícone e do painel fecha a prévia. Clique no ícone para manter o painel aberto e clique novamente ou fora dele para fechar.

Escolha **Câmera da prévia** no painel ou **⋯ → Usar na prévia da barra de menus** no cartão da câmera. A escolha permanece entre aberturas do app. Renomear preserva a seleção; excluir a câmera selecionada escolhe outra câmera salva.

A prévia compartilha uma sessão por câmera com a grade e os popups. Sozinha, usa imagens de 480 pixels de largura a 5 FPS; cartões da grade usam 800 pixels / 5 FPS; cinema, popups e tela cheia mantêm o limite anterior de 1280 pixels / 15 FPS. Câmeras ocultas encerram o decodificador e liberam o frame atual. Passar o mouse retoma uma câmera já conectada com credenciais mantidas em memória; não acessa o Keychain nem autentica câmera desconectada. Clique no ícone do app no Dock para reabrir a janela principal. Controles, gravações e visualizações ampliadas ficam no app principal. Veja [comportamento e medições de recursos](docs/PERFORMANCE.md).

## Controles da câmera

Abra **⋯ → Controles da câmera…** no cartão ou pelo botão de controles no cinema ou popup. As credenciais da transmissão ativa são reutilizadas em memória. Caso contrário, use **Autenticar…** com as credenciais locais; o Chaves continua sendo usado somente pelo fluxo de autenticação explícito.

- **Movimento:** escolha o perfil informado pela câmera, use as setas para movimentos curtos e ajuste a velocidade. **Parar movimento** cancela e envia a parada. Zoom e posições salvas dependem do suporte do dispositivo. Movimento contínuo usa limite no dispositivo de até um segundo; posições salvas usam monitoramento com limite de 15 segundos e parada, pois o padrão ONVIF não fornece Timeout para essa operação.
- **Imagem:** brilho, contraste, saturação, nitidez, exposição e visão noturna aparecem conforme opções e limites retornados. **Aplicar ajustes de imagem** grava e verifica por nova leitura. Trocar perfil ou recarregar pede confirmação antes de descartar edições.
- **Ajustes do dispositivo:** após autenticar, o app consulta um catálogo limitado de seções conhecidas. Por padrão, mostra somente as que a câmera retornou. **Mostrar ajustes não verificados** permite ver candidatos e falhas de leitura, sem afirmar compatibilidade.

O editor preserva campos, tipos e posições nas listas, mascara valores semelhantes a senhas e pede confirmação para aplicar. Antes de gravar, consulta os valores atuais e impede sobrescrever conflitos. Campos desconhecidos de outras funções são preservados. Ajustes avançados usam nomes do firmware e podem ser rejeitados por suporte ou permissão. Leituras bem-sucedidas não comprovam todos os limites de escrita.

Portas padrão: **ONVIF 8899** e **controle local 34567**, editáveis em **Configurar…**. Mudanças de rede, privacidade e energia podem desconectar a câmera. **Reiniciar câmera…** é uma ação separada e confirmada; mantenha o app aberto durante a espera de 15 segundos e reconecte após a câmera terminar de reiniciar. Sair normalmente aguarda a limpeza das operações pendentes.

Nuvem, integrações de celular, formatação, restauração de fábrica, atualização de firmware e administração de contas/senhas não são acionadas por este editor local. Não existe descoberta universal de todos os parâmetros de todos os firmwares.

Validação real nas duas câmeras: consultas ONVIF, solicitações curtas de movimento/parada e alteração de brilho com leitura e restauração do original. Os testes com servidores locais sintéticos cobrem DVRIP, alterações, conflitos e encerramento/reinicialização; ajustes reais de rede, armazenamento, senha e reinício não foram usados na validação. Veja o [guia técnico em inglês](docs/CAMERA_CONTROLS.md).

## Privacidade e limites

Nomes, endereços e ajustes ficam nas preferências locais do macOS. Credenciais persistem no Chaves somente quando solicitado. URL autenticada chega ao FFmpeg por pipe em memória; não por argumento do processo nem arquivo de playlist. Diagnósticos brutos são classificados em memória. Sem telemetria ou integração com conta na nuvem.

Credenciais e vídeo decodificado existem na memória enquanto usados. Transformação Sofia serve para compatibilidade legada, não para criptografia ou armazenamento moderno de senhas. A saída depende da visualização: prévia em 480 pixels / 5 FPS, grade em 800 pixels / 5 FPS e cinema/popups/tela cheia em até 1280 pixels / 15 FPS. Sem visualização visível, decodificação pausa. Veja [política de segurança](SECURITY.md).

## Testes e contribuição

```sh
python3 test.py --core-only
python3 test.py
python3 Tools/build_ffmpeg.py
python3 test.py --interactive
```

Primeiro comando verifica núcleo e seleção nativa de idioma, sem câmera nem sessão gráfica. Segundo adiciona testes de janelas; terceiro verifica interface renderizada em inglês/português, prévia da barra de menus, reabertura da janela, tela cheia e Esc. Ambos precisam de sessão gráfica. CI também compila FFmpeg e valida DMG/ZIP com vídeos H.264/HEVC sintéticos, sem Homebrew no caminho. Primeiro build de empacotamento baixa fonte oficial do FFmpeg; não acessa câmeras reais.

Leia [arquitetura](docs/ARCHITECTURE.md), [investigação](docs/REVERSE_ENGINEERING.md) e [regras de contribuição](CONTRIBUTING.md). Issues e PRs aceitam português ou inglês. Não envie senhas, vídeos privados, APKs ou dados da sua rede.

## Origem e licença

Desenvolvido com assistência do Codex, usando [REA](https://rea.tools/) e a skill [`reverse-engineer-anything`](https://github.com/morluto/rea/blob/main/.agents/skills/reverse-engineer-anything/SKILL.md) para investigação, além de skills de Swift/macOS, depuração, testes, revisão e verificação. O documento de [engenharia reversa](docs/REVERSE_ENGINEERING.md) explica usos e limitações.

Código, ícone e documentação originais sob [MIT](LICENSE). Releases incluem FFmpeg sob LGPL-2.1-or-later, avisos dentro do app e fonte correspondente como download separado. Sem redistribuição de APK, código descompilado, bibliotecas proprietárias ou imagens das câmeras. Veja [avisos de terceiros](THIRD_PARTY_NOTICES.md).
