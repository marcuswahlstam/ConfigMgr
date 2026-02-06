NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

CURRENT_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}' )

echo >> /Users/$CURRENT_USER/.zprofile
echo 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"' >> /Users/$CURRENT_USER/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv zsh)"

sudo softwareupdate --install-rosetta --agree-to-license

curl -fsSL https://raw.githubusercontent.com/marcuswahlstam/ConfigMgr/refs/heads/main/standard-casks | brew bundle --file=-
