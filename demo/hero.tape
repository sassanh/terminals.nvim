Output assets/hero.gif

Set Shell "bash"
Set FontSize 16
Set Width 1280
Set Height 760
Set Padding 32
Set Theme "Catppuccin Mocha"

Hide
Type "export HOME=/tmp/terminals-demo-home"
Enter
Type "export DEMO_HOME=/tmp/terminals-demo-home"
Enter
Type "export TERM=xterm-256color"
Enter
Type "cd /tmp/terminals-demo"
Enter
Type "nvim -u demo/init.lua"
Enter
Sleep 2s
Show
Sleep 20s