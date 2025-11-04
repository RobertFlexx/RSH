This is version 0.6.0, if things dont work, or work optimally. If you notice anything wrong, please consult me.
(Fixed Control-C, fixed some bugs, added new features (check via help command)
THIS IS A BETA RELEASE, IT MAY NOT WORK.

The code itself is written by RobertFlexx, but the comments are written by ChatGPT.

## Known Issues:

* Flatpak chaining with 'and' doesn't work.
* Running Shell Scripts might not always work. Sometimes it works, other times not so much.

## Please Consult:

* if you have any issues with this SRSh version, please post an issue.

## How to Install:

### Clone the repository

```console
git clone https://github.com/RobertFlexx/RSH
```

### Change the directory to where the Ruby Script is located

```console
cd RSH
```

### And finally run it

```console
./rsh
```

---

## Requirements

* Ruby installed (2.7+ is recommended; newer is better).
* A POSIX-ish terminal (Linux, *BSD, macOS Terminal, iTerm2, etc).
* `./rsh` needs the executable bit set:

  ```console
  chmod +x rsh
  ```

If `./rsh` complains or behaves oddly, **run it directly in the repo first** before messing with symlinks or PATH.

---

## Basic Usage

Once you’re in the repo:

```console
./rsh
```

Inside `srsh` / `rsh` you can:

* Use normal commands (`ls`, `cat`, `grep`, etc.).
* Use built-ins:

  * `help` – show builtin help with all srsh-specific commands.
  * `systemfetch` – prints system info with nice bars.
  * `hist` – view shell history.
  * `clearhist` – clear history (memory + file).
  * `alias` / `unalias` – manage aliases.
* Enjoy:

  * **Autosuggestions** (ghost text from history).
  * **Smart Tab completion**:

    * Completes commands, files, dirs.
    * `cd` → only directories.
    * `cat` → only files.

---

## Adding `rsh` / `srsh` to your PATH

So you don’t have to always `cd` into the repo and run `./rsh`, you can either:

1. Add the repo directory to your `PATH`, or
2. Symlink the script into a directory that’s already on your `PATH`.

> ⚠️ There is a *system* command called `rsh` on some systems.
> To avoid conflict, using the name `srsh` for the installed command is usually safer.

### Option 1 — Add the repo directory to PATH (Linux & macOS, bash/zsh)

Assuming the repo is at `~/RSH`:

```console
chmod +x ~/RSH/rsh
```

#### For `bash` (Linux, older macOS)

Add this line to `~/.bashrc` (or `~/.bash_profile` on macOS):

```bash
export PATH="$HOME/RSH:$PATH"
```

Then reload:

```console
source ~/.bashrc
```

#### For `zsh` (default on modern macOS)

Add this line to `~/.zshrc`:

```zsh
export PATH="$HOME/RSH:$PATH"
```

Reload:

```console
source ~/.zshrc
```

Now you can just run:

```console
rsh
# or if you prefer to rename it:
srsh
```

---

### Option 2 — Symlink into `/usr/local/bin` (Linux & macOS)

This keeps your PATH clean and gives you a nice command name.

From the repo directory:

```console
chmod +x rsh
sudo ln -s "$(pwd)/rsh" /usr/local/bin/srsh
```

Now you can just type:

```console
srsh
```

from anywhere.

If you really, really want to override the system `rsh` (not recommended):

```console
sudo ln -s "$(pwd)/rsh" /usr/local/bin/rsh
```

---

### *BSD: Adding to PATH

On *BSD, the default shell might be `sh`, `ksh`, `csh`, or `tcsh`. Same idea, different config files.

Assuming repo at `~/RSH`:

```console
chmod +x ~/RSH/rsh
```

#### For `sh` / `ksh` / `ash` / `dash` style shells

Add to `~/.profile`:

```sh
export PATH="$HOME/RSH:$PATH"
```

Then either log out and back in, or:

```console
. ~/.profile
```

#### For `csh` / `tcsh`

Edit `~/.cshrc` (or `~/.tcshrc`) and add:

```csh
set path = ( $HOME/RSH $path )
```

Reload it:

```console
source ~/.cshrc
```

Now you should be able to run:

```console
rsh
# or rename / symlink it as srsh if you want:
srsh
```

---

## Tips / Notes

* If the command **isn’t found** after editing PATH:

  * Check which shell you’re actually using:

    ```console
    echo $SHELL
    ```
  * Make sure you edited the correct rc file for that shell.
  * Print your PATH to confirm:

    ```console
    echo "$PATH"
    ```
* If things feel off, run it directly from the repo with:

  ```console
  ./rsh
  ```

  to see if the issue is PATH-related or shell-related.

And as i say : if anything looks cursed, **consult me and/or open an issue** :D
