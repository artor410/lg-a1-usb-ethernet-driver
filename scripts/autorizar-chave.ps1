# Autoriza a chave SSH deste PC (~/.ssh/lg_tv_ed25519) na TV.
# Pede a senha de root da TV uma vez; depois o acesso é por chave.
# Uso:  .\scripts\autorizar-chave.ps1 -Tv IP_DA_TV
# Crie a chave antes:  ssh-keygen -t ed25519 -f $HOME/.ssh/lg_tv_ed25519
#   (tecle Enter duas vezes quando pedir a senha da chave, para deixá-la sem senha)
param([Parameter(Mandatory)][string]$Tv)

$pub = (Get-Content "$HOME/.ssh/lg_tv_ed25519.pub" -Raw).Trim()
$remoto = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && " +
          "(grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys) && " +
          "chmod 600 ~/.ssh/authorized_keys && echo CHAVE_AUTORIZADA"

ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password root@$Tv $remoto
