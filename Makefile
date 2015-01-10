CLEAN := \
	luatodonotes.log \
	luatodonotes.aux \
	luatodonotes.tdo \
	luatodonotes.out \
	luatodonotes.idx \
	luatodonotes.glo \
	luatodonotes.gls \
	luatodonotes.ilg \
	luatodonotes.ind \
	luatodonotes.toc \
	luatodonotes.fls \
	luatodonotes.fdb_latexmk \
	luatodonotes.synctex.gz

DISTCLEAN := \
	luatodonotes.sty \
	luatodonotes.pdf

default: luatodonotes.pdf

luatodonotes.pdf: luatodonotes.sty luatodonotes.dtx
	lualatex luatodonotes.dtx
	makeindex -s gglo.ist -o luatodonotes.gls luatodonotes.glo
	makeindex -s gind.ist -o luatodonotes.ind luatodonotes.idx
	lualatex luatodonotes.dtx
	lualatex luatodonotes.dtx
	rm -rf luatodonotes
	mkdir luatodonotes
	cp luatodonotes.ins luatodonotes/luatodonotes.ins
	cp luatodonotes.dtx luatodonotes/luatodonotes.dtx
	cp luatodonotes.pdf luatodonotes/luatodonotes.pdf
	cp luatodonotes.lua luatodonotes/luatodonotes.lua
	cp path_line.lua luatodonotes/path_line.lua
	cp path_point.lua luatodonotes/path_point.lua
	cp inspect.lua luatodonotes/inspect.lua
	cp README luatodonotes/README
	zip -r luatodonotes.zip luatodonotes

luatodonotes.sty: luatodonotes.ins luatodonotes.dtx
	rm -f luatodonotes.sty
	pdflatex luatodonotes.ins

luatodonotes.gls: luatodonotes.glo

#testexample: \
	#todonotes.sty
	#pdflatex todonotesexample.tex
	#okular todonotesexample.pdf 

clean: 
	@rm -f $(CLEAN)

distclean: clean
	@rm -f $(DISTCLEAN)

.PHONY: latexmkpvc
latexmkpvc: luatodonotes.sty
	latexmk -pvc -pdf -r dtxmkrc luatodonotes.dtx

