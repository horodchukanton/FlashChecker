#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

$| = 1;

do {
    print STDOUT "connection_check OUT: $_\n";
    sleep 2
} for (1, 2, 3);
print STDERR "connection_check Error\n";

exit 5;
1;