# luatodonotes
The package allows the user to insert comments into a document that
suggest (for example) further editing that may be needed.

The comments are shown in the margins alongside the text; different styles
for the comments may be used; the styles are selected using package
options.

The package is based on the package todonotes by Henrik Skov Midtiby
(http://www.ctan.org/pkg/todonotes), and depends heavily on Lua,
so it can only be used with LuaLaTeX.


## Installation
Run `latex luatodonotes.ins` to generate the package files and copy the listed
files into your TEXMF tree.


## Development
The latest source code is available on GitHub:  
https://github.com/fabianlipp/luatodonotes

If you want to report bugs or you have suggestions for improvements, you can
use the issue tracker on GitHub or contact me via email.


## License
The luatodonotes package is subject to the LATEX Project Public License.
The following external lua libraries are used:

* `path_line.lua` and `path_point.lua`:  
  taken from luapower.com (Public domain)

* `inspect.lua`:  
  by Enrique García Cota (MIT License)
