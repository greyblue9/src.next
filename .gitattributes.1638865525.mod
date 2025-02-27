# Set the default behavior, in case people don't have core.autocrlf set.
* text=auto eol=lf

# Declare files that will always have CRLF line endings on checkout.
*.cmd text eol=crlf
*.bat text eol=crlf

# Denote all files that are truly binary and should not be modified.
*.so binary
*.dex binary
*.jar binary
*.png binary
[core]
core.fileMode = true
