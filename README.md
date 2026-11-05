# lg-a1-usb-ethernet-driver

Driver **r8152** para usar um adaptador **USB-Ethernet Realtek (RTL8152/RTL8153)** em TVs **LG webOS 6**
da plataforma **lm21u** (ex.: **OLED A1**, 2021), com um app para o **Homebrew Channel** que ativa o driver
com o controle remoto.

A porta de rede das TVs LG é de 100 Mbit/s. Com um adaptador gigabit na porta USB (2.0) a TV passa desse
limite — medimos 111 Mbit/s, com o teste limitado pela internet e pelo PC — útil para Plex, Jellyfin,
Moonlight e afins.

*English summary [below](#english).*

## Testado em

| TV | Firmware / webOS | Adaptador | Resultado |
|---|---|---|---|
| OLED55A1PSA (2021) | 03.53.45 / webOS 6.5.3 | Realtek RTL8153 (`0bda:8153`) | ✅ funciona |

- O driver carrega sem erros; a TV configura a rede do adaptador **sozinha** (IP, rota e DNS pelo
  gerenciador de rede da própria TV) e fica online. Link de 1000 Mbit/s.
- Download pela internet de até **111 Mbit/s** num único arquivo — acima do máximo da porta interna da TV
  (~94 Mbit/s na prática). O teto real não foi medido porque a internet e o PC usados no teste ficam
  perto de 100 Mbit/s.
- **Ativar ao ligar a TV** testado com reinício: o driver carrega sozinho em ~40 s após ligar.

Testou em outra TV? Abra uma [issue](https://github.com/artor410/lg-a1-usb-ethernet-driver/issues) com
modelo, firmware e resultado.

> [!WARNING]
> Isto carrega um módulo no kernel da TV. Foi compilado com o código-fonte GPL que a LG publica para esta TV
> e testado no modelo acima, mas outros firmwares podem ter diferenças. Se algo der errado, a TV pode
> travar e reiniciar; ela volta ao normal, e a ativação automática se desliga sozinha se a TV não terminar
> de ligar. Use por sua conta e risco.

## Compatibilidade

| Item | Exigido |
|---|---|
| TV | LG com plataforma `lm21u` (ex.: OLED A1 2021) |
| Sistema | webOS 6.x (testado na compilação contra 6.5.3) |
| Kernel | `4.4.84-*`, ARMv7 (`armv7l`) |
| Acesso | **root** com o [Homebrew Channel](https://github.com/webosbrew/webos-homebrew-channel) |

O app confere tudo isso sozinho e se recusa a carregar o driver em outra TV. Para conferir pelo SSH:

```sh
nyx-cmd DeviceInfo query device_name   # deve mostrar: lm21u
uname -r                               # deve começar com: 4.4.84-
```

### Adaptadores reconhecidos

Chip Realtek RTL8152 (100 Mbit/s) ou RTL8153 (1 Gbit/s). IDs USB aceitos pelo driver:

| VID:PID | Adaptador |
|---|---|
| `0bda:8152`, `0bda:8153`, `0bda:8050` | Realtek (genéricos, a maioria dos adaptadores USB 3.0/USB-C) |
| `045e:07ab`, `045e:07c6` | Microsoft |
| `04e8:a101` | Samsung |
| `17ef:304f`, `17ef:3062`, `17ef:3069`, `17ef:7205`, `17ef:720c`, `17ef:7214` | Lenovo |
| `13b1:0041` | Linksys USB3GIGV1 |
| `0955:09ff` | NVIDIA |
| `2357:0601` | TP-Link UE300 |

Adaptadores **RTL8156 (2.5G)** e **ASIX** não são reconhecidos por este driver.

## Instalação

### Pelo Homebrew Channel (recomendado)

Adicione este repositório no Homebrew Channel da TV. Assim o app aparece na lista e as atualizações
chegam por lá.

1. Na TV, abra o **Homebrew Channel** → **Settings** (engrenagem) → **Repositories** → **Add repository**.
2. Digite esta URL e confirme em **Add repository**:

   ```
   https://raw.githubusercontent.com/artor410/lg-a1-usb-ethernet-driver/main/repo/apps.json
   ```

3. Volte para a lista de apps: **USB Ethernet (RTL8153)** aparece marcado com *(from …)*. Abra e use
   **Install**.

Digitar a URL com o controle remoto é chato; com acesso SSH dá para abrir o Homebrew Channel já com a URL
preenchida (só falta confirmar na TV):

```sh
luna-send -n 1 luna://com.webos.applicationManager/launch   '{"id":"org.webosbrew.hbchannel","params":{"launchMode":"addRepository","url":"https://raw.githubusercontent.com/artor410/lg-a1-usb-ethernet-driver/main/repo/apps.json"}}'
```

### Instalação manual do `.ipk`

Baixe `io.github.artor410.lgusbethernet_<versão>_all.ipk` em
[Releases](https://github.com/artor410/lg-a1-usb-ethernet-driver/releases) e instale por **um** destes jeitos:

- **webOS Dev Manager:** abra o [webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop),
  conecte na TV, vá em **Apps → Install** e escolha o `.ipk`.
- **Pelo SSH** (TV com root):

  ```sh
  scp io.github.artor410.lgusbethernet_<versão>_all.ipk root@IP_DA_TV:/tmp/app.ipk
  ssh root@IP_DA_TV
  luna-send -n 6 luna://com.webos.appInstallService/dev/install     '{"id":"io.github.artor410.lgusbethernet","ipkUrl":"/tmp/app.ipk","subscribe":true}'
  ```

## Como usar

1. Conecte o adaptador numa porta USB da TV e o cabo de rede nele.
2. Abra o app **USB Ethernet (RTL8153)** na lista de apps.
3. Confira a coluna *Situação*: compatibilidade, adaptador detectado e driver.
4. Use **Ativar driver agora**. Se der tudo certo, o adaptador aparece com uma interface de rede (ex.: `eth1`).
5. Só depois de confirmar que funciona, use **Ativar ao ligar a TV** para carregar o driver a cada inicialização.

Dica: se o cabo também estiver ligado na porta de rede da própria TV, ela pode continuar usando a porta
interna. Desconecte o cabo da porta interna para usar o adaptador.

### Segurança

- O app só carrega o driver na plataforma e no kernel para os quais ele foi compilado.
- **Proteção contra reinício em loop:** se a TV não terminar de ligar depois de carregar o driver
  automaticamente, a ativação automática é desligada sozinha na inicialização seguinte. O Homebrew Channel
  também tem um modo de segurança próprio que pula os scripts de inicialização depois de uma falha.
- Para desinstalar: no app, use **Não ativar ao ligar a TV** e **Desativar driver**; depois remova o app.
  (Se você remover o app direto, o script de inicialização se apaga sozinho no próximo boot.)

### Linha de comando

O app usa um script que também funciona pelo SSH:

```sh
S=/media/developer/apps/usr/palm/applications/io.github.artor410.lgusbethernet/bin/usbeth.sh
sh $S status          # compatibilidade, adaptador, driver, interface
sh $S load            # carrega o driver agora
sh $S unload          # descarrega
sh $S autostart-on    # carrega ao ligar a TV
sh $S autostart-off
sh $S log             # registro (/var/lib/lg-a1-usb-ethernet/log.txt)
```

## Compilar você mesmo

O módulo pronto está em [`prebuilt/`](prebuilt/) (SHA-256 em `prebuilt/*.sha256`). Para reproduzir:

1. Baixe o pacote GPL **"webOS 6.0 LMUA 1.0"** em [opensource.lge.com](https://opensource.lge.com)
   (procure por um modelo `OLED55A1…`); só a parte 2 é usada.
2. Num Linux (ou WSL) com `gcc-9-arm-linux-gnueabihf`, `make`, `flex`, `bison`, `bc` e `libssl-dev`:

   ```sh
   bash scripts/extrair-fonte.sh /pasta/dos/downloads
   bash scripts/compilar-r8152.sh      # gera build/r8152.ko com a config da TV (diagnostico/config.gz)
   bash scripts/empacotar-ipk.sh       # gera dist/*.ipk, dist/*.manifest.json e repo/apps.json
   ```

Detalhes da investigação (diagnóstico da TV, diferenças de configuração, riscos) em
[`docs/DESENVOLVIMENTO.md`](docs/DESENVOLVIMENTO.md). O script `scripts/coletar-info-tv.sh` gera um relatório
da sua TV — útil para abrir uma issue se quiser suporte para outro modelo.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `app/` | App do Homebrew Channel (HTML/JS) e o script `bin/usbeth.sh` |
| `driver/` | `r8152.c` exatamente como no pacote GPL da LG |
| `prebuilt/` | `r8152.ko` compilado para `4.4.84` / `lm21u` |
| `repo/` | Repositório próprio para o Homebrew Channel (`apps.json`, gerado por `scripts/gerar-indice.sh`) |
| `scripts/` | Diagnóstico, compilação e empacotamento |
| `diagnostico/` | Configuração do kernel da TV usada na compilação |

## Uso de IA

O driver foi compilado, e o app e os scripts foram escritos, por um agente de IA (Claude Code) sob a
direção do mantenedor, que acompanhou e conduziu os testes na própria TV (OLED55A1PSA) e é responsável
pelo projeto. O código do driver em si é o `r8152` original da Realtek/LG, sem alterações.

## Licença e créditos

- GPL-2.0 (veja [`LICENSE`](LICENSE)). O driver `r8152` é © Realtek Semiconductor, distribuído pela LG no
  pacote de código aberto da TV; o código está em [`driver/r8152.c`](driver/r8152.c).
- [webOS Homebrew Project](https://github.com/webosbrew) pelo Homebrew Channel.
- [throwaway96/webos-kernel-drivers](https://github.com/throwaway96/webos-kernel-drivers) e
  [DonZoomik/webos-r8152](https://github.com/DonZoomik/webos-r8152) pelas referências de como compilar
  módulos para TVs webOS.

---

## English

**r8152 driver for Realtek RTL8152/RTL8153 USB Ethernet adapters on LG webOS 6 TVs with the `lm21u`
platform (e.g. OLED A1, 2021), plus a Homebrew Channel app to load it with the remote.**

**Tested on OLED55A1PSA (firmware 03.53.45, webOS 6.5.3) with an RTL8153 adapter:** the driver loads
cleanly, the TV's own network manager configures the adapter automatically (DHCP, route, DNS), 1 Gbit/s link,
up to 111 Mbit/s measured (test setup capped near 100), and loading at startup works after a reboot.
Use at your own risk; other firmwares may differ.

- **Requirements:** rooted TV with Homebrew Channel, platform `lm21u`, kernel `4.4.84-*` (`armv7l`).
  The app checks this and refuses to load elsewhere.
- **Install:** in Homebrew Channel go to **Settings → Repositories → Add repository** and enter
  `https://raw.githubusercontent.com/artor410/lg-a1-usb-ethernet-driver/main/repo/apps.json` — the app then shows up in the list. Or download the `.ipk` from
  [Releases](https://github.com/artor410/lg-a1-usb-ethernet-driver/releases) and install it with webOS Dev Manager.
- **Use:** open **USB Ethernet (RTL8153)**, press **Load driver now**, check the status, and only then enable
  **Load at TV startup**. A boot-loop guard turns startup loading off if the TV fails to finish booting.
- **Build it yourself:** see the scripts in `scripts/` and `docs/DESENVOLVIMENTO.md` (Portuguese).
- **License:** GPL-2.0.
