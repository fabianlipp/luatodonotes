# luatodonotes
This package allows you to insert comments for further editing in your document.
The comments are shown in the margins besides the text.
Different styles for the comments can be used, which can be configured using
package options.
This package depends heavily on Lua, so it can only be used with LuaLaTeX.

luatodonotes is based on the todonotes package by Henrik Skov Midtiby
(http://www.ctan.org/pkg/todonotes).

# Installation
Run `latex luatodonotes.ins` to generate the package files and copy the listed
files into your TEXMF tree.

# License
The luatodonotes package is subject to the LATEX Project Public License.
The following external lua libraries are used:

* `path_line.lua` and `path_point.lua`
  taken from luapower.com (Public domain)

* `inspect.lua`
  by Enrique García Cota
  MIT License
