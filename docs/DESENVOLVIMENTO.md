# Notas de desenvolvimento

Como o driver foi investigado e compilado para a TV **LG OLED A1 (webOS 6)**.

## Situação atual (diagnóstico de 05/11/2026)
- TV: webOS 6.5.3, kernel `4.4.84-899.19.koli.1`, ARMv7 (32 bits), compilado com GCC 8.2.0, plataforma `lm21u`.
- Acesso: `ssh -i ~/.ssh/lg_tv_ed25519 root@IP_DA_TV` (chave autorizada com `scripts/autorizar-chave.ps1`).
- Adaptador: **Realtek RTL8153** (`0bda:8153`), detectado na porta USB 2.0, **sem driver**.
- Kernel: aceita módulos (`CONFIG_MODULES=y`), **sem exigência de assinatura** e sem `MODVERSIONS`.
  `CONFIG_MII=y` já está embutido; falta só o driver `r8152` (`CONFIG_USB_RTL8152` desligado).
- A TV já carrega módulos com vermagic diferentes (`4.4.84 ...` e `4.4.84-899.kcl4tv.17 ...`),
  então a checagem de versão é tolerante. Alvo: `4.4.84 SMP preempt mod_unload ARMv7`.
- **Caminho escolhido:** compilar só o `r8152.ko` (ele não depende de `usbnet`).
- Observação: a porta USB da TV é 2.0, então o limite prático fica em torno de 300 Mbit/s
  (ainda acima dos 100 Mbit/s da porta de rede da TV).
- `diagnostico/config.gz` é a configuração do kernel da TV, usada na compilação.

## Compilação (05/11/2026)
- Ambiente: WSL Ubuntu 24.04, `arm-linux-gnueabihf-gcc-9` (9.5; a TV usou 8.2).
- Fonte: `bsp_open/kernel` de `common/bsp_open3.tar.gz` (parte 2 do pacote), kernel 4.4.84.
  Extração: `bash scripts/extrair-fonte.sh /pasta/dos/downloads` (gera `~/lg/bsp_open/kernel`).
- Compilação: `bash scripts/compilar-r8152.sh` → `build/r8152.ko` (driver `r8152` da própria árvore da LG).
- Conferido: vermagic `4.4.84 SMP preempt mod_unload ARMv7` e todos os 94 símbolos que o módulo usa
  estão exportados no kernel da TV.
- Diferenças entre a config da TV e este código: `CPU_SW_DOMAIN_PAN` (o código antigo desliga em MStar;
  o r8152 não acessa memória de usuário, então não afeta) e `MFB_GC` (opção da LG ausente no código,
  efeito desconhecido). Ou seja, o kernel da TV (2025) é mais novo que o código (2021).
  Risco: se alguma estrutura interna mudou, o módulo pode travar a TV — ela reinicia e volta ao normal,
  porque o módulo não é carregado automaticamente.

## Roteiro

### 1. Acesso à TV
- A TV precisa estar com **root** e **SSH** (Homebrew Channel).
- O método de root depende da versão do firmware. Conferir a versão em
  *Configurações → Geral → Sobre esta TV* e ver o método compatível em
  <https://www.webosbrew.org/rooting/>.
- Sem root dá para rodar o diagnóstico com acesso limitado, mas não dá para carregar driver.

### 2. Diagnóstico (adaptador já conectado na TV)
Copiar e rodar na TV:

```sh
scp scripts/coletar-info-tv.sh root@IP_DA_TV:/tmp/
ssh root@IP_DA_TV sh /tmp/coletar-info-tv.sh
scp root@IP_DA_TV:/tmp/lg-ethernet-info.txt diagnostico/
```

O relatório mostra:
- o **VID:PID** e o **chip** do adaptador (e se algum driver já pegou ele);
- a versão do kernel e do webOS;
- se o kernel aceita módulos (`CONFIG_MODULES`) e se exige assinatura (`CONFIG_MODULE_SIG*`);
- quais drivers de rede USB já existem na TV;
- o `vermagic` que um módulo compilado por nós precisa ter.

Se o adaptador estiver no PC (Windows), dá para identificar o chip com:

```powershell
pwsh -File scripts\identificar-adaptador.ps1
```

### 3. Decidir o caminho
| Situação no relatório | O que fazer |
|---|---|
| Driver do chip já existe como `.ko`, mas não carregou | Só `insmod`/`modprobe` e configurar a interface |
| Driver não existe, kernel aceita módulos sem assinatura | Compilar o módulo (passo 4) |
| Kernel exige módulo assinado | Não dá para carregar módulo próprio; trocar por um adaptador com chip já suportado |
| Chip desconhecido | Pesquisar o VID:PID; se for CDC-ECM/NCM, testar `cdc_ether`/`cdc_ncm` |

### 4. Compilar o módulo
1. Baixar o código-fonte GPL do kernel da TV em <https://opensource.lge.com> (buscar pelo modelo, ex.: `OLED55A1`).
   Pacote encontrado: **"webOS 6.0 LMUA 1.0"** (modelo `OLED55A1PSA`), em 3 partes:
   `webOS 6.0 LMUA_1.0_1.tar.gz`, `_2.tar.gz`, `_3.tar.gz`. Ele é da versão 6.0 original;
   a TV está na 6.5.3, então usamos a `.config` da própria TV (`diagnostico/config.gz`).
   Referências de quem já fez algo parecido: `github.com/throwaway96/webos-kernel-drivers`
   (módulos prontos para `armv7l-4.4.84-lm21u`, mas sem `r8152`) e `github.com/DonZoomik/webos-r8152`
   (r8152 para outra TV; desligar scatter-gather evita travar o USB).
