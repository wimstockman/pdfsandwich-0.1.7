OCAMLOPT		= ocamlopt
OCAMLOPTFLAGS	= -thread -w s
OCAMLOPTLIBS	= str.cmxa unix.cmxa threads.cmxa 
OCAMLINCS		=
XOBJS			= pdfsandwich_version.cmx

SOURCE = pdfsandwich.ml
TARGET = pdfsandwich
MANUAL =	$(TARGET).1.gz

VERSION :=	$(shell cat pdfsandwich_version)

all: $(TARGET) $(MANUAL)

$(TARGET): $(XOBJS) $(SOURCE) 
	$(OCAMLOPT) $(OCAMLOPTFLAGS) $(OCAMLINCS) $(OCAMLOPTLIBS) -o $@ $^


%.cmx: %.ml
	$(OCAMLOPT) $(OCAMLOPTFLAGS) $(OCAMLINCS) $(OCAMLOPTLIBS) -c $<

pdfsandwich_version.ml: pdfsandwich_version
	echo "let pdfsandwich_version=\"$(VERSION)\";; (*automatically generated from file pdfsandwich_version*)" > $@

$(MANUAL):	manual.txt
	# you need gawk for this:
	./txt2man -t PDFSANDWICH manual.txt | gzip -9 > $(MANUAL)

# Canceling pathological implicit rule:
%: %.o

##############
### install
##############

DOCFILES = 	copyright changelog

PREFIX = 		/usr/local
# this may overwrite PREFIX:
include makefile.installprefix

PREF = $(DESTDIR)$(PREFIX)
INSTALL = 	install -s
CP = 		cp
INSTALLBINDIR =	$(PREF)/bin
INSTALLMANDIR = $(PREF)/share/man/man1
INSTALLDOCDIR = $(PREF)/share/doc/$(TARGET)

install: $(DOCFILES) $(ADDITIONAL)
	(umask 0022; mkdir -p $(INSTALLBINDIR) $(INSTALLDOCDIR) $(INSTALLMANDIR))
	$(INSTALL) $(TARGET) $(INSTALLBINDIR)
	$(CP) $(DOCFILES) $(INSTALLDOCDIR)
	gzip -9 $(INSTALLDOCDIR)/changelog
	$(CP) $(MANUAL) $(INSTALLMANDIR)
	chmod 644 $(INSTALLDOCDIR)/* $(INSTALLMANDIR)/*

uninstall:
	rm -rf $(INSTALLBINDIR)/$(TARGET) $(INSTALLDOCDIR) $(INSTALLMANDIR)/$(MANUAL)


##########
# PACKAGES:
##########
SVN=svn
#REMOTESRCDIR = https://pdfsandwich.svn.sourceforge.net/svnroot/pdfsandwich/trunk/src
REMOTESRCDIR = https://svn.code.sf.net/p/pdfsandwich/code/trunk/src
PACKAGE :=	$(TARGET)-$(VERSION)
bz2: $(PACKAGE).tar.bz2

# source package:
$(PACKAGE).tar.bz2:
	# "clean" checkout (unversioned):
	$(SVN) export $(REMOTESRCDIR) $(PACKAGE)
	tar -cjf $@ $(PACKAGE)
	rm -rf $(PACKAGE)

# MacOS X Macport:
Portfile: $(PACKAGE).tar.bz2 pdfsandwich_version
	./make_portfile.pl $< > $@

###### deb (Ubuntu)

ARCHITECTURE := $(shell uname -a|perl -e 'while(<>) {print /x86_64/ ? "amd64" : "i386";}')
DEBPACKAGE :=	$(TARGET)_$(VERSION)_$(ARCHITECTURE)
DEBDOCDIR = 	$(DEBPACKAGE)/usr/share/doc/$(TARGET)

deb: control md5sums
	mkdir -p $(DEBPACKAGE)/DEBIAN
	cp $^ $(DEBPACKAGE)/DEBIAN
	fakeroot dpkg -b $(DEBPACKAGE)/ .

$(DEBPACKAGE): all
	$(MAKE) PREFIX=$@/usr install
	./changelog2deb.pl changelog | gzip -9 > $(DEBDOCDIR)/changelog.Debian.gz
	chmod 644 $(DEBDOCDIR)/changelog.Debian.gz
	
md5sums: $(DEBPACKAGE)
	cd $< && find * -type f -exec md5sum {} \; > ../md5sums
	chmod 644 md5sums

control: $(DEBPACKAGE)
	./make_control.pl $< > $@
	
clean: 
	rm -f *.cmi *.cmo *.cmx *.cma *.cmxa *.o *.a *.so depend $(TARGET)
	rm -f pdfsandwich_version.ml $(MANUAL)
	rm -rf $(PACKAGE) $(PACKAGE).tar.bz2 $(DEBPACKAGE) $(DEBPACKAGE).deb

