# cli-tools
Collection of custom CLI scripts and tools.

As of this writing, these are all either POSIX-compliant `sh` scripts, or `bash` scripts.

In general, I favor using `sh` or `bash` as these are pretty universal targets for all
the systems I tend to work in (Linux/BSD-family). This means that I can easily deploy
these to any of those systems by either directly referencing the script, or installing
it with something like [Homebrew/Linuxbrew](https://github.com/andres-rojas/homebrew-keg).

In the future, I might have some CLI tools written in other languages, but since I'm
going to favor portability, I'm probably going to target something that can easily/quickly
be compiled/deployed like Golang. We'll see how that goes.