2. Usar o toolchain da mesma versão do GCC mostrada em `/proc/version`.
3. Usar a `.config` da TV (`/proc/config.gz`), ajustando `LOCALVERSION` para o `vermagic` bater.
4. Compilar como módulo só o necessário: `usbnet`, `mii` e o driver do chip (`r8152`, `ax88179_178a`, `asix`...).

### 5. Carregar e deixar permanente
- `insmod usbnet.ko`, depois o driver do chip; conferir com `dmesg` e `ip link`.
- Subir a interface (DHCP) e testar.
- Para carregar no boot: script em `/var/lib/webosbrew/init.d/`.

## Riscos
- Um módulo incompatível pode travar a TV; normalmente volta ao reiniciar.
- Root e modificações podem afetar a garantia.

## Estrutura
- `scripts/coletar-info-tv.sh` — diagnóstico, roda na TV (só leitura).
- `scripts/identificar-adaptador.ps1` — identifica o chip do adaptador no Windows.
- `diagnostico/` — relatórios trazidos da TV.

## Teste na TV (05/11/2026, OLED55A1PSA, firmware 03.53.45, webOS 6.5.3)
- `insmod` sem erros: `r8152 1-1:1.0 eth1: v1.08.2`. O driver troca o adaptador da configuração USB 2
  (CDC genérico) para a 1 (fornecedor), como esperado.
- Com o cabo no adaptador, o connman da TV cria sozinho o serviço `ethernet_<mac>_cable`, pega IP por DHCP,
  define a rota padrão e o DNS; `connmanctl state` = `online`. Nenhuma configuração extra foi necessária.
- Link 1000 Mbit/s. Download (Cloudflare, 50 MB): 111 Mbit/s num fluxo; 98 Mbit/s com 4 fluxos.
  TV → PC na rede local: 94 Mbit/s, mas a placa do PC estava a 100 Mbit/s (o limite era o PC).
  Por SSH ~90 Mbit/s (limitado pela criptografia no processador da TV).
- `rx_dropped` sobe com o tempo (pacotes que a TV descarta, como multicast/IPv6); `rx_errors` = 0.
- Ativação ao ligar: script em `/var/lib/webosbrew/init.d/60-lg-a1-usb-ethernet`; após `reboot`, o driver
  carregou ~40 s depois de ligar e a rede voltou sozinha. O arquivo de proteção `boot-pending` foi apagado
  ~2 min depois, como previsto.
- Pacote `.ipk`: o verificador da LG recusa o formato `ar` do GNU binutils (nomes com `/` no fim);
  `scripts/empacotar-ipk.sh` gera o formato clássico do `dpkg-deb`, que instala normalmente.

## Velocidade e buffers de recepção (05/11/2026, v0.3.0)
Medido com `scripts/teste-velocidade.sh` e testes na rede local (PC a 1 Gbit/s, servidor HTTP no PC):
- Nenhum núcleo da TV passa de ~36% durante os downloads: a CPU não é o gargalo. O RPS ajudou pouco.
- Enviando (TV → PC, `nc`): ~251 Mbit/s. Recebendo (PC → TV, HTTP): ~152 Mbit/s com o driver original,
  com ~17.700 segmentos TCP fora de ordem a cada 300 MB — perda dentro do adaptador, antes do kernel
  (`rx_dropped` do driver quase não muda).
- Variantes testadas (troca do módulo com volta automática ao original se a rede não voltasse):
  32 × 16 KB: 155–159 Mbit/s; 10 × 32 KB: 202–212; **32 × 32 KB: 214–215** (fora de ordem ~600).
  O ganho vem do tamanho do buffer; 32 KB é o tamanho que o r8152 do Linux oficial usa para o RTL8153.
- Virou `driver/patches/0001-rx-buffers-32x32k.patch`, aplicado por `scripts/compilar-r8152.sh`.
- `speed.cloudflare.com` passa a recusar (HTTP 429) depois de muitos downloads seguidos do mesmo IP.
- Depois de instalar a v0.3.0 pelo serviço do Homebrew Channel (a partir do manifesto) e recarregar o driver:
  rede local 216 Mbit/s (fora de ordem 594); internet (Cloudflare, 50 MB) 182 Mbit/s, contra 111–119 antes.

## Adaptador como eth0 (06/11/2026, v0.4.0)
- Com o adaptador como `eth1`, `connectionmanager/getStatus` dá `"wired":{"plugged":false,"state":"disconnected"}`
  mesmo com internet (`isInternetConnectionAvailable: true`): o webOS só olha `eth0`.
- Na MStar do A1 a porta própria é `/sys/devices/virtual/net/eth0` (sem link `device`), então ela é
  reconhecida como "cabeada, `eth*`, fora do USB, não Wi-Fi/bridge/túnel"; na primeira troca o MAC é salvo
  em `/var/lib/lg-a1-usb-ethernet/builtin_mac` e passa a valer o MAC.
- Troca (adaptador → `eth0`, porta própria → `eth2`): ~12 s até a rede voltar; o connman mantém o serviço
  (`ethernet_<mac>_cable`) e o IP; `getStatus` passa a `connected`, `interfaceName: eth0`, `onInternet: yes`.
- Vigia (`usbeth.sh watch`, a cada 5 s): adaptador desligado por software (`authorized` 0/1) → eth0 volta à
  porta própria; adaptador de volta → troca refeita. Desligar/ligar pelo controle fez boot completo: driver
  aos ~42 s, troca 0,4 s depois, `connected`; proteção `boot-pending` apagada no tempo.
- `luna-send` só devolve saída no contexto do Homebrew Channel (exec/boot); pelo SSH sem terminal fica vazio.
