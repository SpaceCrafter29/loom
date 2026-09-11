# Loom console palette

The Linux console has exactly 16 colours, and they are the ugly VGA defaults
until something tells the kernel otherwise. `setvtrgb` is that something: it
takes three lines of 16 comma-separated 0-255 values (all the reds, then all
the greens, then all the blues) and reprograms the palette on every VT.

| idx | name           | hex     |
|-----|----------------|---------|
| 0   | black          | #1c1b1a |
| 1   | red            | #c4524a |
| 2   | green          | #7c9b58 |
| 3   | yellow         | #c79a4b |
| 4   | blue           | #5e81a6 |
| 5   | magenta        | #9a6b9e |
| 6   | cyan           | #5f9a96 |
| 7   | white          | #c8c2b8 |
| 8   | bright black   | #4a4744 |
| 9   | bright red     | #e0726a |
| 10  | bright green   | #98b877 |
| 11  | bright yellow  | #e3b96a |
| 12  | bright blue    | #7ba0c4 |
| 13  | bright magenta | #b98bbd |
| 14  | bright cyan    | #7fb8b4 |
| 15  | bright white   | #efe9de |

Edit the table, then regenerate `palette` and run
`systemctl restart loom-console-palette`. Every Loom theme (zellij, neovim,
btop, starship) refers to these by *index*, never by hex, so changing this one
file restyles the whole system.
