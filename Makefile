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
	luatodonotes.upa \
	luatodonotes.upb \
	luatodonotes.fls \
	luatodonotes.fdb_latexmk \
	luatodonotes.synctex.gz

DISTCLEAN := \
	luatodonotes.sty \
	luatodonotes.pdf \
	luatodonotes.zip

default: luatodonotes.pdf luatodonotes.zip

luatodonotes.pdf: luatodonotes.sty luatodonotes.dtx
	lualatex luatodonotes.dtx
	makeindex -s gglo.ist -o luatodonotes.gls luatodonotes.glo
	makeindex -s gind.ist -o luatodonotes.ind luatodonotes.idx
	lualatex luatodonotes.dtx
	lualatex luatodonotes.dtx

luatodonotes.zip: luatodonotes.pdf luatodonotes.dtx luatodonotes.ins
	rm -rf luatodonotes
	mkdir luatodonotes
	cp luatodonotes.ins luatodonotes/luatodonotes.ins
	cp luatodonotes.dtx luatodonotes/luatodonotes.dtx
	cp luatodonotes.pdf luatodonotes/luatodonotes.pdf
	cp luatodonotes.lua luatodonotes/luatodonotes.lua
	cp path_line.lua luatodonotes/path_line.lua
	cp path_point.lua luatodonotes/path_point.lua
	cp inspect.lua luatodonotes/inspect.lua
	cp README.md luatodonotes/README.md
	chmod a+r -R luatodonotes
	chmod a+x luatodonotes
	zip -r luatodonotes.zip luatodonotes

luatodonotes.sty: luatodonotes.ins luatodonotes.dtx
	rm -f luatodonotes.sty
	pdflatex luatodonotes.ins

luatodonotes.gls: luatodonotes.glo

#testexample: \
	#todonotes.sty
	#pdflatex todonotesexample.tex
	#okular todonotesexample.pdf 

.PHONY: clean
clean:
	@rm -f $(CLEAN)

.PHONY: distclean
distclean: clean
	@rm -f $(DISTCLEAN)

.PHONY: latexmkpvc
latexmkpvc: luatodonotes.sty
	latexmk -pvc -pdf -r dtxmkrc luatodonotes.dtx

