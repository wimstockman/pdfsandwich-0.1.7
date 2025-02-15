# What is pdfsandwich?

pdfsandwich generates "sandwich" OCR pdf files, i.e. pdf files which contain only images (no text) will be processed by optical character recognition (OCR) and the text will be added to each page invisibly "behind" the images.

pdfsandwich is a command line tool which is supposed to be useful to OCR scanned books or journals. It is able to recognize the page layout even for multicolumn text.

Essentially, pdfsandwich is a wrapper script which calls the following binaries: unpaper (since version 0.0.9), convert, gs, hocr2pdf (for tesseract prior to version 3.03), and tesseract. It is known to run on Unix systems and has been tested on Linux and MacOS X. It supports parallel processing on multiprocessor systems.

While pdfsandwich works with any version of tesseract from version 3.0 on, tesseract 3.03 or later is recommended for best performance. By default, pdfsandwich runs unpaper to enhance the readability of scanned pages and to improve OCR. For instance, slightly rotated pages are automatically straightened and dark edges removed. For optimally scanned pdf files, this can be switched off by option -nopreproc to speed up processing. 
