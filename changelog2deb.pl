#!/usr/bin/perl -w

# convert changelog file to changelog.Debian.gz
# changelog format: 
#package version (date):
#	entry1
#	entry2 ...
# date is generated with: date -R
# (changelog.Debian.gz: see http://www.debian.org/doc/debian-policy/ch-source.html#s-dpkgchangelog)

$DISTRI = "unstable";
$URGENCY = "low";
$MAINTAINER = "Tobias Elze <sourceforge\@tobias-elze.de>";

$counter = 0;
$mstring = " -- $MAINTAINER  ";

while(<>)
{
	if(/^\S+\s+\S+.*\(([^\)]*)\).*/)
	{
		$counter++;
		$date = $new_date;
		($new_date = $1) =~ s/, 0/,  /;
	}
	s/^[ \t]+/  \* /;
	if($counter>1)
	{
		s/^(\S+)\s+(\S+).*/$mstring$date\n\n$1 ($2) $DISTRI; urgency=$URGENCY\n/;
	}
	else 
	{
		s/^(\S+)\s+(\S+).*/$1 ($2) $DISTRI; urgency=$URGENCY\n/;
	}
	print;
}

print "$mstring$new_date\n\nLocal variables:\nmode: debian-changelog\nEnd:";
