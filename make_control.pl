#!/usr/bin/perl -w

# generate "control" from PACKAGEDIR (first argumemt)
# writes to STDOUT
# USAGE: ./make_control PACKAGEDIR

$PACKAGEDIR = shift;
if($PACKAGEDIR =~ m/^([^_]+)_([^_]+)_([^_]+)$/)
{
	$name=$1;
	$version=$2;
	$arch=$3;
}
else { die "First argument does not match package naming conventions." }

open(IN, "cd $PACKAGEDIR && du -sk --apparent-size|");
$inp = <IN>;
chomp $inp;
($size = $inp) =~ s/^(\d+)\D.*$/$1/;
close(IN);

print <<END
Package: $name
Version: $version
Section: graphics
Priority: optional
Architecture: $arch
Depends: libc6, tesseract-ocr (>=3.00), unpaper, exactimage, imagemagick, poppler-utils, ghostscript
Installed-Size: $size
Maintainer: Tobias Elze <sourceforge\@tobias-elze.de>
Description: Tool to generate "sandwich" OCR pdf files.
 pdfsandwich generates "sandwich" OCR pdf files, i.e. pdf files which 
 contain only images (no text) will be processed by optical character 
 recognition (OCR) and the text will be added to each page invisibly 
 "behind" the images. pdfsandwich is a command line tool which is 
 supposed to be useful to OCR scanned books or journals. 
 It is able to recognize the page layout even for multicolumn text. 
 Essentially, pdfsandwich is a wrapper script which calls the following 
 binaries: 
 convert, unpaper, pdfinfo, pdfunite, gs (only for pdf resizing), 
 hocr2pdf (for tesseract < 3.03), and tesseract.


END
