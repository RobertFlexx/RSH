## SRSH IS NOW A GEM!

This is **srsh version 0.8.0**.

This is a **beta release**. Things may break, behave oddly, or not work at all in some edge cases. If you notice anything weird, please open an issue.

Recent changes:

* Fixed Control-C handling
* Fixed several bugs
* Added new features (see the `help` command for details)

The core code is written by **RobertFlexx**. Comments were written with help from ChatGPT.

---

## Webpage

Live preview (renders as a real webpage):

```
https://raw.githack.com/RobertFlexx/RSH/master/docs/index.html
```

Source file in the repository (shows HTML source on GitHub, this is expected):

```
https://github.com/RobertFlexx/RSH/blob/master/docs/index.html
```

Note: GitHub READMEs cannot force links to open in a new tab. Use middle-click or right-click if you want it opened separately.

---

## Known Issues

* Flatpak chaining with `and` does not work.
* Running shell scripts is inconsistent. Sometimes it works, sometimes it does not.
* Native RSH scripts work correctly when using this shebang:

  ```
  #!/usr/bin/env srsh
  ```

---

## Support

If you run into issues, please open an issue here:

```
https://github.com/RobertFlexx/RSH/issues
```

---

## Installation (Recommended: RubyGem)

```console
gem install srsh
```

That’s it. You can now run:

```console
srsh
```

---

## Classic Installation (Clone the Repository)

```console
git clone https://github.com/RobertFlexx/RSH
cd RSH
chmod +x rsh
./rsh
```

---

## Requirements

* Ruby 2.7 or newer (newer versions are recommended).
* A POSIX-style terminal (Linux, *BSD, macOS Terminal, iTerm2, etc).
* The `rsh` file must be executable:

```console
chmod +x rsh
```

If `./rsh` behaves strangely, always try running it directly from the repository first before adding it to PATH or creating symlinks.

---

## Basic Usage

From inside the repository:

```console
./rsh
```

Inside `srsh` / `rsh` you can:

* Run normal commands (`ls`, `cat`, `grep`, etc).
* Use built-in commands:

  * `help` – show all srsh-specific commands
  * `systemfetch` – display system information with bars
  * `hist` – view shell history
  * `clearhist` – clear history (memory and file)
  * `alias` / `unalias` – manage aliases

Features:

* Autosuggestions (ghost text from history)
* Smart tab completion:

  * Commands, files, and directories
  * `cd` completes only directories
  * `cat` completes only files

---

## Adding srsh to Your PATH

To avoid running `./rsh` every time, you can either add the repository to your PATH or create a symlink.

Warning: Some systems already have a command named `rsh`. Using `srsh` is safer.

### Option 1: Add Repository to PATH (Linux & macOS)

Assuming the repository is located at `~/RSH`:

```console
chmod +x ~/RSH/rsh
```

#### bash

Add to `~/.bashrc` (or `~/.bash_profile` on macOS):

```bash
export PATH="$HOME/RSH:$PATH"
```

Reload:

```console
source ~/.bashrc
```

#### zsh

Add to `~/.zshrc`:

```zsh
export PATH="$HOME/RSH:$PATH"
```

Reload:

```console
source ~/.zshrc
```

You can now run:

```console
rsh
# or rename it to:
srsh
```

---

### Option 2: Symlink into /usr/local/bin

From inside the repository:

```console
chmod +x rsh
sudo ln -s "$(pwd)/rsh" /usr/local/bin/srsh
```

Run from anywhere:

```console
srsh
```

Overriding the system `rsh` command is possible but not recommended:

```console
sudo ln -s "$(pwd)/rsh" /usr/local/bin/rsh
```

---

## *BSD Notes

Assuming the repository is at `~/RSH`:

```console
chmod +x ~/RSH/rsh
```

### sh / ksh / ash / dash

Add to `~/.profile`:

```sh
export PATH="$HOME/RSH:$PATH"
```

Reload:

```console
. ~/.profile
```

### csh / tcsh

Add to `~/.cshrc` or `~/.tcshrc`:

```csh
set path = ( $HOME/RSH $path )
```

Reload:

```console
source ~/.cshrc
```

---

## Tips

* If the command is not found:

  * Check your shell:

    ```console
    echo $SHELL
    ```
  * Confirm your PATH:

    ```console
    echo "$PATH"
    ```
* If something feels broken, always test with:

  ```console
  ./rsh
  ```

If anything looks cursed, consult me and/or open an issue :D
(Btw I wrote this markdown on mobile, ik It's ass)
