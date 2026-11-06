# Authorizes this PC's SSH key (~/.ssh/lg_tv_ed25519) on the TV.
# Asks for the TV's root password once; after that, access is key-based.
# Usage:  .\scripts\authorize-key.ps1 -Tv TV_IP
# Create the key first:  ssh-keygen -t ed25519 -f $HOME/.ssh/lg_tv_ed25519
#   (press Enter twice at the passphrase prompt to leave it without a passphrase)
param([Parameter(Mandatory)][string]$Tv)

$pub = (Get-Content "$HOME/.ssh/lg_tv_ed25519.pub" -Raw).Trim()
$remote = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && " +
          "(grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys) && " +
          "chmod 600 ~/.ssh/authorized_keys && echo KEY_AUTHORIZED"

ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password root@$Tv $remote
