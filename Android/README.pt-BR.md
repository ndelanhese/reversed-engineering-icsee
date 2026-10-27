# Android

[English](README.md) · [Projeto](../README.pt-BR.md)

Versão Android nativa: protocolos em Rust, interface Kotlin e vídeo LibVLC. Conecta diretamente às câmeras pela rede local ou VPN existente; não precisa de Mac ligado, conta de nuvem ou SDK do iCSee.

## Instalar

Baixe o APK assinado **0.1.0-alpha.5** na release de prévia Android do GitHub. Android 9 ou posterior, arm64/x86_64. Autorize instalação pelo navegador/gerenciador quando solicitado. Instala junto com o iCSee original.

Toque **Encontrar câmeras** no mesmo Wi-Fi ou rede Ethernet. Selecione um resultado, escolha o nome e salve; endereço e porta ONVIF são preenchidos. Portas RTSP/controle usam os padrões iCSee. **Ajustes avançados** permite alterar portas/canal; cadastro manual continua disponível. Conecte com suas credenciais locais. A opção de lembrar senha usa criptografia AES-GCM com Android Keystore; backups e preenchimento automático desses campos ficam excluídos. Android 17 pede permissão de rede local.

Se o Android bloquear especificamente por **verificação de identidade do desenvolvedor**, esta prévia ainda não foi registrada no cadastro do Google. O [fluxo avançado oficial ou instalação de desenvolvimento via ADB](https://developer.android.com/developer-verification/guides) permite instalar apps não registrados. Com seu aparelho autorizado/selecionado: `adb -s SERIAL_DO_APARELHO install -r reversed-engineering-icsee-android-0.1.0-alpha.5.apk`. Assinatura do APK e cadastro de identidade são verificações distintas.

O menu **⋯** abre controles ou gravações. PTZ, posições e opções de imagem dependem do que a câmera anuncia. A descoberta de ajustes é somente leitura; alterações são explícitas, verificam conflitos e conferem os valores retornados. Formatação, exclusão de gravações e alterações de contas não fazem parte do app.

Histórico usa horários da câmera. Escolha dia, linha do tempo ou horário; reprodução oferece busca, velocidade e exportação de original, MP4 ou intervalo. Primeiro baixa o trecho completo e valida o vídeo, portanto pode demorar. Reprodução usa cache privado e temporário, removido ao trocar trecho, sair, cancelar ou falhar. Somente exportação explícita pelo seletor de arquivos deixa cópia permanente. O seletor mantém temporariamente o trecho preparado enquanto você escolhe o destino. Falha do sistema/provedor durante exportação pode deixar incompleto um destino escolhido explicitamente.

O áudio ao vivo fica silenciado, mantendo o canal RTSP ativo para câmeras que interrompem o vídeo quando ele é encerrado. A interface acompanha o tema claro ou escuro do Android. Vídeos fora da tela e app em segundo plano liberam players. Sem serviço permanente de câmera. Interface segue idioma Android: inglês/português brasileiro; nomes técnicos vêm do firmware. PiP, nuvem/P2P, atualização automática e transmissão em segundo plano ficam fora desta primeira versão.

## Compilar e testar

Instruções completas e versões fixadas: [guia em inglês](README.md#build). Com JDK, SDK/NDK e Rustup preparados:

```sh
python3 Android/build.py --sign
```

APK e checksum ficam em `dist/android/`. A chave privada de assinatura é criada/reutilizada fora do Git, em `~/.local/share/reversed-engineering-icsee/android-signing/`; mantenha backup privado para preservar atualizações. Sem `--sign`, sai APK não assinado para CI, que não instala diretamente.

Testes locais usam emulador Android 15, protocolos simulados e padrões de vídeo sintéticos. **Ainda precisa validar no celular físico com suas câmeras**, principalmente codec por hardware e permissão Android 17. A versão macOS e seus dados foram preservados. Fontes originais MIT; LibVLC LGPL e demais avisos acompanham app/release.
