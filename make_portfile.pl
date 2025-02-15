#!/usr/bin/perl -w

# generate a portfile from SOURCEFILE (first argumemt)
# writes to STDOUT
# USAGE: ./make_portfile sources.tar.bz2

$SOURCEFILE = shift;
if($SOURCEFILE =~ m/^([^-]+)\-([0-9.]+)\.tar\.bz2$/)
{
	$name=$1;
	$version=$2;
}
else { die "First argument does not match source file naming conventions." }

sub extract_checksum
{
	my $call = shift;
	my $checksum;
	my $inp;
	open(IN, "$call|");
	$inp = <IN>;
	chomp $inp;
	($checksum = $inp) =~ s/[^=]+=\s*(.+)$/$1/;
	close(IN);
	return($checksum);
}
$md5 = extract_checksum("md5 $SOURCEFILE");
$sha1 = extract_checksum("openssl sha1 $SOURCEFILE");
$rmd160 = extract_checksum("openssl rmd160 $SOURCEFILE");

print <<END
# \$Id\$

PortSystem		1.0

name 			$name
version			$version
platforms		darwin
maintainers		tobias-elze.de:macports
categories		textproc, graphics
description		pdfsandwich is a tool to make "sandwich" OCR pdf files
homepage		http://pdfsandwich.origo.ethz.ch/
master_sites		http://download.origo.ethz.ch/pdfsandwich/1809/

use_bzip2		yes

checksums		md5 $md5 \\
			sha1 $sha1 \\
			rmd160 $rmd160 

long_description \\
			pdfsandwich generates "sandwich" OCR pdf files, i.e. pdf files which contain only images \\
			(no text) will be processed by optical character recognition (OCR) and the text will be \\
			added to each page invisibly "behind" the images. pdfsandwich is a command line \\
			tool which is supposed to be useful to OCR scanned books or journals. \\
			It is able to recognize the page layout even for multicolumn text. \\
			Essentially, pdfsandwich is a wrapper script which calls the following binaries: \\
			unpaper, convert, gs, hocr2pdf, and tesseract.

depends_build		port:gawk \\
			port:ocaml
depends_run		port:tesseract \\
			port:unpaper \\
			port:exact-image \\
			port:ghostscript 

END
